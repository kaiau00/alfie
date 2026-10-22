import Foundation
import Testing
@testable import MoeVoice

// The AssemblyAI session, driven end to end against a scripted socket. No
// network: every frame the actor sends is recorded and every reply is one
// the test wrote, so each rule of the protocol here is a check that fails
// when the rule is broken, not a run that happened to work.

// MARK: - Fake socket

/// A socket the test scripts. `replies` maps what the client sent to the
/// text frames the server answers with; anything not matched is silent.
final class FakeSocket: AssemblyAISocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [AssemblyAIFrame] = []
    private var waiter: CheckedContinuation<AssemblyAIFrame, Error>?
    private(set) var sent: [AssemblyAIFrame] = []
    private(set) var closed = false
    var onSend: @Sendable (AssemblyAIFrame) -> [String] = { _ in [] }

    init(begin: Bool = true) {
        if begin {
            queue.append(.text(#"{"type":"Begin","id":"sess-1234","expires_at":1,"configuration":{"model":"universal-3-5-pro","mode":"max_accuracy"}}"#))
        }
    }

    /// Server-side push, out of band.
    func push(_ text: String) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: .text(text)); return }
        queue.append(.text(text))
        lock.unlock()
    }

    func send(_ frame: AssemblyAIFrame) async throws {
        record(frame)
        for reply in onSend(frame) { push(reply) }
    }

    func receive() async throws -> AssemblyAIFrame {
        if let ready = try dequeue() { return ready }
        return try await withCheckedThrowingContinuation { cont in park(cont) }
    }

    func close() async { shut() }

    // Synchronous halves, so the lock is never held across a suspension.
    private func record(_ frame: AssemblyAIFrame) { lock.lock(); sent.append(frame); lock.unlock() }
    private func dequeue() throws -> AssemblyAIFrame? {
        lock.lock(); defer { lock.unlock() }
        if closed { throw AssemblyAIError.closed(code: 1000, reason: "closed") }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
    private func park(_ cont: CheckedContinuation<AssemblyAIFrame, Error>) {
        lock.lock()
        if closed { lock.unlock(); cont.resume(throwing: AssemblyAIError.closed(code: 1000, reason: "closed")); return }
        waiter = cont
        lock.unlock()
    }
    private func shut() {
        lock.lock()
        closed = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(throwing: AssemblyAIError.closed(code: 1000, reason: "closed"))
    }

    var texts: [String] { sent.compactMap { if case .text(let t) = $0 { return t } else { return nil } } }
    var datas: [Data] { sent.compactMap { if case .data(let d) = $0 { return d } else { return nil } } }
}

final class FakeFactory: AssemblyAISocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var connects: [(URL, String?)] = []
    private(set) var sockets: [FakeSocket] = []
    var make: @Sendable () -> FakeSocket = { FakeSocket() }
    var failConnect: Error?

    func connect(url: URL, authorization: String?) async throws -> any AssemblyAISocket {
        try open(url: url, authorization: authorization)
    }
    private func open(url: URL, authorization: String?) throws -> any AssemblyAISocket {
        lock.lock(); defer { lock.unlock() }
        connects.append((url, authorization))
        if let failConnect { throw failConnect }
        let s = make()
        sockets.append(s)
        return s
    }
    var last: FakeSocket? { lock.lock(); defer { lock.unlock() }; return sockets.last }
}

/// A clock the test moves.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: Double) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private func turn(_ order: Int, _ text: String, final: Bool, confidences: [Double] = [0.9]) -> String {
    let words = text.split(separator: " ").enumerated().map { i, w in
        #"{"text":"\#(w)","confidence":\#(confidences[min(i, confidences.count - 1)]),"start":0,"end":1,"word_is_final":\#(final)}"#
    }.joined(separator: ",")
    return #"{"type":"Turn","turn_order":\#(order),"transcript":"\#(text)","end_of_turn":\#(final),"turn_is_formatted":\#(final),"end_of_turn_confidence":1,"words":[\#(words)]}"#
}

private let forceEndpoint = #"{"type":"ForceEndpoint"}"#
private let terminate = #"{"type":"Terminate"}"#

/// Real sleeps, a hundred times shorter: a 4 s deadline is 40 ms.
private let quickSleep: AssemblyAIStream.Sleeper = { s in
    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 10_000_000))
}

private func makeStream(factory: FakeFactory, clock: FakeClock = FakeClock(),
                        idleSeconds: Double = 60,
                        usage: AssemblyAIStream.UsageReport? = nil) -> AssemblyAIStream {
    AssemblyAIStream(
        factory: factory,
        connection: { AssemblyAIConnection(socketURL: URL(string: "wss://example.test/v3/ws?sample_rate=16000&speech_model=universal-3-5-pro&mode=max_accuracy&token=T")!,
                                           authorization: nil) },
        idleSeconds: idleSeconds,
        sleep: quickSleep,
        now: { clock.now },
        usage: usage)
}

