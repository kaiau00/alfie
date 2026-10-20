import Foundation
import Testing
@testable import MoeVoice

// The voice reliability fixes of 2026-10-15, each against the incident in
// moe.log that it answers. Every number here is a measurement from that
// log, not a constant chosen to agree with the code.

private let forceEndpoint = #"{"type":"ForceEndpoint"}"#

private func final(_ order: Int, _ text: String) -> String {
    #"{"type":"Turn","turn_order":\#(order),"transcript":"\#(text)","end_of_turn":true,"turn_is_formatted":true,"end_of_turn_confidence":1,"words":[{"text":"x","confidence":0.9,"start":0,"end":1,"word_is_final":true}]}"#
}

private func partial(_ order: Int, _ text: String) -> String {
    #"{"type":"Turn","turn_order":\#(order),"transcript":"\#(text)","end_of_turn":false,"turn_is_formatted":false,"end_of_turn_confidence":0,"words":[]}"#
}

/// Ten times faster than real: the 1 s quiet wait is 100 ms, the 2.5 s
/// live grace 250 ms — room enough that a scheduler hiccup cannot pass a
/// broken rule or fail a sound one.
private let fastSleep: AssemblyAIStream.Sleeper = { s in
    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 100_000_000))
}
private let realSleep: AssemblyAIStream.Sleeper = { s in
    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
}
private let url = URL(string: "wss://example.test/v3/ws?sample_rate=16000&token=T")!

private func frame() -> [Float] { [Float](repeating: 0.1, count: 512) }   // 32 ms

