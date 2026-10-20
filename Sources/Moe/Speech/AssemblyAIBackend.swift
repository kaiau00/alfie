import Foundation
import MoeDictation
import MoeVoice

/// Cloud speech recognition — AssemblyAI Universal-3.5 Pro over a streaming
/// WebSocket — behind the same seam as the two local engines.
///
/// What it is for: the accurate re-read of a finished utterance, in the
/// eighteen languages the model steers to, when the Mac is entitled to it
/// (`CloudVoice.mayUse(.stt)`). What it is not: a replacement for the local
/// engines. Those stay loaded, because every failure here — no credential,
/// a dropped socket, no final in time, a 3007/3006/1008 close — falls back
/// to them *for that utterance*, and marks the cloud unhealthy for sixty
/// seconds so the next turn does not pay the failure again.
///
/// The protocol lives in `MoeVoice.AssemblyAIStream`, where it is tested
/// without a network; this file is the wiring: the real socket, the
/// credential, the keyterms, the health mark and the log line.
actor AssemblyAIBackend: SttBackend {
    nonisolated let displayName = "Premium"

    private let stream: AssemblyAIStream
    /// Shared with the stream's failure callback and read from the
    /// pipeline's thread, so a lock rather than actor state.
    private let health = HealthBox()
    private let now: @Sendable () -> Date
    private let credentials: @Sendable () -> any CloudVoiceCredentials
    /// A session credential minted before it is needed. Tokens are
    /// single-use and live sixty seconds, so this is refreshed on a short
    /// loop — for a few minutes after the voice becomes ready or a
    /// conversation ends, and for as long as the wake word is listening,
    /// because then a turn can start at any moment (`CredentialPrefetch`).
    private let prefetched = PrefetchBox()
    private var prefetching: Task<Void, Never>?

    final class PrefetchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ready: (AssemblyAIConnection, Date)?
        func put(_ c: AssemblyAIConnection, expiresAt: Date) { lock.lock(); ready = (c, expiresAt); lock.unlock() }
        /// The credential if it has at least eight seconds left, and it is
        /// gone once taken — a token opens one session.
        func take() -> AssemblyAIConnection? {
            lock.lock(); defer { lock.unlock() }
            guard let (c, at) = ready, at.timeIntervalSinceNow > 8 else { ready = nil; return nil }
            ready = nil
            return c
        }
        var expiresAt: Date? { lock.lock(); defer { lock.unlock() }; return ready?.1 }
    }

    final class HealthBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = CloudSttHealth()
        func read() -> CloudSttHealth { lock.lock(); defer { lock.unlock() }; return value }
        func failed(reason: String, at now: Date) { lock.lock(); value.failed(reason: reason, at: now); lock.unlock() }
        func succeeded() { lock.lock(); value.succeeded(); lock.unlock() }
    }

    /// `terms`/`contextTerms` are the router's own closures — the standing
    /// vocabulary and this utterance's on-screen words — merged the same way
    /// Whisper's prompt merges them, then cut to what the API takes.
    /// `agentContext` is Moe's last spoken reply, for `agent_context`.
    private let terms: @Sendable () -> [String]
    private let contextTerms: @Sendable () -> [String]
    private let agentContext: @Sendable () -> String?
    /// Whether "Hey Moe" is listening: while it is, a credential is kept
    /// minted past the warm-up window.
    private let wakeWordOn: @Sendable () -> Bool

    init(factory: any AssemblyAISocketFactory = URLSessionSocketFactory(),
         credentials: @escaping @Sendable () -> any CloudVoiceCredentials = { CloudVoice.shared },
         terms: @escaping @Sendable () -> [String] = { [] },
         contextTerms: @escaping @Sendable () -> [String] = { [] },
         agentContext: @escaping @Sendable () -> String? = { nil },
         wakeWordOn: @escaping @Sendable () -> Bool = { Config.load().wakeWordEnabled },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.wakeWordOn = wakeWordOn
        self.terms = terms
        self.contextTerms = contextTerms
        self.agentContext = agentContext
        self.now = now
        self.credentials = credentials
        let health = self.health
        let prefetched = self.prefetched
        stream = AssemblyAIStream(
            factory: factory,
            connection: {
                // A credential minted ahead of time, if one is still good;
                // otherwise mint now and say how long that took, because
                // in the first live run it was the three seconds between
                // the wake and the session opening.
                if let ready = prefetched.take() { return ready }
                let began = Date()
                let cred = try await credentials().credential(for: .stt)
                Log.write("stt: assemblyai credential minted in \(Int(Date().timeIntervalSince(began) * 1000)) ms"
                          + (cred.minted.map { " (\($0.described))" } ?? ""))
                // The edge mints a token and puts it in the URL; no header.
                return AssemblyAIConnection(socketURL: cred.socketURL, authorization: nil)
            },
            log: { Log.write($0) },
            // Session seconds, not audio seconds: AssemblyAI bills the time
            // the socket is open, and the edge meters the same way.
            usage: { _, sessionSeconds in
                await credentials().report(kind: .stt, sttSeconds: sessionSeconds, ttsCharacters: 0)
            },
            // A live turn that fails between re-reads (the open, a frame
            // send, a discard) rests the cloud the same as a failed read.
            onFailure: { error in
                let why = AssemblyAIBackend.reason(for: error)
                health.failed(reason: why, at: now())
                Log.write("stt: cloud fell back to local — \(why); cloud off for \(Int(health.read().lastCooldown)) s")
            })
    }

    nonisolated func supportsLanguage(_ code: String) -> Bool {
        AssemblyAILanguages.codes.contains(code.lowercased())
    }

    /// Ready means "would be used": entitled, and not cooling off.
    var isReady: Bool { CloudVoice.mayUse(.stt) && health.read().isHealthy(at: now()) }

    /// Nothing to load. The session opens on the first utterance; opening it
    /// earlier would start the meter before anyone has spoken.
    func warmUp(progress: (@Sendable (String) -> Void)?) async throws {}

    func unload() async { await stream.terminate() }

    /// Whether the router should send this utterance here.
    nonisolated func shouldHandle(locale: String) -> Bool {
        CloudSttRoute.shouldUseCloud(mayUse: CloudVoice.mayUse(.stt), locale: locale,
                                     health: health.read(), now: now())
    }

    /// Why the last fallback happened, for the router's log line.
    nonisolated var lastFailure: String? { health.read().lastReason }
    /// How long the last failure rests the cloud (`CloudSttHealth` ladder).
    nonisolated var lastCooldown: Double { health.read().lastCooldown }

    /// The `language_codes` hint: the locale's code when the model steers
    /// to it, else nil for native code-switching.
    nonisolated func hint(for locale: String) -> String? {
        let code = AssemblyAILanguages.code(of: locale)
        return AssemblyAILanguages.codes.contains(code) ? code : nil
    }

    /// The per-turn inputs: vocabulary and screen words as keyterms, Moe's
    /// last reply as agent context.
    nonisolated func context(language: String?) -> AssemblyAIContext {
        AssemblyAIContext(
            languageCodes: language.map { [$0] } ?? [],
            keyterms: AssemblyAIKeyterms.prepare(LiveVocabulary.merge(terms(), contextTerms())),
            agentContext: agentContext().flatMap { $0.isEmpty ? nil : String($0.suffix(1_500)) })
    }

    // MARK: Live feed

    /// A capture is starting. When the cloud is to be used for this locale,
    /// the session opens now (so `Begin` is never in the critical path) and
    /// every frame fed from here goes up as it is heard. Otherwise nothing,
    /// and the re-read takes the local engine.
    nonisolated func beginLiveTurn(locale: String) {
        guard shouldHandle(locale: locale) else { return }
        stream.beginLiveTurn(context: context(language: hint(for: locale)))
    }

    nonisolated func feedLive(_ samples16k: [Float]) { stream.feedLive(samples16k) }
    nonisolated func markTurnBoundary() { stream.markTurnBoundary() }
    nonisolated func claimLiveTurn() { stream.claimLiveTurn() }
    nonisolated func endLiveTurn() { stream.endLiveTurn() }

    /// How long after a warm-up the credential keeps being refreshed.
    static let prefetchWindowSeconds: Double = 300

    /// A turn is likely soon: have the session open (or opening) now, and
    /// keep a fresh credential to hand for the next few minutes so that
    /// when the idle rule has closed it, the reopen is a socket connect and
    /// not a mint as well.
    func warm(locale: String) async {
        guard shouldHandle(locale: locale) else { return }
        let context = context(language: hint(for: locale))
        do { try await stream.open(context: context) } catch {
            // Logged, and the prefetch still starts: with the wake word on,
            // the next turn should not pay the mint because this open failed.
            Log.write("stt: assemblyai warm-up failed — \(Self.reason(for: error))")
        }
        // One loop at a time: a new warm-up replaces the last one's.
        prefetching?.cancel()
        prefetchUntil = Date().addingTimeInterval(Self.prefetchWindowSeconds)
        prefetching = Task { [weak self] in
            var failures = 0
            var minted = 0
            var lastFailure: Date?
            let supported = AssemblyAILanguages.supports(locale: locale)
            while !Task.isCancelled {
                guard let self else { return }
                guard CloudVoice.mayUse(.stt), supported else { return }
                let step = CredentialPrefetch.next(
                    now: Date(), windowUntil: await self.prefetchUntil,
                    wakeWordOn: self.wakeWordOn(),
                    sessionOpen: await self.stream.isOpen,
                    heldExpiresAt: self.prefetched.expiresAt,
                    failuresInARow: failures, lastFailureAt: lastFailure)
                switch step {
                case .stop:
                    return
                case .wait(let seconds):
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                case .mint:
                    do {
                        let began = Date()
                        let cred = try await self.credentials().credential(for: .stt)
                        self.prefetched.put(AssemblyAIConnection(socketURL: cred.socketURL, authorization: nil),
                                            expiresAt: cred.expiresAt)
                        failures = 0
                        minted += 1
                        // The first of a run and any slow one; with the wake
                        // word on this runs all day, once a token lifetime.
                        let ms = Int(Date().timeIntervalSince(began) * 1000)
                        if minted == 1 || ms > 1000 {
                            Log.write("stt: assemblyai credential prefetched in \(ms) ms"
                                      + (cred.minted.map { " (\($0.described))" } ?? ""))
                        }
                    } catch {
                        failures += 1
                        lastFailure = Date()
                        // Once per run of failures, not once a minute while offline.
                        if failures == 1 {
                            Log.write("stt: assemblyai credential prefetch failed — \(Self.reason(for: error)); retrying with a backoff")
                        }
                    }
                }
            }
        }
    }

    /// The end of the warm-up window the prefetch loop is honouring.
    private var prefetchUntil = Date.distantPast

    func transcribe(samples16k: [Float], language: String?) async throws -> String {
        try await transcribeScored(samples16k: samples16k, language: language).text
    }

    /// The utterance through the open session, with the mean word
    /// confidence as the engine's own number. Throws on any failure after
    /// marking the cloud unhealthy; the router catches and falls back.
    func transcribeScored(samples16k: [Float], language: String?)
        async throws -> (text: String, confidence: Float?)
    {
        let began = Date()
        let seconds = Double(samples16k.count) / 16_000
        let live = stream.liveTurnActive
        // The Mac's own ears on the same audio: a turn this loud had a voice
        // in it, so the cloud saying nothing back yet is not "nobody spoke"
        // (`AssemblyAIStream.liveWait`).
        let level = Self.rms(samples16k)
        do {
            let result = try await stream.transcribe(samples16k: samples16k, context: context(language: language),
                                                     localHeardSpeech: QuietTurnPolicy.voiceIsPresent(rms: level))
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            let pieces = result.turns > 1 ? ", \(result.turns) turns stitched" : ""
            Log.write(String(format: "stt: assemblyai %.1f s in %d ms%@%@", seconds, ms,
                             live ? "" : " (batch)", pieces))
            health.succeeded()
            return (result.text, result.confidence)
        } catch {
            // Nothing heard is the room, not the cloud: read locally, and
            // the cloud stays on for the next turn.
            if case AssemblyAIError.heardNothing = error { throw error }
            // A failure on audio this quiet is the room too: it reads locally
            // and the cloud stays on (`QuietTurnPolicy.isSilent`). These were
            // most of the "no final" and "socket not connected" fallbacks,
            // and each switched the cloud off for the turns after it.
            if QuietTurnPolicy.isSilent(rms: level) {
                throw AssemblyAIError.heardNothing(afterSeconds: Date().timeIntervalSince(began))
            }
            health.failed(reason: Self.reason(for: error), at: now())
            throw error
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples { sum += x * x }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// One short phrase per failure, for the log.
    static func reason(for error: Error) -> String {
        switch error {
        case let e as AssemblyAIError: return e.description
        case CloudVoiceUnavailable.notEntitled: return "not entitled"
        case CloudVoiceUnavailable.allowanceSpent: return "allowance spent"
        case CloudVoiceUnavailable.notConfigured(let why): return "not configured: \(why)"
        case CloudVoiceUnavailable.offline: return "offline"
        case CloudVoiceUnavailable.disabled: return "disabled"
        case let e as URLError: return "network: \(e.code.rawValue)"
        // Never `"\(error)"`: a Foundation error prints the socket URL, with
        // its token and Moe's last reply in it (`AssemblyAIRedact`).
        default: return AssemblyAIRedact.describe(error)
        }
    }
}

// MARK: - The real socket

/// `URLSessionWebSocketTask` behind `AssemblyAISocket`.
struct URLSessionSocketFactory: AssemblyAISocketFactory {
    func connect(url: URL, authorization: String?) async throws -> any AssemblyAISocket {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return URLSessionSocket(task: task)
    }
}

final class URLSessionSocket: AssemblyAISocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ frame: AssemblyAIFrame) async throws {
        switch frame {
        case .text(let s): try await task.send(.string(s))
        case .data(let d): try await task.send(.data(d))
        }
    }

    func receive() async throws -> AssemblyAIFrame {
        do {
            switch try await task.receive() {
            case .string(let s): return .text(s)
            case .data(let d): return .data(d)
            @unknown default: throw AssemblyAIError.badMessage("unknown frame")
            }
        } catch let error as AssemblyAIError {
            throw error
        } catch {
            // The server's close code (3007, 3006, 1008…) is on the task
            // once it has closed; before that, this is a transport error.
            let code = task.closeCode
            if code != .invalid {
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                throw AssemblyAIError.closed(code: code.rawValue, reason: reason)
            }
            throw error
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