private func samples(ms: Int) -> [Float] { [Float](repeating: 0.1, count: ms * 16) }

// MARK: - Framing

struct AssemblyAIFramingTests {

    @Test func hundredMillisecondFramesAndARemnantMergedIntoTheLast() {
        let pcm = AssemblyAIFraming.pcm16(samples(ms: 230))
        let frames = AssemblyAIFraming.frames(pcm)
        #expect(frames.map(\.count) == [3200, 3200 + 30 * 32])
        for f in frames { #expect(f.count >= 50 * 32 && f.count <= 1000 * 32) }
        #expect(frames.reduce(0) { $0 + $1.count } == pcm.count)
    }

    @Test func aRemnantOfFiftyOrMoreStandsOnItsOwn() {
        let frames = AssemblyAIFraming.frames(AssemblyAIFraming.pcm16(samples(ms: 250)))
        #expect(frames.map(\.count) == [3200, 3200, 1600])
    }

    @Test func aBufferUnderFiftyMillisecondsIsPaddedNotSentShort() {
        let frames = AssemblyAIFraming.frames(AssemblyAIFraming.pcm16(samples(ms: 20)))
        #expect(frames.count == 1)
        #expect(frames[0].count == 50 * 32)
    }

    @Test func emptyAudioSendsNothing() {
        #expect(AssemblyAIFraming.frames(Data()).isEmpty)
    }

    @Test func pcm16IsLittleEndianSigned() {
        let d = AssemblyAIFraming.pcm16([1, -1, 0])
        #expect([UInt8](d) == [0xFF, 0x7F, 0x01, 0x80, 0x00, 0x00])
    }
}

// MARK: - Keyterms

struct AssemblyAIKeytermsTests {

    @Test func cappedAtOneHundredDroppingTheLongestFirst() {
        var terms = (0..<120).map { "term\($0)" }          // 5–7 chars
        terms.append(contentsOf: (0..<10).map { "a much longer phrase number \($0)" })
        let out = AssemblyAIKeyterms.prepare(terms)
        #expect(out.count == AssemblyAIKeyterms.maxTerms)
        #expect(!out.contains { $0.hasPrefix("a much longer") })
        #expect(out.first == "term0")
    }

    @Test func dedupedCaseInsensitivelyKeepingTheFirstSpelling() {
        #expect(AssemblyAIKeyterms.prepare(["Alfie", "alfie", " ALFIE ", "Izzy"]) == ["Alfie", "Izzy"])
    }

    @Test func overFiftyCharactersIsDroppedBecauseTheServerIgnoresIt() {
        let long = String(repeating: "x", count: 51)
        #expect(AssemblyAIKeyterms.prepare([long, "ok"]) == ["ok"])
    }

    @Test func urlCarriesTheJSONArrayPercentEncoded() {
        let ctx = AssemblyAIContext(languageCodes: ["en"], keyterms: ["Keanu Reeves", "R&D", "\"quoted\""])
        let base = URL(string: "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&token=T")!
        let url = AssemblyAIStream.url(base: base, context: ctx)
        let s = url.absoluteString
        #expect(s.hasPrefix("wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&token=T&encoding=pcm_s16le&"))
        // The value is one query item: no raw &, ", [ or space inside it.
        let item = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            .first { $0.name == "keyterms_prompt" }!
        #expect(item.value == #"["Keanu Reeves","R&D","\"quoted\""]"#)
        #expect(s.contains("keyterms_prompt=%5B%22Keanu%20Reeves%22%2C%22R%26D%22"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            .first { $0.name == "language_codes" }!.value == #"["en"]"#)
    }

    @Test func parametersAlreadyOnTheURLAreNotRepeated() {
        let base = URL(string: "wss://x/v3/ws?encoding=pcm_s16le")!
        let url = AssemblyAIStream.url(base: base, context: .init())
        #expect(url.absoluteString == "wss://x/v3/ws?encoding=pcm_s16le")
    }
}

// MARK: - Health and routing

struct CloudSttHealthTests {