private func waitUntil(_ what: String, tries: Int = 400, _ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<tries {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out waiting for \(what)")
}

/// A socket that answers each ForceEndpoint with what `answers` says, after
/// the delay it says (real milliseconds).
private func scriptedFactory(_ answers: [(delayMs: UInt64, messages: [String])]) -> FakeFactory {
    let factory = FakeFactory()
    factory.make = {
        let s = FakeSocket()
        let n = Counter()
        s.onSend = { frame in
            guard frame == .text(forceEndpoint) else { return [] }
            let k = n.next() - 1
            guard k < answers.count else { return [] }
            let (delay, messages) = answers[k]
            Task {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                for m in messages { s.push(m) }
            }
            return []
        }
        return s
    }
    return factory
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func contains(_ s: String) -> Bool { lock.lock(); defer { lock.unlock() }; return lines.contains { $0.contains(s) } }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if open { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }
    func release() {
        lock.lock(); open = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - A. A slow network is not silence

struct LateOpenIsNotSilenceTests {

    /// 2026-10-01 02:45:50: the credential took 5646 ms, so the session
    /// opened with 8.9 s of the turn waiting, all of it went up in one burst
    /// just before the force-end, and the read was called silent one second
    /// later. The final was coming; it needed the server to read the burst.
    @Test func aSessionThatOpenedLateWaitsForTheBurstToBeRead() async throws {
        // The final lands 3 s (scaled) after the force-end: past the 1 s
        // quiet wait, well inside 4 + 8.9 / 1.25 s.
        let factory = scriptedFactory([(300, [final(0, "how does that reconcile it")])])
        let stream = AssemblyAIStream(
            factory: factory,
            connection: {
                try await Task.sleep(nanoseconds: 80_000_000)        // the slow mint
                return AssemblyAIConnection(socketURL: url, authorization: nil)
            },
            sleep: fastSleep)
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<278 { let f = frame(); all += f; stream.feedLive(f) }   // 8.9 s, before the open
        stream.claimLiveTurn()
        stream.endLiveTurn()
        stream.markTurnBoundary()
        let result = try await stream.transcribe(samples16k: all, context: .init())
        #expect(result.text == "how does that reconcile it")
    }

    /// 2026-10-02 00:33:43: "Fifty dollars" at level 0.066, the session open
    /// and in real time, no partial back by the force-end. The Mac heard a
    /// voice, so the cloud's silence is waited out, not believed.
    @Test func whenTheMacHeardAVoiceNoWordsBackYetIsNotSilence() async throws {
        // 1.5 s (scaled): past the quiet wait, inside the live grace.
        let factory = scriptedFactory([(170, [final(0, "Fifty dollars.")])])
        let stream = AssemblyAIStream(factory: factory,
                                      connection: { AssemblyAIConnection(socketURL: url, authorization: nil) },
                                      sleep: fastSleep)
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        stream.markTurnBoundary()
        let result = try await stream.transcribe(samples16k: all, context: .init(), localHeardSpeech: true)
        #expect(result.text == "Fifty dollars.")
    }

    /// The other side of it: the room was quiet to the Mac as well, and the
    /// one-second answer stands.
    @Test func whenTheMacHeardNothingEitherItIsStillNothingHeard() async throws {
        let factory = scriptedFactory([(170, [final(0, "Fifty dollars.")])])
        let stream = AssemblyAIStream(factory: factory,
                                      connection: { AssemblyAIConnection(socketURL: url, authorization: nil) },
                                      sleep: fastSleep)
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        stream.markTurnBoundary()
        await #expect(throws: AssemblyAIError.heardNothing(afterSeconds: AssemblyAIStream.quietFinalSeconds)) {
            _ = try await stream.transcribe(samples16k: all, context: .init(), localHeardSpeech: false)
        }
    }

    @Test func theRuleInNumbers() {
        // 8.9 s still unread: read like a batch.
        let late = AssemblyAIStream.liveWait(serverHeardWords: false, backlogSeconds: 8.9,
                                             localHeardSpeech: false, finalGrace: 4)
        #expect(!late.quiet)
        #expect(abs(late.deadline - (4 + 8.9 / 1.25)) < 0.001)
        // Real time, nothing heard by anyone: the quick answer.
        #expect(AssemblyAIStream.liveWait(serverHeardWords: false, backlogSeconds: 0.1,
                                          localHeardSpeech: false, finalGrace: 4)
                == .init(deadline: AssemblyAIStream.quietFinalSeconds, quiet: true))
        // Real time, the Mac heard a voice: the live grace, and no shortcut.
        #expect(AssemblyAIStream.liveWait(serverHeardWords: false, backlogSeconds: 0.1,
                                          localHeardSpeech: true, finalGrace: 4)
                == .init(deadline: 2.5, quiet: false))
    }

    /// The levels of the 15 turns the cloud called silent, 10-01 → 10-13.
    @Test func theVoiceLevelSplitsTheMeasuredTurns() {
        let reallySilent: [Float] = [0.002, 0.001, 0.001, 0.001, 0.011, 0.002, 0.000, 0.006, 0.005, 0.001, 0.001]
        let speech: [Float] = [0.052, 0.066]
        for l in reallySilent { #expect(!QuietTurnPolicy.voiceIsPresent(rms: l), "level \(l)") }
        for l in speech { #expect(QuietTurnPolicy.voiceIsPresent(rms: l), "level \(l)") }
    }
}

// MARK: - C. Nothing on the wire waits behind something it does not need

struct DiscardAndMeterDoNotBlockTheReadTests {

    /// 2026-10-02 00:33:44 → 00:33:58: a read the cloud gave up on at once
    /// came back 13.3 s later — its teardown was awaiting the usage report,
    /// a request to an edge that was timing out that night.
    @Test func aFailedReadDoesNotWaitForTheMeter() async throws {
        let gate = Gate()
        let factory = FakeFactory()                         // answers nothing
        let stream = AssemblyAIStream(factory: factory,
                                      connection: { AssemblyAIConnection(socketURL: url, authorization: nil) },
                                      sleep: fastSleep,
                                      usage: { _, _ in await gate.wait() })   // the edge, not answering
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        stream.markTurnBoundary()
        let done = Flag()
        let read = Task {
            _ = try? await stream.transcribe(samples16k: all, context: .init())
            done.set()
        }
        try await waitUntil("the read to come back with the meter still out", tries: 200) { done.isSet }
        gate.release()
        _ = await read.value
    }

    /// A discard waiting for its final while a read waits for the wire: the
    /// read goes first. With the final never coming, the old discard held
    /// the read the whole discard grace (1 s, real time here).
    @Test func aWaitingReadIsNotHeldBehindADiscard() async throws {
        let factory = scriptedFactory([
            (60_000, []),                                   // the discard's final: never
            (0, [final(1, "fresh words")]),                 // the read's
        ])
        let stream = AssemblyAIStream(factory: factory,
                                      connection: { AssemblyAIConnection(socketURL: url, authorization: nil) },
                                      sleep: realSleep)
        stream.beginLiveTurn(context: .init())
        for _ in 0..<16 { stream.feedLive(frame()) }         // 512 ms, abandoned
        try await waitUntil("five frames") { factory.last?.datas.count == 5 }
        factory.last?.push(partial(0, "stale words"))
        try await Task.sleep(nanoseconds: 20_000_000)
        stream.endLiveTurn()
        try await waitUntil("the discard's force-end") { factory.last?.texts.count == 1 }
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        stream.markTurnBoundary()
        let began = Date()
        let result = try await stream.transcribe(samples16k: all, context: .init())
        let took = Date().timeIntervalSince(began)
        #expect(result.text == "fresh words")
        #expect(took < 0.7, "the read waited \(took) s behind the discard")
    }

    /// When the discard stops waiting early, its final can still land in the
    /// middle of the read. It is the abandoned words, and must not be read
    /// as the start of the next turn.
    @Test func theDiscardedFinalArrivingLateIsNotTheReadsWords() async throws {
        let factory = scriptedFactory([
            (100, [final(0, "stale words")]),               // lands inside the read's settle
            (0, [final(1, "fresh words")]),
        ])
        let stream = AssemblyAIStream(factory: factory,
                                      connection: { AssemblyAIConnection(socketURL: url, authorization: nil) },
                                      sleep: realSleep)
        stream.beginLiveTurn(context: .init())
        for _ in 0..<16 { stream.feedLive(frame()) }
        try await waitUntil("five frames") { factory.last?.datas.count == 5 }
        factory.last?.push(partial(0, "stale words"))
        try await Task.sleep(nanoseconds: 20_000_000)
        stream.endLiveTurn()
        try await waitUntil("the discard's force-end") { factory.last?.texts.count == 1 }
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        stream.markTurnBoundary()
        let result = try await stream.transcribe(samples16k: all, context: .init())
        #expect(result.text == "fresh words")
    }

    /// The double-tap of 00:33:44: a discard queued behind a read that then
    /// failed and closed the session. It used to go ahead on the socket it
    /// had captured before waiting — force-ending a closed session.
    @Test func aDiscardWhoseSessionClosedWhileItWaitedSendsNothing() async throws {
        let factory = FakeFactory()                         // answers nothing: the read fails quiet
        let logs = LogLines()
        let stream = AssemblyAIStream(factory: factory,
                                      connection: { AssemblyAIConnection(socketURL: url, authorization: nil) },
                                      sleep: { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 100_000_000)) },
                                      log: { logs.add($0) })
        stream.beginLiveTurn(context: .init())
        var all: [Float] = []
        for _ in 0..<10 { let f = frame(); all += f; stream.feedLive(f) }
        try await waitUntil("three frames") { factory.last?.datas.count == 3 }
        stream.markTurnBoundary()
        let socket = try #require(factory.last)
        let read = Task { _ = try? await stream.transcribe(samples16k: all, context: .init()) }
        try await waitUntil("the read's force-end") { socket.texts.count == 1 }
        // A hold begins and is double-tapped away while the read is out.
        stream.beginLiveTurn(context: .init())
        for _ in 0..<16 { stream.feedLive(frame()) }
        stream.endLiveTurn()
        _ = await read.value
        try await waitUntil("the discard to give up") { logs.contains("discard dropped") }
        #expect(socket.texts.filter { $0 == forceEndpoint }.count == 1, "\(socket.texts)")
    }
}

