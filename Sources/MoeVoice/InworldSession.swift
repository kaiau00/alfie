import Foundation

/// The wire half of Moe's cloud voice: Inworld's bidirectional TTS socket,
/// as a state machine over an abstract socket so every rule here is a test
/// rather than a network call.
///
/// Shapes verified 2026-09-06 against Inworld's own low-latency example
/// (`inworld-api-examples/tts/js/example_tts_low_latency_ws.js`) and the
/// API reference (`docs.inworld.ai/api-reference/ttsAPI/texttospeech/
/// synthesize-speech-websocket`):
///
///     → {"context_id": …, "create": {"voice_id", "model_id", "audio_config":
///           {"audio_encoding": "PCM", "sample_rate_hertz": 24000}}}
///     → {"context_id": …, "send_text": {"text": …, "flush_context": {}}}
///     → {"context_id": …, "close_context": {}}
///     ← {"result": {"contextId", "contextCreated" | "audioChunk":
///           {"audioContent": <base64 PCM16 LE>} | "flushCompleted" |
///           "contextClosed" | "status"}}   or   {"error": …}
///
/// `flush_context` is a message, not a boolean — the reference says so and
/// both official examples send `{}`.
///
/// **Why one context, reused.** Inworld processes a connection's messages in
/// order, so the `create` need not be acknowledged before `send_text`
/// follows it (their latency guide, point 8). That makes a fresh context per
/// sentence cost no extra round trip — but it still costs the server a
/// context set-up per sentence, and a connection holds at most five. One
/// context per connection, created lazily and pipelined ahead of the first
/// sentence, is the fewest messages on the path to first audio; each Moe
/// sentence is then one `send_text` with a flush, and `flushCompleted` is
/// the end of that sentence's audio. Cancelling closes the context (the
/// documented way to stop generation) and the next sentence creates a new
/// one — again pipelined, so a barge-in costs nothing on the next reply.
///
/// **Why one warm socket.** Measured 2026-09-06: 118 ms text → first audio
/// on a warm connection, 332 ms cold; REST equals the socket once warm. The
/// connection *is* the latency win, so the session keeps it open across
/// sentences, reconnects when it is lost, and — because Inworld closes a
/// socket after 10 idle minutes — replaces an idle one when a voice turn
/// starts (`prepareForTurn`), while the person is still talking.

// MARK: - The socket, abstractly

/// One text frame in, one out. `URLSessionWebSocketTask` in the app; a fake
/// in the tests.
public protocol InworldSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text frame. Throws once the connection is gone.
    func receive() async throws -> String
    /// Round trip to the far end. Throws, or never returns, when the
    /// connection is gone — the session bounds it with `pingTimeout`.
    func ping() async throws
    func close()
}

extension InworldSocket {
    public func ping() async throws {}
}

/// What opening a socket needs: where, and the bearer token for the
/// `Authorization` header. Tokens are single-use, so the session asks for a
/// fresh one per connection attempt and never keeps one.
public struct InworldCredential: Sendable {
    public let socketURL: URL
    public let token: String
    public init(socketURL: URL, token: String) {
        self.socketURL = socketURL
        self.token = token
    }
}

public typealias InworldCredentialSource = @Sendable () async throws -> InworldCredential
public typealias InworldSocketFactory = @Sendable (InworldCredential) async throws -> any InworldSocket

/// The typed failures a caller falls back on. Anything thrown by the
/// credential source passes through untouched, so an entitlement or
/// allowance problem keeps its own type.
public enum InworldError: Error, Equatable {
    /// Two connection attempts in a row failed, the second with a fresh
    /// credential. The caller should speak locally.
    case unreachable(String)
    /// The connection closed while a sentence was still rendering.
    case connectionLost(String)
    /// The server answered a render with an error.
    case rejected(String)
}

// MARK: - Messages

/// What the server said, reduced to what the session acts on.
public enum InworldEvent: Equatable {
    case contextCreated(String?)
    case audioChunk(contextId: String?, pcm: Data)
    case flushCompleted(String?)
    case contextClosed(String?)
    case error(String)
    /// Acknowledgements and statuses the session has no use for.
    case other
}

public enum InworldWire {

    /// Verified accepted 2026-09-06. Inworld's latency guide puts it at
    /// 20 ms P90 to first byte server-side, five times faster than
    /// `inworld-tts-2`; Moe needs neither steering nor cloning.
    public static let modelId = "inworld-tts-2-flash"

    /// Sampling temperature. The API default is 1.0, which with Flash made
    /// the voice's character drift from one sentence to the next; Inworld's
    /// own integrations run about 0.8 for a steadier assistant.
    public static let temperature = 0.8