    /// A ladder, not a flat minute: the blips behind real failures lasted
    /// 11–34 s (09-23 → 09-29), and the minute was paid 43 times.
    @Test func restsLongerOnlyWhileItKeepsFailingAndASuccessResetsIt() {
        let t0 = Date(timeIntervalSince1970: 5_000)
        var h = CloudSttHealth()
        #expect(h.isHealthy(at: t0))
        h.failed(reason: "socket closed 3007", at: t0)
        #expect(!h.isHealthy(at: t0.addingTimeInterval(4)))
        #expect(h.isHealthy(at: t0.addingTimeInterval(5)))
        #expect(h.lastReason == "socket closed 3007")
        h.failed(reason: "again", at: t0.addingTimeInterval(5))
        #expect(h.lastCooldown == 15)
        h.failed(reason: "again", at: t0.addingTimeInterval(20))
        h.failed(reason: "again", at: t0.addingTimeInterval(50))
        h.failed(reason: "again", at: t0.addingTimeInterval(110))
        #expect(h.lastCooldown == 60, "the ladder tops out at a minute")
        h.succeeded()
        h.failed(reason: "new blip", at: t0.addingTimeInterval(500))
        #expect(h.lastCooldown == 5, "a read that worked starts the ladder again")
    }

    @Test func theRouterFallsBackWhileUnhealthyAndForUnsupportedLocales() {
        let t0 = Date(timeIntervalSince1970: 5_000)
        var h = CloudSttHealth()
        #expect(CloudSttRoute.shouldUseCloud(mayUse: true, locale: "he-IL", health: h, now: t0))
        #expect(!CloudSttRoute.shouldUseCloud(mayUse: false, locale: "he-IL", health: h, now: t0))
        #expect(!CloudSttRoute.shouldUseCloud(mayUse: true, locale: "ko-KR", health: h, now: t0))
        h.failed(reason: "x", at: t0)
        #expect(!CloudSttRoute.shouldUseCloud(mayUse: true, locale: "en-US", health: h, now: t0.addingTimeInterval(3)))
        #expect(CloudSttRoute.shouldUseCloud(mayUse: true, locale: "en-US", health: h, now: t0.addingTimeInterval(6)))
    }

    @Test func eighteenLanguages() {
        #expect(AssemblyAILanguages.codes.count == 18)
        #expect(AssemblyAILanguages.supports(locale: "zh-Hans-CN"))
        #expect(!AssemblyAILanguages.supports(locale: "uk-UA"))
    }
}

// MARK: - Messages

struct AssemblyAIMessageTests {

    @Test func turnFieldsAreRead() throws {
        let m = try AssemblyAIMessage.parse(turn(3, "hello there", final: true, confidences: [0.5, 1.0]))
        guard case .turn(let t) = m else { Issue.record("not a turn"); return }
        #expect(t.order == 3)
        #expect(t.transcript == "hello there")
        #expect(t.endOfTurn && t.formatted)
        #expect(t.wordConfidences == [0.5, 1.0])
    }

    @Test func errorAndTerminationAndUnknown() throws {
        #expect(try AssemblyAIMessage.parse(#"{"type":"Error","error_code":3007,"error":"too fast"}"#)
                == .error(code: 3007, message: "too fast"))
        #expect(try AssemblyAIMessage.parse(#"{"type":"Termination","audio_duration_seconds":13,"session_duration_seconds":14}"#)
                == .termination(audioSeconds: 13, sessionSeconds: 14))
        #expect(try AssemblyAIMessage.parse(#"{"type":"SpeechStarted","timestamp":10}"#) == .other(type: "SpeechStarted"))
        #expect(throws: AssemblyAIError.self) { try AssemblyAIMessage.parse("not json") }
    }
}

// MARK: - Session

struct AssemblyAIStreamTests {

    @Test func audioGoesOutAsFramesThenForceEndpointAndTheFinalComesBack() async throws {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            s.onSend = { frame in frame == .text(forceEndpoint) ? [turn(0, "Hello Alfie.", final: true, confidences: [0.8, 1.0])] : [] }
            return s
        }
        let stream = makeStream(factory: factory)
        let result = try await stream.transcribe(samples16k: samples(ms: 1230),
                                                 context: .init(languageCodes: ["en"], keyterms: ["Alfie"]))
        #expect(result.text == "Hello Alfie.")
        #expect(result.turns == 1)
        #expect(result.confidence.map { abs($0 - 0.9) < 0.001 } == true)
        let socket = try #require(factory.last)
        // Every binary frame is within bounds, and they add up to the audio.
        #expect(socket.datas.count == 12)
        for d in socket.datas { #expect(d.count >= 1600 && d.count <= 32_000) }
        #expect(socket.datas.reduce(0) { $0 + $1.count } == 1230 * 32)
        // ForceEndpoint after the last frame, nothing before the audio.
        if case .data = socket.sent.first! {} else { Issue.record("first frame was not audio") }
        #expect(socket.sent.last == .text(forceEndpoint))
        #expect(socket.texts == [forceEndpoint])
        // Token auth: nothing in the header, everything in the URL.
        #expect(factory.connects.count == 1)
        #expect(factory.connects[0].1 == nil)
        #expect(factory.connects[0].0.absoluteString.contains("token=T"))
        #expect(factory.connects[0].0.absoluteString.contains("keyterms_prompt=%5B%22Alfie%22%5D"))
        #expect(await stream.isOpen)
    }