// MARK: - D. A live final that is not coming is not waited for four seconds

struct LiveFinalGraceTests {

    /// 499 live reads to 10-15: median 317 ms, p99 1.75 s, four over 2.5 s.
    @Test func aLiveTurnWaitsTheMeasuredGraceNotTheBatchOne() {
        #expect(AssemblyAIStream.liveFinalGraceSeconds == 2.5)
        let w = AssemblyAIStream.liveWait(serverHeardWords: true, backlogSeconds: 0.05,
                                          localHeardSpeech: true, finalGrace: 4)
        #expect(w == .init(deadline: 2.5, quiet: false))
    }
}

// MARK: - B. A credential is always to hand while the wake word listens

struct CredentialPrefetchTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The old loop stopped five minutes after a warm-up; with "Hey Moe" on,
    /// the next turn then paid the mint — 5646 ms on 10-01 02:45:50.
    @Test func pastTheWindowItKeepsMintingWhileTheWakeWordIsOn() {
        let past = t0.addingTimeInterval(-1)
        #expect(CredentialPrefetch.next(now: t0, windowUntil: past, wakeWordOn: true, sessionOpen: false,
                                        heldExpiresAt: nil, failuresInARow: 0, lastFailureAt: nil) == .mint)
        #expect(CredentialPrefetch.next(now: t0, windowUntil: past, wakeWordOn: false, sessionOpen: false,
                                        heldExpiresAt: nil, failuresInARow: 0, lastFailureAt: nil) == .stop)
    }

    /// One edge request per token lifetime: a token with time left is kept.
    @Test func aFreshTokenIsKeptAndOneNearlySpentIsReplaced() {
        let fresh = CredentialPrefetch.next(now: t0, windowUntil: t0, wakeWordOn: true, sessionOpen: false,
                                            heldExpiresAt: t0.addingTimeInterval(59), failuresInARow: 0, lastFailureAt: nil)
        #expect(fresh == .wait(5))
        #expect(CredentialPrefetch.next(now: t0, windowUntil: t0, wakeWordOn: true, sessionOpen: false,
                                        heldExpiresAt: t0.addingTimeInterval(14), failuresInARow: 0, lastFailureAt: nil) == .mint)
    }

    @Test func nothingIsMintedWhileASessionIsOpen() {
        #expect(CredentialPrefetch.next(now: t0, windowUntil: t0, wakeWordOn: true, sessionOpen: true,
                                        heldExpiresAt: nil, failuresInARow: 0, lastFailureAt: nil) == .wait(5))
    }

    @Test func anEdgeThatIsDownIsAskedLessAndLessOften() {
        let failed = t0.addingTimeInterval(-10)
        #expect(CredentialPrefetch.next(now: t0, windowUntil: t0, wakeWordOn: true, sessionOpen: false,
                                        heldExpiresAt: nil, failuresInARow: 1, lastFailureAt: failed) == .mint)
        #expect(CredentialPrefetch.next(now: t0, windowUntil: t0, wakeWordOn: true, sessionOpen: false,
                                        heldExpiresAt: nil, failuresInARow: 2, lastFailureAt: failed) == .wait(5))
        #expect(CredentialPrefetch.next(now: t0, windowUntil: t0, wakeWordOn: true, sessionOpen: false,
                                        heldExpiresAt: nil, failuresInARow: 9, lastFailureAt: t0.addingTimeInterval(-59)) == .wait(1))
    }
}

