import Foundation
import Testing
@testable import MoeVoice

/// The cloud voice's socket protocol, against a fake socket. No network:
/// every rule that decides how fast the first word arrives, what a barge-in
/// costs, and when Moe gives up and speaks locally is exercised here.
struct InworldSessionTests {

    // MARK: - A fake socket

    /// Records what was sent; the test pushes what the server "says".
    final class FakeSocket: InworldSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [String] = []
        private var _closed = false
        private var _failSends = false
        private let feed: AsyncStream<String>.Continuation
        private var iterator: AsyncStream<String>.Iterator

        init() {
            let (stream, continuation) = AsyncStream<String>.makeStream()
            feed = continuation
            iterator = stream.makeAsyncIterator()
        }

        var sent: [String] { lock.withLock { _sent } }
        var closed: Bool { lock.withLock { _closed } }
        var failSends: Bool {
            get { lock.withLock { _failSends } }
            set { lock.withLock { _failSends = newValue } }
        }

        struct SendFailed: Error {}
        struct Gone: Error {}

        func send(_ text: String) async throws {
            if failSends { throw SendFailed() }
            lock.withLock { _sent.append(text) }
        }

        func receive() async throws -> String {
            guard let next = await iterator.next() else { throw Gone() }
            return next
        }

        func close() { lock.withLock { _closed = true }; feed.finish() }

        /// A ping on a connection that died behind a proxy: never answered.
        private var _pingHangs = false
        var pingHangs: Bool {
            get { lock.withLock { _pingHangs } }
            set { lock.withLock { _pingHangs = newValue } }
        }
        func ping() async throws {
            if pingHangs { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }

        /// The server speaks.
        func push(_ text: String) { feed.yield(text) }
        /// The connection drops under the reader.
        func drop() { feed.finish() }

        /// Messages sent, as JSON objects.
        var sentObjects: [[String: Any]] {
            sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func sent(withKey key: String) -> [[String: Any]] { sentObjects.filter { $0[key] != nil } }
    }

    /// Hands out fake sockets, counting connections; can refuse the first N.
    final class Factory: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sockets: [FakeSocket] = []
        private(set) var credentialsAsked = 0
        var refuseFirst = 0
        struct Refused: Error {}

        var credential: InworldCredentialSource {
            { [self] in
                lock.withLock { credentialsAsked += 1 }
                return InworldCredential(socketURL: URL(string: "wss://example.invalid/tts")!, token: "t")
            }
        }
        var open: InworldSocketFactory {
            { [self] _ in
                let n = lock.withLock { sockets.count }
                if n < refuseFirst {
                    lock.withLock { sockets.append(FakeSocket()) }   // counts the attempt
                    throw Refused()
                }
                let s = FakeSocket()
                lock.withLock { sockets.append(s) }
                return s
            }
        }
        var last: FakeSocket { sockets.last! }
        func session() -> InworldSession { InworldSession(credentials: credential, openSocket: open) }
    }

    // MARK: - Server messages

    static func chunk(_ samples: [Int16], context: String? = nil) -> String {
        var data = Data()
        for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        var result: [String: Any] = ["audioChunk": ["audioContent": data.base64EncodedString()]]
        if let context { result["contextId"] = context }
        return json(["result": result])
    }
    static func event(_ name: String, context: String? = nil) -> String {
        var result: [String: Any] = [name: [String: String]()]
        if let context { result["contextId"] = context }
        return json(["result": result])
    }
    static func json(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }

    // MARK: - Decoding

    @Test func base64Pcm16DecodesToFloats() {
        let event = InworldWire.parse(Self.chunk([0, 32767, -32768, 16384], context: "c1"))
        guard case .audioChunk(let id, let pcm) = event else {
            Issue.record("parsed \(event), not an audio chunk"); return
        }
        #expect(id == "c1")
        let floats = InworldWire.pcm16ToFloats(pcm)
        #expect(floats.count == 4)
        #expect(floats[0] == 0)
        #expect(abs(floats[1] - 32767.0 / 32768.0) < 1e-6)
        #expect(floats[2] == -1)
        #expect(floats[3] == 0.5)
    }