    public static func create(contextId: String, voice: String, model: String,
                              sampleRate: Int) -> String {
        json([
            "context_id": contextId,
            "create": [
                "voice_id": voice,
                "model_id": model,
                // No `auto_mode`. Moe sends whole passages, each with one
                // explicit flush, and ends a render on the `flushCompleted`
                // for it. Whether the server also reports its *own* flushes
                // under auto_mode is not documented; if it does, the first
                // one would end the render and drop the rest of the passage
                // (review H1). One flush per passage is provable here.
                "temperature": temperature,
                "audio_config": [
                    "audio_encoding": "PCM",
                    "sample_rate_hertz": sampleRate,
                ],
            ],
        ])
    }

    /// One sentence, flushed: the server synthesises what it has now rather
    /// than waiting for a buffer threshold.
    public static func sendText(contextId: String, text: String) -> String {
        json([
            "context_id": contextId,
            "send_text": ["text": text, "flush_context": [String: String]()],
        ])
    }

    public static func closeContext(contextId: String) -> String {
        json(["context_id": contextId, "close_context": [String: String]()])
    }

    public static func parse(_ text: String) -> InworldEvent {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .other }
        if let error = object["error"] {
            return .error(describe(error))
        }
        guard let result = object["result"] as? [String: Any] else { return .other }
        let id = result["contextId"] as? String
        if let chunk = result["audioChunk"] as? [String: Any] {
            // Both official examples read `audioChunk.audioContent` and fall
            // back to `result.audioContent`; so does this.
            let b64 = (chunk["audioContent"] as? String) ?? (result["audioContent"] as? String) ?? ""
            return .audioChunk(contextId: id, pcm: Data(base64Encoded: b64) ?? Data())
        }
        if result["flushCompleted"] != nil { return .flushCompleted(id) }
        if result["contextClosed"] != nil { return .contextClosed(id) }
        if result["contextCreated"] != nil { return .contextCreated(id) }
        if let status = result["status"] as? [String: Any],
           let code = status["code"] as? Int, code != 0 {
            return .error(describe(status))
        }
        return .other
    }

    /// 16-bit little-endian PCM to the [-1, 1) floats the player takes.
    public static func pcm16ToFloats(_ data: Data) -> [Float] {
        let n = data.count / 2
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let lo = UInt16(raw[2 * i])
                let hi = UInt16(raw[2 * i + 1])
                out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            }
        }
        return out
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ value: Any) -> String {
        if let dict = value as? [String: Any] {
            if let message = dict["message"] as? String { return message }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return String(describing: value)
    }
}

// MARK: - The session

/// What `InworldSession.prepareForTurn()` found.
public enum InworldRewarm: Equatable, Sendable {
    /// The socket is open and recently used, or a render is in flight.
    case warm
    /// There was no socket (it closed, or never opened); one is open now.
    case opened
    /// The socket had been idle for this many seconds, past the point
    /// Inworld closes it, so it was replaced before anyone needed it.
    case reopened(idleSeconds: Int)
    /// The socket looked open but did not answer a ping, so it was replaced.
    case replacedDead
}