// MARK: - G. No token or reply text in the log

struct RedactionTests {

    /// The shape of the 35 lines in moe.log, 09-23 → 10-02 (token and reply
    /// replaced with stand-ins).
    static let failing = "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&speech_model=universal-3-5-pro&mode=max_accuracy&token=SECRETTOKEN123&encoding=pcm_s16le&language_codes=%5B%22en%22%5D&agent_context=I%27m%20pulling%20up%20your%20flight%20tickets"

    static var posix57: NSError {
        NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: [
            NSLocalizedDescriptionKey: "Socket is not connected",
            NSURLErrorFailingURLStringErrorKey: failing,
            NSURLErrorFailingURLErrorKey: URL(string: failing)!,
        ])
    }

    @Test func aFoundationErrorKeepsItsCodeAndLosesItsURL() {
        let s = AssemblyAIRedact.describe(Self.posix57)
        #expect(s.contains("57"))
        #expect(s.contains("Socket is not connected"))
        #expect(!s.contains("SECRETTOKEN123"))
        #expect(!s.contains("agent_context"))
        #expect(!s.contains("flight"))
    }

    @Test func aCloseReasonCarryingTheErrorIsScrubbedToo() {
        let closed = AssemblyAIError.closed(code: 0, reason: "\(Self.posix57)")
        let s = AssemblyAIRedact.describe(closed)
        #expect(s.hasPrefix("socket closed 0"))
        #expect(!s.contains("SECRETTOKEN123"))
        #expect(!s.contains("flight"))
        #expect(s.contains("wss://streaming.assemblyai.com/…"))
    }

    @Test func aBareTokenParameterIsCut() {
        #expect(AssemblyAIRedact.scrub("token=abc.def&x=1") == "token=…&x=1")
    }
}

// MARK: - C. A read that comes back after a stop is nobody's

struct StaleReadTests {

    @Test func aTurnStoppedWhileBeingReadNoLongerAwaitsItsTranscript() {
        var m = VoiceMachine()
        m.tuning.conversation = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("fifty dollars"))
        #expect(m.state == .deciding(.hotkey, turn: 1))
        #expect(m.awaitsTranscript(turn: 1))
        #expect(!m.awaitsTranscript(turn: 2))
        _ = m.handle(.stopAll)
        #expect(!m.awaitsTranscript(turn: 1))
    }
}