    @Test func autoEndedPiecesAreConcatenatedInOrderNotReplacedByTheLast() async throws {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            s.onSend = { frame in
                guard frame == .text(forceEndpoint) else { return [] }
                return [
                    turn(0, "I need you to", final: false),
                    turn(0, "I need you to", final: true),
                    turn(1, "book the", final: true),
                    turn(2, "flight to Lisbon.", final: true),
                ]
            }
            return s
        }
        let stream = makeStream(factory: factory)
        let result = try await stream.transcribe(samples16k: samples(ms: 2000), context: .init())
        #expect(result.text == "I need you to book the flight to Lisbon.")
        #expect(result.turns == 3)
    }

    @Test func aTurnStillOpenAfterTheFinalIsForcedOnceMore() async throws {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            let forces = Counter()
            s.onSend = { frame in
                guard frame == .text(forceEndpoint) else { return [] }
                switch forces.next() {
                case 1: return [turn(0, "first half", final: true), turn(1, "second", final: false)]
                default: return [turn(1, "second half.", final: true)]
                }
            }
            return s
        }
        let stream = makeStream(factory: factory)
        let result = try await stream.transcribe(samples16k: samples(ms: 1000), context: .init())
        #expect(result.text == "first half second half.")
        #expect(factory.last?.texts == [forceEndpoint, forceEndpoint])
    }

    @Test func noFinalInTimeIsAnErrorAndTheSessionIsGone() async throws {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            s.onSend = { frame in frame == .text(forceEndpoint) ? [turn(0, "still going", final: false)] : [] }
            return s
        }
        let stream = makeStream(factory: factory)
        await #expect(throws: AssemblyAIError.noFinal(afterSeconds: 4 + 1.0 / 1.25)) {
            _ = try await stream.transcribe(samples16k: samples(ms: 1000), context: .init())
        }
        #expect(await !stream.isOpen)
        let socket = try #require(factory.last)
        #expect(socket.closed)
        // A session abandoned by us is still terminated so it stops billing.
        #expect(socket.texts.last == terminate)
    }

    @Test func aServerErrorSurfacesWithItsCode() async throws {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            s.onSend = { frame in frame == .text(forceEndpoint) ? [#"{"type":"Error","error_code":3007,"error":"Input duration violation"}"#] : [] }
            return s
        }
        let stream = makeStream(factory: factory)
        await #expect(throws: AssemblyAIError.server(code: 3007, message: "Input duration violation")) {
            _ = try await stream.transcribe(samples16k: samples(ms: 500), context: .init())
        }
        #expect(await !stream.isOpen)
    }

    @Test func noBeginIsAnError() async throws {
        let factory = FakeFactory()
        factory.make = { FakeSocket(begin: false) }
        let stream = makeStream(factory: factory)
        await #expect(throws: AssemblyAIError.noBegin) {
            _ = try await stream.transcribe(samples16k: samples(ms: 500), context: .init())
        }
    }

    @Test func aCredentialFailureIsThrownBeforeAnySocketOpens() async throws {
        struct Denied: Error {}
        let factory = FakeFactory()
        let stream = AssemblyAIStream(factory: factory, connection: { throw Denied() }, sleep: quickSleep)
        await #expect(throws: Denied.self) {
            _ = try await stream.transcribe(samples16k: samples(ms: 500), context: .init())
        }
        #expect(factory.connects.isEmpty)
    }

    @Test func oneSessionServesManyUtterancesAndIsTerminatedWhenIdle() async throws {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            let n = Counter()
            s.onSend = { frame in
                if frame == .text(forceEndpoint) { return [turn(n.next() - 1, "turn", final: true)] }
                if frame == .text(terminate) { return [#"{"type":"Termination","audio_duration_seconds":2,"session_duration_seconds":9}"#] }
                return []
            }
            return s
        }
        let reported = Reported()
        let stream = makeStream(factory: factory, idleSeconds: 1) { audio, session in reported.add(audio, session) }
        _ = try await stream.transcribe(samples16k: samples(ms: 1000), context: .init())
        _ = try await stream.transcribe(samples16k: samples(ms: 1000), context: .init())
        #expect(factory.connects.count == 1)
        #expect(await stream.isOpen)
        // Idle: 1 "second" is 10 ms under the quick sleeper.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await !stream.isOpen)
        let socket = try #require(factory.last)
        #expect(socket.texts.last == terminate)
        #expect(socket.closed)
        // Usage came from the Termination message; audio is what we sent
        // (2 s) and session what the server billed (9 s).
        #expect(reported.values.count == 1)
        #expect(reported.values.first?.0 == 2)
        #expect(reported.values.first?.1 == 9)
        // The next utterance opens a fresh session.
        _ = try await stream.transcribe(samples16k: samples(ms: 1000), context: .init())
        #expect(factory.connects.count == 2)
    }

    @Test func changedKeytermsGoOutAsUpdateConfigurationDebouncedToTwoSeconds() async throws {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            let n = Counter()
            s.onSend = { frame in frame == .text(forceEndpoint) ? [turn(n.next() - 1, "t", final: true)] : [] }
            return s
        }
        let clock = FakeClock()
        let stream = makeStream(factory: factory, clock: clock)
        _ = try await stream.transcribe(samples16k: samples(ms: 500), context: .init(keyterms: ["Alfie"]))
        // Changed inside the window: waits.
        clock.advance(1)
        _ = try await stream.transcribe(samples16k: samples(ms: 500), context: .init(keyterms: ["Alfie", "Izzy"]))
        #expect(factory.last?.texts.filter { $0.contains("UpdateConfiguration") }.isEmpty == true)
        // Past the window: one message, with the list and Moe's last reply.
        clock.advance(2)
        _ = try await stream.transcribe(samples16k: samples(ms: 500),
                                        context: .init(keyterms: ["Alfie", "Izzy"], agentContext: "What time?"))
        let updates = factory.last!.texts.filter { $0.contains("UpdateConfiguration") }
        #expect(updates == [#"{"agent_context":"What time?","keyterms_prompt":["Alfie","Izzy"],"type":"UpdateConfiguration"}"#])
        // Unchanged: nothing more.
        clock.advance(5)
        _ = try await stream.transcribe(samples16k: samples(ms: 500),
                                        context: .init(keyterms: ["Alfie", "Izzy"], agentContext: "What time?"))
        #expect(factory.last!.texts.filter { $0.contains("UpdateConfiguration") }.count == 1)
    }
}

