import Foundation
import MoeVoice

/// The cloud voice: Inworld's TTS over one warm WebSocket.
///
/// Everything about the protocol — message shapes, the one reused context,
/// the reconnect-once rule, cancel-by-closing-the-context — lives in
/// `InworldSession` (Sources/MoeVoice), where it is tested against a fake
/// socket. This file is the adapter: `TtsBackend` on one side, a real
/// `URLSessionWebSocketTask` and `CloudVoice` on the other.
///
/// Why a warm connection is the whole point, measured 2026-09-06: 118 ms
/// text → first audio warm, 332 ms cold, and REST equals the socket once
/// warm. `warmUp()` therefore opens the socket rather than rendering
/// anything — a cloud warm-up that renders spends the person's allowance
/// on a sentence nobody hears.
actor InworldBackend: TtsBackend {

    nonisolated let sampleRate: Double = 24_000
    nonisolated let isCloudBackend = true

    private let credentials: any CloudVoiceCredentials
    private let session: InworldSession

    init(credentials: any CloudVoiceCredentials = CloudVoice.shared) {
        self.credentials = credentials
        self.session = InworldSession(
            credentials: {
                // Timed the same way as the ears' mint, and broken down the
                // same way, so a slow connect can be read off the log.
                let began = Date()
                let c = try await credentials.credential(for: .tts)
                Log.write("tts: inworld credential minted in \(Int(Date().timeIntervalSince(began) * 1000)) ms"
                          + (c.minted.map { " (\($0.described))" } ?? ""))
                return InworldCredential(socketURL: c.socketURL, token: c.token)
            },
            openSocket: { credential in try await URLSessionInworldSocket.open(credential) })
    }

    /// Connects. Throws when there is no credential or no route, which is
    /// what `VoiceEngine.loadVoiceBackend` falls back on.
    func warmUp() async throws {
        try await session.connect()
    }

    /// Called when capture opens (`VoiceEngine`, `.capture(true)`): a socket
    /// Inworld dropped after 10 idle minutes is replaced now, while the
    /// person talks, instead of on the reply's first sentence (0.8–2.4 s
    /// measured there, against ~111 ms warm).
    func prepareForTurn() async {
        let began = Date()
        do {
            switch try await session.prepareForTurn() {
            case .warm:
                return
            case .opened:
                Log.write("tts: inworld socket was closed — reopened for the turn in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
            case .reopened(let idle):
                Log.write("tts: inworld socket idle \(idle) s — replaced for the turn in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
            case .replacedDead:
                Log.write("tts: inworld socket did not answer a ping — replaced for the turn in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
            }
        } catch {
            // The reply's first render tries again, and falls back locally
            // if that fails too; nothing to say to the person here.
            Log.write("tts: inworld re-warm for the turn failed — \(error)")
        }
    }

    /// A render stalled: drop the socket, so the next one — or the next
    /// turn's re-warm — opens a fresh connection instead of waiting on one
    /// the proxy has quietly lost.
    func abandonConnection() async {
        await session.close()
    }

    func render(_ text: String, voice: String) async throws -> [Float] {
        var all: [Float] = []
        for try await frame in try await stream(text, voice: voice) {
            all.append(contentsOf: frame)
        }
        return all
    }

    func stream(_ text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        let inner = try await session.stream(text, voice: voice)
        let credentials = self.credentials
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in inner { continuation.yield(frame) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // Reported whether the render finished or was cut off: the
                // characters were sent, and the server billed them either
                // way.
                await credentials.report(kind: .tts, sttSeconds: 0, ttsCharacters: text.count)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Closes the current context so the server stops generating, and the
    /// stream ends early.
    func cancel() async {
        if let ms = await session.cancel() {
            Log.write("tts: cancelled mid-stream after \(ms) ms")
        }
    }
}

// MARK: - The real socket

final class URLSessionInworldSocket: InworldSocket, @unchecked Sendable {

    private let task: URLSessionWebSocketTask

    private init(task: URLSessionWebSocketTask) { self.task = task }

    /// Opens and *proves* the connection: `URLSessionWebSocketTask` has no
    /// "opened" signal, but a ping is queued behind the handshake and fails
    /// when it does — so this returns a socket that is actually up, or
    /// throws. One round trip, paid at warm-up rather than per sentence.
    static func open(_ credential: InworldCredential) async throws -> URLSessionInworldSocket {
        var request = URLRequest(url: credential.socketURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        do {
            // One-shot: an aborted socket calls sendPing's handler twice,
            // and a continuation resumed twice kills the app.
            try await OneShot.completion { done in task.sendPing(pongReceiveHandler: done) }
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
            throw error
        }
        return URLSessionInworldSocket(task: task)
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    /// Answers when the far end does. Through a local proxy a dead
    /// connection raises no error of its own, so this is the only way to
    /// find one before a sentence is trusted to it.
    func ping() async throws {
        // One-shot, as in `open`: the handler can be called twice.
        try await OneShot.completion { done in task.sendPing(pongReceiveHandler: done) }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