    @Test func serverEventsParse() {
        #expect(InworldWire.parse(Self.event("contextCreated", context: "a")) == .contextCreated("a"))
        #expect(InworldWire.parse(Self.event("flushCompleted", context: "a")) == .flushCompleted("a"))
        #expect(InworldWire.parse(Self.event("contextClosed", context: "a")) == .contextClosed("a"))
        #expect(InworldWire.parse(#"{"error":{"code":16,"message":"unauthenticated"}}"#) == .error("unauthenticated"))
        #expect(InworldWire.parse(#"{"result":{"status":{"code":3,"message":"bad voice"}}}"#) == .error("bad voice"))
        #expect(InworldWire.parse(#"{"done":true}"#) == .other)
        #expect(InworldWire.parse("not json") == .other)
    }

    /// The shapes Inworld's own examples send: snake_case, `flush_context`
    /// an object, PCM at the session's rate, the model verified today.
    @Test func messagesMatchTheDocumentedShapes() throws {
        let create = try #require(try JSONSerialization.jsonObject(
            with: Data(InworldWire.create(contextId: "c", voice: "Ashley", model: InworldWire.modelId,
                                          sampleRate: 24_000).utf8)) as? [String: Any])
        #expect(create["context_id"] as? String == "c")
        let body = try #require(create["create"] as? [String: Any])
        #expect(body["voice_id"] as? String == "Ashley")
        #expect(body["model_id"] as? String == "inworld-tts-2-flash")
        // A steadier temperature than the 1.0 default — and no auto_mode:
        // under it the server may flush on its own, and a render ends on the
        // first flushCompleted, so a passage could be cut after its first
        // server chunk (review H1). One explicit flush per passage.
        #expect(body["temperature"] as? Double == 0.8)
        #expect(body["auto_mode"] == nil)
        let audio = try #require(body["audio_config"] as? [String: Any])
        #expect(audio["audio_encoding"] as? String == "PCM")
        #expect(audio["sample_rate_hertz"] as? Int == 24_000)

        let send = try #require(try JSONSerialization.jsonObject(
            with: Data(InworldWire.sendText(contextId: "c", text: "Hello.").utf8)) as? [String: Any])
        let sendBody = try #require(send["send_text"] as? [String: Any])
        #expect(sendBody["text"] as? String == "Hello.")
        #expect(sendBody["flush_context"] is [String: Any], "flush_context is a message, not a boolean")

        let close = try #require(try JSONSerialization.jsonObject(
            with: Data(InworldWire.closeContext(contextId: "c").utf8)) as? [String: Any])
        #expect(close["close_context"] is [String: Any])
    }

    // MARK: - Time to first audio

    /// The first chunk reaches the consumer before `flushCompleted` exists —
    /// the stream is audio as it arrives, not a render handed over at the
    /// end. And the path to it is create + send_text, pipelined, with no
    /// wait for `contextCreated`.
    @Test func firstChunkArrivesBeforeTheFlushCompletes() async throws {
        let factory = Factory()
        let session = factory.session()
        let stream = try await session.stream("Hello.", voice: "Ashley")
        let socket = factory.last

        // Sent without waiting for any acknowledgement.
        #expect(socket.sent(withKey: "create").count == 1)
        #expect(socket.sent(withKey: "send_text").count == 1)
        let contextId = try #require(socket.sent(withKey: "create").first?["context_id"] as? String)

        var iterator = stream.makeAsyncIterator()
        socket.push(Self.event("contextCreated", context: contextId))
        socket.push(Self.chunk([16384, -16384], context: contextId))
        let first = try await iterator.next()
        #expect(first == [0.5, -0.5])
        // Only now does the server say the flush is done.
        socket.push(Self.chunk([0], context: contextId))
        socket.push(Self.event("flushCompleted", context: contextId))
        #expect(try await iterator.next() == [0])
        #expect(try await iterator.next() == nil)
    }

    /// The second sentence reuses the context: one create on the wire, two
    /// send_texts. That is the lowest-message path to the next first word.
    @Test func aSecondSentenceReusesTheContext() async throws {
        let factory = Factory()
        let session = factory.session()
        let first = try await session.stream("One.", voice: "Ashley")
        let socket = factory.last
        let contextId = try #require(socket.sent(withKey: "create").first?["context_id"] as? String)
        socket.push(Self.event("flushCompleted", context: contextId))
        for try await _ in first {}

        _ = try await session.stream("Two.", voice: "Ashley")
        #expect(socket.sent(withKey: "create").count == 1)
        #expect(socket.sent(withKey: "send_text").count == 2)
        #expect(factory.sockets.count == 1, "one warm socket, not one per sentence")
        #expect(factory.credentialsAsked == 1, "a single-use token is minted once per connection")
    }

    /// A different voice is a different context.
    @Test func changingVoiceClosesAndRecreatesTheContext() async throws {
        let factory = Factory()
        let session = factory.session()
        _ = try await session.stream("One.", voice: "Ashley")
        let socket = factory.last
        _ = try await session.stream("Two.", voice: "Clive")
        #expect(socket.sent(withKey: "close_context").count == 1)
        let creates = socket.sent(withKey: "create")
        #expect(creates.count == 2)
        #expect((creates.last?["create"] as? [String: Any])?["voice_id"] as? String == "Clive")
    }

    // MARK: - Cancel

    /// A barge-in: the context is closed so the server stops generating,
    /// the stream ends without waiting for the server, and the next
    /// sentence starts a fresh context.
    @Test func cancelClosesTheContextAndEndsTheStream() async throws {
        let factory = Factory()
        let session = factory.session()
        let stream = try await session.stream("A long sentence that gets interrupted.", voice: "Ashley")
        let socket = factory.last
        let contextId = try #require(socket.sent(withKey: "create").first?["context_id"] as? String)

        var iterator = stream.makeAsyncIterator()
        socket.push(Self.chunk([1000], context: contextId))
        _ = try await iterator.next()

        let ms = await session.cancel()
        #expect(ms != nil && ms! >= 0)
        let closes = socket.sent(withKey: "close_context")
        #expect(closes.count == 1)
        #expect(closes.first?["context_id"] as? String == contextId)
        // Ended — without a flushCompleted ever arriving.
        #expect(try await iterator.next() == nil)
        // Nothing running: a second cancel has nothing to report.
        #expect(await session.cancel() == nil)

        // Late audio for the closed context is dropped, and the next
        // sentence gets a new context on the same socket.
        socket.push(Self.chunk([1000], context: contextId))
        let next = try await session.stream("Next.", voice: "Ashley")
        let creates = socket.sent(withKey: "create")
        #expect(creates.count == 2)
        let newId = try #require(creates.last?["context_id"] as? String)
        #expect(newId != contextId)
        var it2 = next.makeAsyncIterator()
        socket.push(Self.chunk([2000], context: newId))
        #expect(try await it2.next() == [Float(2000) / 32768])
        #expect(factory.sockets.count == 1)
    }

    /// Dropping the iterator — what SpeechOut's pump does when its
    /// generation moves on — also stops the server.
    @Test func abandoningTheStreamClosesTheContext() async throws {
        let factory = Factory()
        let session = factory.session()
        do {
            let stream = try await session.stream("Abandoned.", voice: "Ashley")
            var iterator = stream.makeAsyncIterator()
            factory.last.push(Self.chunk([1]))
            _ = try await iterator.next()
        }
        // onTermination fires asynchronously; give it a moment.
        for _ in 0..<50 where factory.last.sent(withKey: "close_context").isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(factory.last.sent(withKey: "close_context").count == 1)
    }

    // MARK: - Reconnect once, then a typed error

    @Test func oneRefusedConnectionIsRetriedWithAFreshCredential() async throws {
        let factory = Factory()
        factory.refuseFirst = 1
        let session = factory.session()
        _ = try await session.stream("Hello.", voice: "Ashley")
        #expect(factory.sockets.count == 2)
        #expect(factory.credentialsAsked == 2, "single-use tokens: a fresh one per attempt")
        #expect(factory.last.sent(withKey: "send_text").count == 1)
    }

    @Test func twoRefusedConnectionsIsUnreachable() async throws {
        let factory = Factory()
        factory.refuseFirst = 10
        let session = factory.session()
        await #expect(throws: InworldError.self) {
            _ = try await session.stream("Hello.", voice: "Ashley")
        }
        #expect(factory.sockets.count == 2, "two attempts, not ten")
        // And it is the typed error the caller falls back on.
        do {
            _ = try await session.stream("Again.", voice: "Ashley")
            Issue.record("connected against a factory that refuses everything")
        } catch let error as InworldError {
            guard case .unreachable = error else { Issue.record("wrong case: \(error)"); return }
        }
    }

    /// The credential source's own error is not retried and not rewrapped:
    /// "allowance spent" has to arrive at the caller as itself.
    @Test func aCredentialErrorPassesThroughUntouched() async throws {
        struct AllowanceSpent: Error, Equatable {}
        let session = InworldSession(credentials: { throw AllowanceSpent() },
                                     openSocket: { _ in FakeSocket() })
        await #expect(throws: AllowanceSpent.self) {
            _ = try await session.stream("Hello.", voice: "Ashley")
        }
    }

    /// A socket that dies mid-sentence fails that sentence with a typed
    /// error (SpeechOut re-renders it locally), and the next sentence gets
    /// a new connection rather than the corpse of the old one.
    @Test func aConnectionLostMidSentenceFailsItAndReconnectsForTheNext() async throws {
        let factory = Factory()
        let session = factory.session()
        let stream = try await session.stream("Cut off.", voice: "Ashley")
        let dead = factory.last
        var iterator = stream.makeAsyncIterator()
        dead.push(Self.chunk([1]))
        _ = try await iterator.next()
        dead.drop()
        do {
            _ = try await iterator.next()
            Issue.record("the stream ended cleanly on a dropped connection")
        } catch let error as InworldError {
            guard case .connectionLost = error else { Issue.record("wrong case: \(error)"); return }
        }
        _ = try await session.stream("Next.", voice: "Ashley")
        #expect(factory.sockets.count == 2)
        #expect(factory.last.sent(withKey: "create").count == 1)
    }

    /// A send that fails on a socket the reader has not yet noticed is dead
    /// is retried once on a new connection.
    @Test func aFailedSendReconnectsOnce() async throws {
        let factory = Factory()
        let session = factory.session()
        _ = try await session.stream("One.", voice: "Ashley")
        let stale = factory.last
        stale.failSends = true
        _ = try await session.stream("Two.", voice: "Ashley")
        #expect(factory.sockets.count == 2)
        #expect(stale.closed)
        #expect(factory.last.sent(withKey: "create").count == 1)
        #expect(factory.last.sent(withKey: "send_text").count == 1)
    }

    // MARK: - Re-warm when a turn starts

    /// A clock the test moves.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
        var source: @Sendable () -> Date { { [self] in now } }
    }

    /// Inworld closes a socket after 10 idle minutes. A turn starting after
    /// that replaces it while the person talks, so the reply's first render
    /// finds a fresh socket — the render after a fresh mint measured
    /// 789–2405 ms against ~111 ms warm (inworld-optimise.md §2).
    @Test func aTurnAfterTenIdleMinutesReplacesTheSocket() async throws {
        let factory = Factory()
        let clock = Clock()
        let session = InworldSession(credentials: factory.credential, openSocket: factory.open, now: clock.source)
        try await session.connect()
        let old = factory.last
        clock.advance(10 * 60)
        #expect(try await session.prepareForTurn() == .reopened(idleSeconds: 600))
        #expect(factory.sockets.count == 2)
        #expect(old.closed)
        // The reply renders on the socket opened for it, with no second mint.
        _ = try await session.stream("Hello.", voice: "Ashley")
        #expect(factory.sockets.count == 2)
        #expect(factory.credentialsAsked == 2)
        #expect(factory.last.sent(withKey: "send_text").count == 1)
    }

    /// A socket in recent use is left alone: a re-warm is free only when it
    /// does nothing.
    @Test func aTurnSoonAfterTheLastOneKeepsTheSocket() async throws {
        let factory = Factory()
        let clock = Clock()
        let session = InworldSession(credentials: factory.credential, openSocket: factory.open, now: clock.source)
        _ = try await session.stream("One.", voice: "Ashley")
        clock.advance(8 * 60)
        #expect(try await session.prepareForTurn() == .warm)
        #expect(factory.sockets.count == 1)
        #expect(!factory.last.closed)
    }

    /// Activity is what the server counts, received messages included: a
    /// reply that streamed until a minute ago is not idle.
    @Test func receivedAudioCountsAsActivity() async throws {
        let factory = Factory()
        let clock = Clock()
        let session = InworldSession(credentials: factory.credential, openSocket: factory.open, now: clock.source)
        let stream = try await session.stream("One.", voice: "Ashley")
        clock.advance(8 * 60)
        factory.last.push(Self.chunk([1]))
        factory.last.push(Self.event("flushCompleted"))
        for try await _ in stream {}
        clock.advance(2 * 60)
        #expect(try await session.prepareForTurn() == .warm)
        #expect(factory.sockets.count == 1)
    }

    /// A socket the server already closed (the reader saw it go) is reopened
    /// at turn start, not on the first sentence of the reply.
    @Test func aClosedSocketIsReopenedAtTurnStart() async throws {
        let factory = Factory()
        let session = factory.session()
        try await session.connect()
        factory.last.drop()
        for _ in 0..<100 where await session.isConnected {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await !session.isConnected)
        #expect(try await session.prepareForTurn() == .opened)
        #expect(factory.sockets.count == 2)
        #expect(await session.isConnected)
    }

    /// A render that did not get a re-warm (▶ on a typed reply) still does
    /// not trust a socket past the idle limit.
    @Test func aRenderOnAnIdledSocketReconnectsFirst() async throws {
        let factory = Factory()
        let clock = Clock()
        let session = InworldSession(credentials: factory.credential, openSocket: factory.open, now: clock.source)
        try await session.connect()
        let old = factory.last
        clock.advance(11 * 60)
        _ = try await session.stream("Hello.", voice: "Ashley")
        #expect(old.closed)
        #expect(old.sent(withKey: "send_text").isEmpty)
        #expect(factory.last.sent(withKey: "send_text").count == 1)
    }

    /// A re-warm and the render right behind it share one connection attempt
    /// rather than minting two tokens and leaking a socket.
    @Test func aRewarmAndARenderShareOneConnect() async throws {
        let factory = Factory()
        let session = factory.session()
        async let warm = session.prepareForTurn()
        async let render = session.stream("Hello.", voice: "Ashley")
        _ = try await (warm, render)
        #expect(factory.sockets.count == 1)
        #expect(factory.credentialsAsked == 1)
    }

    /// The server rejecting a render surfaces as `rejected`, and the next
    /// sentence does not trust the old context.
    @Test func aServerErrorFailsTheSentence() async throws {
        let factory = Factory()
        let session = factory.session()
        let stream = try await session.stream("Bad.", voice: "Nobody")
        let socket = factory.last
        socket.push(#"{"error":{"code":3,"message":"voice not found"}}"#)
        await #expect(throws: InworldError.rejected("voice not found")) {
            for try await _ in stream {}
        }
        _ = try await session.stream("Again.", voice: "Nobody")
        #expect(socket.sent(withKey: "create").count == 2)
    }

    // MARK: - A dead socket found before the reply needs it

    /// 2026-09-25 18:22: a socket that had died behind the Mac's filter proxy
    /// held the reply's first word for 36 s, and a fresh one opened a second
    /// later worked. The turn-start check pings it while the person talks.
    @Test func aTurnReplacesASocketThatDoesNotAnswerAPing() async throws {
        let factory = Factory()
        let session = InworldSession(credentials: factory.credential, openSocket: factory.open)
        try await session.connect()
        let first = try #require(factory.sockets.first)
        first.pingHangs = true
        let began = Date()
        let result = try await session.prepareForTurn()
        #expect(result == .replacedDead)
        #expect(Date().timeIntervalSince(began) < InworldSession.pingTimeout + 1,
                "the check must give up on the ping, not wait for it")
        #expect(first.closed)
        #expect(factory.sockets.count == 2)
    }

    @Test func aSocketThatAnswersIsKept() async throws {
        let factory = Factory()
        let session = InworldSession(credentials: factory.credential, openSocket: factory.open)
        try await session.connect()
        #expect(try await session.prepareForTurn() == .warm)
        #expect(factory.sockets.count == 1)
    }
}