// MARK: - Live feed

/// The pipeline hands frames over as they are heard; at the end only the
/// tail and a ForceEndpoint go up. A 32 ms frame is 512 samples.
struct AssemblyAILiveTests {

    private func frame() -> [Float] { [Float](repeating: 0.1, count: 512) }

    /// A pause, for the checks that prove something did *not* happen.
    private func settle(_ ms: Int = 30) async throws {
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    /// Wait for the pump (a detached task) to catch up, rather than guess
    /// how long it takes on a loaded test runner. Gives up after 2 s so a
    /// wrong expectation still fails rather than hangs.
    private func waitUntil(_ what: String = "", _ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func liveFactory() -> FakeFactory {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            let n = Counter()
            s.onSend = { frame in
                guard frame == .text(forceEndpoint) else { return [] }
                let k = n.next()
                return [turn(k - 1, k == 1 ? "stale words" : "fresh words", final: true)]
            }
            return s
        }
        return factory
    }

    @Test func framesAreForwardedDuringCaptureAsHundredMillisecondPieces() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init(languageCodes: ["en"]))
        for _ in 0..<10 { stream.feedLive(frame()) }          // 320 ms
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        let socket = try #require(factory.last)
        #expect(socket.datas.map(\.count) == [3200, 3200, 3200])   // 300 ms up, 20 ms waiting
        #expect(socket.texts.isEmpty)                            // no ForceEndpoint yet
        #expect(await stream.isOpen)
    }

    @Test func atTheEndOnlyTheTailGoesUpThenForceEndpoint() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        stream.markTurnBoundary()
        let result = try await stream.transcribe(samples16k: all, context: .init())
        // "stale words" is what the fake answers the first ForceEndpoint with.
        #expect(result.text == "stale words")
        let socket = try #require(factory.last)
        // Three live frames, then the 20 ms tail padded to 50 ms — never the
        // 320 ms buffer again.
        #expect(socket.datas.map(\.count) == [3200, 3200, 3200, 1600])
        #expect(socket.sent.last == .text(forceEndpoint))
        #expect(socket.texts == [forceEndpoint])
    }

    @Test func framesFedBeforeTheSessionHasOpenedAreKept() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init())
        // Same turn of the run loop as the begin: the open has not happened.
        for _ in 0..<7 { stream.feedLive(frame()) }           // 224 ms
        try await waitUntil("two frames") { factory.last?.datas.count == 2 }
        let socket = try #require(factory.last)
        #expect(socket.datas.map(\.count) == [3200, 3200])
    }

    @Test func anAbandonedTurnIsForceEndedAndItsWordsNeverReachTheNextOne() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init())
        for _ in 0..<16 { stream.feedLive(frame()) }          // 512 ms, never read back
        try await waitUntil("five frames") { factory.last?.datas.count == 5 }
        stream.endLiveTurn()
        try await waitUntil("the discard's force-end") { factory.last?.texts.count == 1 }
        let socket = try #require(factory.last)
        #expect(socket.texts == [forceEndpoint])              // the discard
        #expect(await stream.isOpen)                          // session kept
        // The next turn.
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("the next turn's frames") { (factory.last?.datas.count ?? 0) >= 9 }
        stream.markTurnBoundary()
        let result = try await stream.transcribe(samples16k: all, context: .init())
        #expect(result.text == "fresh words")
        #expect(!result.text.contains("stale"))
        #expect(socket.texts == [forceEndpoint, forceEndpoint])
        #expect(factory.connects.count == 1)
    }

    @Test func aTinyRemnantAfterTheTurnWasTakenIsNotWorthAForceEnd() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        stream.markTurnBoundary()
        _ = try await stream.transcribe(samples16k: all, context: .init())
        // 64 ms between the take and the capture switching off.
        stream.feedLive(frame()); stream.feedLive(frame())
        stream.endLiveTurn()
        try await settle(100)
        #expect(factory.last?.texts == [forceEndpoint])       // no second force
    }

    /// A socket whose server auto-ended pieces during the live turn: they are
    /// pushed while the owner is still talking, and the force-end is answered
    /// `delayMs` later (real time; the stream's settle is 2 ms at test speed).
    private func longTurnFactory(forced: [String], delayMs: UInt64) -> FakeFactory {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            s.onSend = { frame in
                guard frame == .text(forceEndpoint) else { return [] }
                Task {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    for m in forced { s.push(m) }
                }
                return []
            }
            return s
        }
        return factory
    }

    private func speakLong(_ stream: AssemblyAIStream, _ factory: FakeFactory, pieces: [String]) async throws -> [Float] {
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        let socket = try #require(factory.last)
        for p in pieces { socket.push(p) }
        try await settle()                                    // the reader files them in the inbox
        stream.markTurnBoundary()
        return all
    }

    // 2026-09-09 16:01:31Z: a 67.7 s hold. The server auto-ended two short
    // pieces while the owner spoke, and the other fifty seconds were one turn
    // still open at the force-end. The read took the two pieces, heard
    // nothing for the 0.2 s settle, and the brain got "…I'm going to give an
    // example. I asked it" — the log said "final 200 ms after end", which is
    // the settle expiring, not a final arriving.
    @Test func theTurnStillOpenAtTheForceEndIsWaitedForNotLostBehindTheAutoEndedPieces() async throws {
        let factory = longTurnFactory(forced: [turn(2, "and it gave me steps instead of doing it.", final: true)],
                                      delayMs: 12)             // 1.2 s at test speed: past the settle, inside the 2.5 s live grace
        let stream = makeStream(factory: factory)
        let all = try await speakLong(stream, factory, pieces: [
            turn(0, "Add to my notes.", final: true),
            turn(1, "I asked it", final: true),
            turn(2, "and it gave me", final: false),
        ])
        let result = try await stream.transcribe(samples16k: all, context: .init())
        #expect(result.text == "Add to my notes. I asked it and it gave me steps instead of doing it.")
        #expect(result.turns == 3)
    }

    @Test func anOpenTurnWhoseFinalNeverComesFailsSoTheWholeBufferIsReReadLocally() async throws {
        let factory = longTurnFactory(forced: [], delayMs: 0)
        let stream = makeStream(factory: factory)
        let all = try await speakLong(stream, factory, pieces: [
            turn(0, "Add to my notes.", final: true),
            turn(1, "and it gave me", final: false),
        ])
        await #expect(throws: AssemblyAIError.self) {
            _ = try await stream.transcribe(samples16k: all, context: .init())
        }
        #expect(await !stream.isOpen)
    }

    @Test func withNothingOpenAtTheForceEndTheSettleStillEndsTheReadQuickly() async throws {
        // The owner stopped talking after the last auto-ended piece: the
        // force-end has nothing to finalise, and waiting the grace for a
        // final that is not coming would add four seconds to every such turn.
        let factory = longTurnFactory(forced: [], delayMs: 0)
        let stream = makeStream(factory: factory)
        let all = try await speakLong(stream, factory, pieces: [
            turn(0, "Add to my notes", final: false),
            turn(0, "Add to my notes.", final: true),
        ])
        let result = try await stream.transcribe(samples16k: all, context: .init())
        #expect(result.text == "Add to my notes.")
    }

    @Test func framesAfterTheBoundaryWaitBehindTheForceEndpoint() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<7 { let f = frame(); all += f; stream.feedLive(f) }   // 224 ms: this turn
        try await waitUntil("two frames") { factory.last?.datas.count == 2 }
        stream.markTurnBoundary()
        for _ in 0..<7 { stream.feedLive(frame()) }                         // 224 ms: the next one
        _ = try await stream.transcribe(samples16k: all, context: .init())
        try await waitUntil("the next turn's frames") { factory.last?.datas.count == 5 }
        let socket = try #require(factory.last)
        let sent = socket.sent
        let force = try #require(sent.firstIndex(of: .text(forceEndpoint)))
        // Before the force-end: 200 ms in two frames and the 24 ms tail
        // padded to 50; after it: the next turn's 200 ms.
        let before = sent[..<force].compactMap { if case .data(let d) = $0 { return d.count } else { return nil } }
        let after = sent[(force + 1)...].compactMap { if case .data(let d) = $0 { return d.count } else { return nil } }
        #expect(before == [3200, 3200, 1600])
        #expect(after == [3200, 3200])
    }

    @Test func theSessionDoesNotIdleOutWhileATurnIsBeingFed() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory, idleSeconds: 1)
        stream.beginLiveTurn(context: .init())
        stream.feedLive(frame())
        try await waitUntil("the open") { factory.last != nil }
        try await settle(60)                                  // several idle periods
        #expect(await stream.isOpen)
        stream.endLiveTurn()
        try await waitUntil("the idle Terminate") { factory.last?.closed == true }
        #expect(await !stream.isOpen)
        #expect(factory.last?.texts.last == terminate)
    }

    /// 26 of 28 "no final within 4 s" fallbacks from 09-23 to 09-29 were
    /// turns with no speech: the server opened no turn, so no final was
    /// coming, and the read waited four seconds and rested the cloud for a
    /// minute. Now it waits one, says it heard nothing, and closes the
    /// session so the next turn opens a fresh one.
    @Test func aLiveTurnTheServerHeardNoWordsInIsNothingHeardNotAFailure() async throws {
        let factory = FakeFactory()                            // answers nothing, ever
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        stream.markTurnBoundary()
        await #expect(throws: AssemblyAIError.heardNothing(afterSeconds: AssemblyAIStream.quietFinalSeconds)) {
            _ = try await stream.transcribe(samples16k: all, context: .init())
        }
        #expect(await !stream.isOpen)
        #expect(factory.last?.texts.last == terminate, "the meter is stopped")
    }

    /// Words were heard — a partial is open — and the final never came: that
    /// is still the cloud failing, and still rests it.
    @Test func aTurnTheServerHadOpenStillFailsAsBefore() async throws {
        let factory = FakeFactory()
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        factory.last?.push(turn(0, "what time", final: false))
        try await Task.sleep(nanoseconds: 20_000_000)
        stream.markTurnBoundary()
        await #expect(throws: AssemblyAIError.noFinal(afterSeconds: AssemblyAIStream.liveFinalGraceSeconds)) {
            _ = try await stream.transcribe(samples16k: all, context: .init())
        }
    }

    @Test func mosOwnTeardownIsNotACloudFailure() {
        #expect(AssemblyAIStream.isOwnTeardown(AssemblyAIError.cancelled))
        #expect(AssemblyAIStream.isOwnTeardown(AssemblyAIError.noBegin))
        #expect(!AssemblyAIStream.isOwnTeardown(AssemblyAIError.closed(code: 1006, reason: "")))
        #expect(!AssemblyAIStream.isOwnTeardown(AssemblyAIError.noFinal(afterSeconds: 4)))
    }

    @Test func aFailedOpenTurnsTheFeedOffAndTellsTheOwner() async throws {
        struct Denied: Error {}
        let factory = FakeFactory()
        let failures = Reported()
        let stream = AssemblyAIStream(factory: factory, connection: { throw Denied() }, sleep: quickSleep,
                                      onFailure: { _ in failures.add(1, 0) })
        stream.beginLiveTurn(context: .init())
        stream.feedLive(frame())
        try await waitUntil("the failure") { failures.values.count == 1 }
        #expect(!stream.liveTurnActive)
        #expect(failures.values.count == 1)
        #expect(await !stream.isOpen)
    }
}