/// The first of two racers to claim it wins; the other does nothing.
public final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    public init() {}
    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }

    /// Awaits a Foundation-style `(Error?) -> Void` completion that may be
    /// called more than once, and takes only the first call.
    ///
    /// `URLSessionWebSocketTask.sendPing` calls its handler **twice** when
    /// the socket aborts under it — once with the abort, once more as the
    /// task tears down — and a `CheckedContinuation` resumed twice is a
    /// fatal error: the whole app quit mid-reply (2026-09-29 20:02 and
    /// 2026-09-30 16:52). The second call is dropped here instead.
    public static func completion(
        _ start: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        let once = OneShot()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            start { error in
                guard once.claim() else { return }
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}

public actor InworldSession {

    /// Inworld closes a session after 10 minutes with no activity (API
    /// reference, "Limits"), and sends nothing Moe can rely on to say so. A
    /// socket older than this is treated as gone. Nine, not ten: a minute
    /// of margin for a server clock that counts from its own last message.
    public static let idleLimit: TimeInterval = 9 * 60

    /// How long a turn-start ping may take before the socket is called dead.
    /// A live one answers in a round trip (tens of milliseconds); on
    /// 2026-09-25 18:22 a socket that had died behind the Mac's filter proxy
    /// held the reply's first word for 36 s, and a fresh one opened a second
    /// later worked. Checked while the person is still talking, so the cost
    /// of being wrong is a reconnect nobody hears.
    public static let pingTimeout: TimeInterval = 1.5

    private let credentials: InworldCredentialSource
    private let openSocket: InworldSocketFactory
    private let model: String
    private let sampleRate: Int

    private var socket: (any InworldSocket)?
    /// Bumped whenever the socket is dropped, so a reader for a dead socket
    /// cannot report the loss of the one that replaced it.
    private var socketGeneration = 0
    private var reader: Task<Void, Never>?
    /// A connection being opened, so a re-warm at turn start and the reply's
    /// first render that follows it share one socket rather than minting two.
    private var connecting: Task<Void, Error>?
    /// The last message sent or received on the socket: Inworld's idle clock.
    private var lastActivity: Date?
    private let now: @Sendable () -> Date

    /// The one context on the connection, and the voice it was created
    /// with. A different voice closes it and creates another.
    private var context: (id: String, voice: String)?
    private var contextsCreated = 0

    private struct Render {
        let contextId: String
        let continuation: AsyncThrowingStream<[Float], Error>.Continuation
        let began: Date
        var chunks = 0
    }
    private var current: Render?

    public init(credentials: @escaping InworldCredentialSource,
                openSocket: @escaping InworldSocketFactory,
                model: String = InworldWire.modelId,
                sampleRate: Int = 24_000,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.openSocket = openSocket
        self.model = model
        self.sampleRate = sampleRate
        self.now = now
    }

    public var isConnected: Bool { socket != nil }

    /// Open the socket now, so the first sentence finds it warm.
    public func connect() async throws {
        try await ensureConnected()
    }

    /// A voice turn is starting: make sure the reply will find the socket
    /// warm. Called when capture opens, so the connect overlaps the person
    /// speaking rather than the wait for the reply.
    ///
    /// Measured 2026-09-23 (`~/moe-voice-notes/inworld-optimise.md` §2): the
    /// first render after a fresh mint took 789–2405 ms (15 of 19 over
    /// 0.75 s) against a warm p50 of 111 ms — and Inworld drops a socket
    /// after 10 idle minutes, which is most "Hey Moe" moments. Reconnecting
    /// only on the next render put that whole cost on the first reply.
    ///
    /// Renders nothing, so it costs no allowance; a token mint is free.
    @discardableResult
    public func prepareForTurn() async throws -> InworldRewarm {
        if current != nil { return .warm }
        if socket == nil {
            try await ensureConnected()
            return .opened
        }
        if isIdlePastLimit, let last = lastActivity {
            let idle = now().timeIntervalSince(last)
            dropSocket()
            try await ensureConnected()
            return .reopened(idleSeconds: Int(idle))
        }
        if let socket {
            let generation = socketGeneration
            if !(await Self.answers(socket, within: Self.pingTimeout)) {
                // A render may have started while the ping was out, or the
                // socket been replaced; either way it is no longer this
                // check's to drop — the render's own stall guard watches it.
                guard current == nil, generation == socketGeneration else { return .warm }
                dropSocket()
                try await ensureConnected()
                return .replacedDead
            }
        }
        return .warm
    }

    /// Whether the socket answers a ping in time. Not a task group: a ping
    /// on a dead connection may never return at all, and a group waits for
    /// every child before it returns.
    static func answers(_ socket: any InworldSocket, within seconds: TimeInterval) async -> Bool {
        let once = OneShot()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            Task {
                let ok = (try? await socket.ping()) != nil
                if once.claim() { c.resume(returning: ok) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { c.resume(returning: false) }
            }
        }
    }

    private var isIdlePastLimit: Bool {
        guard let last = lastActivity else { return false }
        return now().timeIntervalSince(last) >= Self.idleLimit
    }

    /// One sentence's audio as it arrives. Finishes on `flushCompleted`,
    /// early on `cancel()`, and throws `InworldError` when the connection
    /// or the server fails it.
    public func stream(_ text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        // One at a time: a render nobody finished consuming is over.
        if let stale = current {
            stale.continuation.finish()
            current = nil
        }
        // A socket past Inworld's idle limit is not trusted with a render:
        // one closed under us is found by the reader, but one that went
        // half-open (a sleep, a network change) takes the render with it.
        if socket != nil, isIdlePastLimit { dropSocket() }
        var attempt = 0
        while true {
            do {
                try await ensureConnected()
                guard let socket else { throw InworldError.unreachable("no socket after connect") }
                let contextId = try await ensureContext(voice: voice, on: socket)
                let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
                current = Render(contextId: contextId, continuation: continuation, began: Date())
                do {
                    try await socket.send(InworldWire.sendText(contextId: contextId, text: text))
                    lastActivity = now()
                } catch {
                    current = nil
                    throw error
                }
                // The consumer walking away (a barge-in dropped the iterator)
                // must stop the server too, not just stop listening.
                continuation.onTermination = { [weak self] reason in
                    guard case .cancelled = reason else { return }
                    Task { _ = await self?.cancel() }
                }
                return stream
            } catch let error as InworldError {
                throw error
            } catch {
                // The credential source's own errors pass through: an
                // allowance that is spent will not be less spent on retry.
                if !(error is CancellationError), attempt == 0, socket != nil {
                    dropSocket()
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    /// Stop the sentence that is rendering. Closes its context so the server
    /// stops generating, ends the stream, and returns how long the render
    /// had been running — nil when nothing was.
    @discardableResult
    public func cancel() async -> Int? {
        guard let render = current else { return nil }
        current = nil
        let ms = Int(Date().timeIntervalSince(render.began) * 1000)
        render.continuation.finish()
        if let c = context, c.id == render.contextId {
            context = nil
            try? await socket?.send(InworldWire.closeContext(contextId: c.id))
        }
        return ms
    }

    public func close() {
        if let render = current {
            render.continuation.finish()
            current = nil
        }
        dropSocket()
    }

    // MARK: Connection

    /// Connect, trying twice — the second time with a fresh credential,
    /// since tokens are single-use. Two failures is `unreachable`.
    private func ensureConnected() async throws {
        if socket != nil { return }
        if let inFlight = connecting {
            try await inFlight.value
            if socket != nil { return }
        }
        let attempt = Task { try await self.openFresh() }
        connecting = attempt
        defer { if connecting == attempt { connecting = nil } }
        try await attempt.value
    }

    private func openFresh() async throws {
        if socket != nil { return }
        var lastError: Error?
        for _ in 0..<2 {
            let credential = try await credentials()
            do {
                let opened = try await openSocket(credential)
                socket = opened
                context = nil
                lastActivity = now()
                startReader(opened)
                return
            } catch {
                lastError = error
            }
        }
        throw InworldError.unreachable(String(describing: lastError ?? InworldError.unreachable("")))
    }

    private func ensureContext(voice: String, on socket: any InworldSocket) async throws -> String {
        if let c = context, c.voice == voice { return c.id }
        if let c = context {
            context = nil
            try await socket.send(InworldWire.closeContext(contextId: c.id))
        }
        contextsCreated += 1
        let id = "moe-\(contextsCreated)-\(UUID().uuidString.prefix(8))"
        // Not awaited for `contextCreated`: messages are processed in order,
        // and waiting is a round trip added to every first sentence.
        try await socket.send(InworldWire.create(contextId: id, voice: voice, model: model,
                                                 sampleRate: sampleRate))
        context = (id, voice)
        return id
    }

    private func startReader(_ socket: any InworldSocket) {
        reader?.cancel()
        let generation = socketGeneration
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await socket.receive()
                    await self?.handle(InworldWire.parse(text))
                } catch {
                    await self?.connectionLost(error, generation: generation)
                    return
                }
            }
        }
    }

    private func dropSocket() {
        reader?.cancel()
        reader = nil
        socket?.close()
        socket = nil
        context = nil
        socketGeneration += 1
    }

    private func connectionLost(_ error: Error, generation: Int) {
        guard generation == socketGeneration else { return }
        if let render = current {
            render.continuation.finish(throwing: InworldError.connectionLost(String(describing: error)))
            current = nil
        }
        dropSocket()
    }

    // MARK: Events

    private func handle(_ event: InworldEvent) {
        lastActivity = now()
        switch event {
        case .audioChunk(let id, let pcm):
            guard let render = current, id == nil || id == render.contextId else { return }
            current?.chunks += 1
            render.continuation.yield(InworldWire.pcm16ToFloats(pcm))
        case .flushCompleted(let id):
            guard let render = current, id == nil || id == render.contextId else { return }
            render.continuation.finish()
            current = nil
        case .contextClosed(let id):
            if let render = current, id == nil || id == render.contextId {
                render.continuation.finish()
                current = nil
            }
            if let c = context, id == nil || id == c.id { context = nil }
        case .error(let message):
            if let render = current {
                render.continuation.finish(throwing: InworldError.rejected(message))
                current = nil
            }
            // Whether the server kept the context is not knowable from
            // here; the next sentence creates a fresh one, pipelined.
            context = nil
        case .contextCreated, .other:
            break
        }
    }
}