// MARK: - The real sequence

/// What `VoiceEngine` actually does, in order: `.capture(true)` (begin +
/// pre-roll + frames), then in one batch `.transcribe` (claim, take →
/// boundary, read queued) and the derived `.capture(false)` (end), with the
/// read arriving last. The first live run on a Mac went to the batch path
/// on every turn because the end ran before the read.
struct AssemblyAIRealSequenceTests {

    private func frame() -> [Float] { [Float](repeating: 0.1, count: 512) }

    private func waitUntil(_ what: String, _ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func liveFactory() -> FakeFactory {
        let factory = FakeFactory()
        factory.make = {
            let s = FakeSocket()
            let n = Counter()
            s.onSend = { frame in
                guard frame == .text(forceEndpoint) else { return [] }
                return [turn(n.next() - 1, "what time is it", final: true)]
            }
            return s
        }
        return factory
    }

    @Test func takeThenCaptureOffThenReadStaysLive() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory)
        // .capture(true): begin, then the pipeline's pre-roll seed and frames.
        stream.beginLiveTurn(context: .init(languageCodes: ["en"]))
        var all = [Float](repeating: 0.05, count: 4800)             // 0.3 s pre-roll
        stream.feedLive(all)
        for _ in 0..<50 { let f = frame(); all += f; stream.feedLive(f) }   // 1.6 s spoken
        try await waitUntil("the live frames") { (factory.last?.datas.count ?? 0) >= 19 }
        // .transcribe: claim now; the take runs a moment later on the pipeline.
        stream.claimLiveTurn()
        // .capture(false), synchronously, in the same batch.
        stream.endLiveTurn()
        // The pipeline gets to the take, then the engine reads.
        stream.markTurnBoundary()
        let result = try await stream.transcribe(samples16k: all, context: .init(languageCodes: ["en"]))
        #expect(result.text == "what time is it")
        let socket = try #require(factory.last)
        // Live: exactly one ForceEndpoint, and the audio went up as it was
        // heard — the 1.9 s buffer was not sent again at the end.
        #expect(socket.texts == [forceEndpoint])
        let bytes = socket.datas.reduce(0) { $0 + $1.count }
        #expect(bytes <= all.count * 2 + 1600)                          // at most the padded tail extra
        #expect(bytes >= all.count * 2)
        // The feed ended with the read: nothing fed now is kept, and the
        // session idles rather than being held open by a phantom turn.
        #expect(!stream.liveTurnActive)
        #expect(await stream.isOpen)
    }

    @Test func aClaimedTurnNobodyReadsIsDiscardedAfterAGrace() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory)
        stream.beginLiveTurn(context: .init())
        for _ in 0..<20 { stream.feedLive(frame()) }
        try await waitUntil("the frames") { (factory.last?.datas.count ?? 0) >= 6 }
        stream.claimLiveTurn()
        stream.endLiveTurn()
        #expect(stream.liveTurnActive)                                  // held for the read…
        try await waitUntil("the grace to run out") { factory.last?.texts.count == 1 }
        #expect(factory.last?.texts == [forceEndpoint])                 // …then discarded
        #expect(!stream.liveTurnActive)
    }

    @Test func aReadThatArrivesWhileTheOpenIsStillInFlightWaitsAndGoesLive() async throws {
        let factory = liveFactory()
        let clock = FakeClock()
        let stream = AssemblyAIStream(
            factory: factory,
            connection: {
                // The credential mint: three seconds in the first live run.
                try await Task.sleep(nanoseconds: 60_000_000)
                return AssemblyAIConnection(socketURL: URL(string: "wss://example.test/v3/ws?token=T")!, authorization: nil)
            },
            sleep: quickSleep, now: { clock.now })
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<30 { let f = frame(); all += f; stream.feedLive(f) }   // ~1 s, before the open
        stream.claimLiveTurn()
        stream.endLiveTurn()
        stream.markTurnBoundary()
        let result = try await stream.transcribe(samples16k: all, context: .init())
        #expect(result.text == "what time is it")
        let socket = try #require(factory.last)
        #expect(socket.texts == [forceEndpoint])
        // Nothing went up before the open, so it all went as the tail: nine
        // 100 ms frames and a 60 ms remnant, once, no padding needed.
        #expect(socket.datas.reduce(0) { $0 + $1.count } == all.count * 2)
        #expect(socket.datas.map(\.count) == Array(repeating: 3200, count: 9) + [1920])
    }

    @Test func openWarmsTheSessionWithNoTurnOnItAndItIdlesOut() async throws {
        let factory = liveFactory()
        let stream = makeStream(factory: factory, idleSeconds: 1)
        try await stream.open(context: .init(languageCodes: ["en"]))
        #expect(await stream.isOpen)
        #expect(!stream.liveTurnActive)
        #expect(factory.connects.count == 1)
        // Open again: nothing happens.
        try await stream.open(context: .init(languageCodes: ["en"]))
        #expect(factory.connects.count == 1)
        try await waitUntil("the idle Terminate") { factory.last?.closed == true }
        #expect(factory.last?.texts.last == terminate)
    }
}

// MARK: - Helpers

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [(Double, Double)] = []
    func add(_ a: Double, _ s: Double) { lock.lock(); values.append((a, s)); lock.unlock() }
}
