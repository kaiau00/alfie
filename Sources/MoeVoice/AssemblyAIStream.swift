import Foundation

// The AssemblyAI streaming protocol, without the network.
//
// Everything here is pure Foundation so that every rule of the protocol is a
// test rather than a night of pressing keys against a metered API: how audio
// is framed, what a turn message means, how the keyterm list is trimmed and
// encoded, when a session is opened, updated, force-ended and terminated, and
// what counts as the final transcript for one utterance. The socket itself is
// behind `AssemblyAISocket`, so the tests drive the whole state machine with
// a fake and the app plugs in `URLSessionWebSocketTask`.
//
// Protocol facts below were read from the docs on 2026-09-06 (the pages are
// named beside each fact) and several were measured against the live API
// the same day. Names drift; when one of these stops matching, re-read
// https://www.assemblyai.com/docs/streaming/message-sequence first.

// MARK: - Socket seam

/// One WebSocket frame, either direction.
public enum AssemblyAIFrame: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// The socket the session talks through. `URLSessionWebSocketTask` in the
/// app; a scripted fake in the tests.
public protocol AssemblyAISocket: Sendable {
    func send(_ frame: AssemblyAIFrame) async throws
    /// The next frame from the server. Throws when the socket is closed or
    /// broken; a server close code surfaces as `AssemblyAIError.closed`.
    func receive() async throws -> AssemblyAIFrame
    /// Close from our side. Idempotent.
    func close() async
}

/// Opens sockets. `authorization`, when present, is the raw API key for the
/// `Authorization` header; with a minted token it is nil because the token
/// rides in the URL's `token` query parameter
/// (docs/streaming/authenticate-with-a-temporary-token).
public protocol AssemblyAISocketFactory: Sendable {
    func connect(url: URL, authorization: String?) async throws -> any AssemblyAISocket
}

// MARK: - Errors

public enum AssemblyAIError: Error, Equatable, CustomStringConvertible {
    /// No `end_of_turn` arrived within the deadline after `ForceEndpoint`.
    case noFinal(afterSeconds: Double)
    /// The server sent an `Error` message (`error_code`, `error`) and is
    /// about to close (docs/streaming/common-session-errors-and-closures).
    case server(code: Int, message: String)
    /// The socket closed under us with a close code.
    case closed(code: Int, reason: String)
    /// `Begin` never came.
    case noBegin
    /// A text frame that was not JSON with a `type`.
    case badMessage(String)
    /// The session was torn down while a call was waiting on it.
    case cancelled
    /// A live turn the server never opened a turn for — it heard no words —
    /// and no final came in the short wait after the force-end. Not a
    /// failure of the cloud: the room was quiet, or it was noise. The caller
    /// reads the audio locally, and the cloud is not rested for it.
    case heardNothing(afterSeconds: Double)

    public var description: String {
        switch self {
        case .noFinal(let s): return "no final within \(String(format: "%.1f", s)) s of ForceEndpoint"
        case .server(let code, let message): return "server error \(code): \(message)"
        case .closed(let code, let reason): return "socket closed \(code)\(reason.isEmpty ? "" : ": \(reason)")"
        case .noBegin: return "no Begin message"
        case .badMessage(let s): return "unreadable message: \(String(s.prefix(80)))"
        case .cancelled: return "session closed mid-call"
        case .heardNothing(let s): return "the server heard no words (nothing within \(String(format: "%.1f", s)) s)"
        }
    }
}

// MARK: - Redaction

/// What may be written to a log about a failure on the socket.
///
/// The session URL carries a single-use token and, as `agent_context`, the
/// words of Moe's last reply. `"\(error)"` on a Foundation error prints its
/// `userInfo`, which carries that URL whole: moe.log held 35 such lines from
/// 09-23 to 10-02 — 21 "cloud fell back", 10 "session failed", one warm-up —
/// each with a live token and a sentence of a reply. So nothing about a
/// socket failure is logged without coming through here.
public enum AssemblyAIRedact {
    /// A failure as a short phrase with no URL, token or reply text in it.
    public static func describe(_ error: Error) -> String {
        if let e = error as? AssemblyAIError { return scrub(e.description) }
        let ns = error as NSError
        // Domain and code, and the system's own sentence — never userInfo,
        // which is where the failing URL lives.
        let said = ns.userInfo[NSLocalizedDescriptionKey] as? String
        return scrub("\(ns.domain) \(ns.code)" + (said.map { ": \($0)" } ?? ""))
    }

    /// Any URL in `text` cut to its scheme and host, and any `token=`
    /// value removed, wherever it sits.
    public static func scrub(_ text: String) -> String {
        var out = text
        if let url = try? NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9+.-]*://[^/\s?#,}]+)[^\s,}]*"#) {
            out = url.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                               withTemplate: "$1/…")
        }
        if let token = try? NSRegularExpression(pattern: #"(?i)(token=)[^&\s,}]+"#) {
            out = token.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: "$1…")
        }
        return out
    }
}

// MARK: - Languages

public enum AssemblyAILanguages {
    /// The `language_codes` Universal-3.5 Pro Streaming accepts — the list in
    /// the AsyncAPI spec (docs/streaming/api-spec/streaming-websocket,
    /// parameter `language_codes`), read 2026-09-06. Eighteen.
    public static let codes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "tr", "nl", "sv", "no", "da", "fi",
        "hi", "vi", "ar", "he", "ja", "zh",
    ]

    /// ISO 639-1 code from a locale tag, lowercased ("zh-Hans-CN" → "zh").
    /// Same rule as `SpeechLanguages.code(of:)`, repeated here because this
    /// module cannot see that one.
    public static func code(of locale: String) -> String {
        let head = locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? locale
        return head.lowercased()
    }

    public static func supports(locale: String) -> Bool { codes.contains(code(of: locale)) }
}

// MARK: - Keyterms

public enum AssemblyAIKeyterms {
    /// "You can include a maximum of 100 keyterms per session. Each
    /// individual keyterm string must be 50 characters or less. Keyterms
    /// longer than 50 characters are ignored; requests with more than 100
    /// keyterms return an error." (docs/streaming/prompting-and-keyterms)
    public static let maxTerms = 100
    public static let maxLength = 50

    /// The list as the API will take it: trimmed, empty and over-long terms
    /// gone, duplicates (case-insensitive) gone keeping the first spelling,
    /// and if there are still more than 100, the *longest* dropped first so
    /// the short names — the ones a recogniser most needs help with — are the
    /// last to go. Order otherwise preserved, because `Vocabulary` already
    /// puts what the user typed ahead of what was learned.
    public static func prepare(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= maxLength else { continue }
            guard seen.insert(t.lowercased()).inserted else { continue }
            kept.append(t)
        }
        guard kept.count > maxTerms else { return kept }
        // Indices of the longest terms, dropped until the count fits.
        let byLength = kept.indices.sorted { (a, b) in
            let (la, lb) = (kept[a].count, kept[b].count)
            return la != lb ? la > lb : a > b
        }
        let drop = Set(byLength.prefix(kept.count - maxTerms))
        return kept.indices.filter { !drop.contains($0) }.map { kept[$0] }
    }

    /// The JSON array the `keyterms_prompt` parameter carries, both as a
    /// query value and inside `UpdateConfiguration`
    /// (`keyterms_prompt=["Keanu Reeves", "AssemblyAI"]`).
    public static func json(_ terms: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: terms, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Audio framing

public enum AssemblyAIFraming {
    /// 16 kHz, 16-bit, mono: 32 bytes per millisecond.
    public static let bytesPerMs = 32
    /// "Input duration violation: Expected between 50 and 1000 ms" is close
    /// code 3007 (docs/streaming/common-session-errors-and-closures). The
    /// quickstart sends ~50 ms; 100 ms halves the frame count for the same
    /// latency, which for a buffered utterance is nil either way.
    public static let minFrameMs = 50
    public static let maxFrameMs = 1000
    public static let frameMs = 100

    /// Float samples in [-1, 1] to little-endian signed 16-bit PCM.
    public static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                let clamped = max(-1, min(1, s))
                out[i] = Int16((clamped * 32767).rounded()).littleEndian
            }
        }
        return data
    }

    /// Cut PCM into frames the server accepts: 100 ms each, a tail shorter
    /// than 50 ms merged into the frame before it (the merged frame is at
    /// most 150 ms, under the 1000 ms ceiling), and a buffer that is under
    /// 50 ms on its own padded with silence up to 50 ms rather than sent
    /// short. Short frames close the socket; a little silence is free.
    public static func frames(_ pcm: Data) -> [Data] {
        let frame = frameMs * bytesPerMs
        let minimum = minFrameMs * bytesPerMs
        guard !pcm.isEmpty else { return [] }
        if pcm.count < minimum {
            var padded = pcm
            padded.append(Data(count: minimum - pcm.count))
            return [padded]
        }
        var out: [Data] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + frame, pcm.count)
            out.append(pcm.subdata(in: offset..<end))
            offset = end
        }
        if out.count >= 2, let last = out.last, last.count < minimum {
            out.removeLast()
            out[out.count - 1].append(last)
        }
        return out
    }
}

// MARK: - Messages

/// The server messages the session acts on. Anything else (`SpeechStarted`,
/// `Heartbeat`, `SpeakerRevision`) is `.other`.
public enum AssemblyAIMessage: Sendable, Equatable {
    case begin(id: String, model: String?)
    case turn(AssemblyAITurn)
    case termination(audioSeconds: Double, sessionSeconds: Double)
    case error(code: Int, message: String)
    case other(type: String)

    public static func parse(_ text: String) throws -> AssemblyAIMessage {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { throw AssemblyAIError.badMessage(text) }
        switch type {
        case "Begin":
            let config = object["configuration"] as? [String: Any]
            return .begin(id: object["id"] as? String ?? "", model: config?["model"] as? String)
        case "Turn":
            return .turn(AssemblyAITurn(object))
        case "Termination":
            return .termination(audioSeconds: (object["audio_duration_seconds"] as? Double) ?? 0,
                                sessionSeconds: (object["session_duration_seconds"] as? Double) ?? 0)
        case "Error":
            return .error(code: (object["error_code"] as? Int) ?? 0,
                          message: (object["error"] as? String) ?? "")
        default:
            return .other(type: type)
        }
    }
}

/// One `Turn` message (docs/streaming/message-sequence, "Partial transcript"
/// and "End of turn"). Within a turn each message supersedes the last; a
/// turn is complete when `end_of_turn` is true.
public struct AssemblyAITurn: Sendable, Equatable {
    public let order: Int
    public let transcript: String
    public let endOfTurn: Bool
    public let formatted: Bool
    /// Per-word confidences, for the average the router reports.
    public let wordConfidences: [Float]

    public init(order: Int, transcript: String, endOfTurn: Bool, formatted: Bool, wordConfidences: [Float]) {
        self.order = order
        self.transcript = transcript
        self.endOfTurn = endOfTurn
        self.formatted = formatted
        self.wordConfidences = wordConfidences
    }

    init(_ object: [String: Any]) {
        order = (object["turn_order"] as? Int) ?? 0
        transcript = (object["transcript"] as? String) ?? ""
        endOfTurn = (object["end_of_turn"] as? Bool) ?? false
        formatted = (object["turn_is_formatted"] as? Bool) ?? false
        let words = (object["words"] as? [[String: Any]]) ?? []
        wordConfidences = words.compactMap { w in
            (w["confidence"] as? Double).map { Float($0) } ?? (w["confidence"] as? Float)
        }
    }
}

// MARK: - Results

public struct AssemblyAIResult: Sendable, Equatable {
    /// The utterance's finals, in turn order, joined with single spaces.
    public let text: String
    /// Mean word confidence over those finals; nil when there were no words.
    public let confidence: Float?
    /// How many `end_of_turn` turns made up the utterance. One is normal;
    /// more means the server auto-ended mid-utterance and the pieces were
    /// stitched back together.
    public let turns: Int
}

// MARK: - Health

/// "Cloud STT failed; do not pay that failure again for a while."
///
/// A ladder, not a flat minute. The minute was paid 43 times from 09-23 to
/// 09-29, and the blips behind the real ones lasted 11–34 s
/// (`~/moe-voice-notes/audit-2026-09-29/audit-cloud-local.md`): a short
/// rest after the first failure, longer only if it keeps failing, and back
/// to the bottom the moment a read succeeds. Pure and clocked from outside
/// so the ladder is a test, not a wait.
public struct CloudSttHealth: Sendable, Equatable {
    public static let cooldownLadder: [Double] = [5, 15, 30, 60]
    public private(set) var unhealthyUntil: Date?
    public private(set) var lastReason: String?
    /// Failures since the last read that worked.
    public private(set) var failuresInARow = 0
    /// The rest the last failure bought, for the log line.
    public private(set) var lastCooldown: Double = 0

    public init() {}

    public mutating func failed(reason: String, at now: Date) {
        lastCooldown = Self.cooldownLadder[min(failuresInARow, Self.cooldownLadder.count - 1)]
        failuresInARow += 1
        unhealthyUntil = now.addingTimeInterval(lastCooldown)
        lastReason = reason
    }

    /// A cloud read came back: the next failure starts the ladder again.
    public mutating func succeeded() {
        failuresInARow = 0
    }

    public func isHealthy(at now: Date) -> Bool {
        guard let until = unhealthyUntil else { return true }
        return now >= until
    }
}

/// The one rule the router asks: is this utterance for the cloud?
public enum CloudSttRoute {
    public static func shouldUseCloud(mayUse: Bool, locale: String,
                                      health: CloudSttHealth, now: Date) -> Bool {
        mayUse && AssemblyAILanguages.supports(locale: locale) && health.isHealthy(at: now)
    }
}

// MARK: - Session

/// What a session needs to open: where, and how to prove who we are.
public struct AssemblyAIConnection: Sendable {
    /// The socket URL as the credential hands it over — already carrying
    /// `sample_rate`, `speech_model`, `mode` and, with a minted token,
    /// `token`. The session appends its own parameters.
    public let socketURL: URL
    /// Raw API key for the `Authorization` header, or nil with a token.
    public let authorization: String?

    public init(socketURL: URL, authorization: String?) {
        self.socketURL = socketURL
        self.authorization = authorization
    }
}

/// The per-utterance inputs the app hands in.
public struct AssemblyAIContext: Sendable, Equatable {
    /// ISO 639-1 codes for `language_codes`; empty means "do not steer, let
    /// the model code-switch".
    public var languageCodes: [String]
    /// Already through `AssemblyAIKeyterms.prepare`.
    public var keyterms: [String]
    /// Moe's last spoken reply, for `agent_context`; nil to leave it alone.
    public var agentContext: String?

    public init(languageCodes: [String] = [], keyterms: [String] = [], agentContext: String? = nil) {
        self.languageCodes = languageCodes
        self.keyterms = keyterms
        self.agentContext = agentContext
    }
}

/// The audio arriving live, between the microphone's actor and the
/// session's.
///
/// `feedLive` is called from the audio pipeline for every 32 ms frame and
/// has to be synchronous and ordered — actor hops through `Task {}` keep no
/// order — so the frames land here under a lock and the session's pump
/// drains them in order. `boundary` is where the turn being read ends:
/// audio before it is this utterance, audio after it is already the next.
public final class LiveInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var boundary: Int?
    private var activeFlag = false
    private var pumpScheduled = false
    private var heldFlag = false
    private var claimedFlag = false
    private var endPendingFlag = false
    /// Samples accepted since the feed was activated.
    private var acceptedCount = 0

    public init() {}

    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return activeFlag }
    /// Set while a discarded turn is being force-ended: the pump waits so
    /// the next turn's frames cannot slip in ahead of that ForceEndpoint.
    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return heldFlag }
    func hold() { lock.lock(); heldFlag = true; lock.unlock() }
    func release() { lock.lock(); heldFlag = false; lock.unlock() }
    public var accepted: Int { lock.lock(); defer { lock.unlock() }; return acceptedCount }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    func activate() {
        lock.lock(); defer { lock.unlock() }
        activeFlag = true
        pending.removeAll(keepingCapacity: true)
        boundary = nil
        acceptedCount = 0
        claimedFlag = false
        endPendingFlag = false
    }

    func deactivate() {
        lock.lock(); defer { lock.unlock() }
        activeFlag = false
        pending.removeAll(keepingCapacity: true)
        boundary = nil
        claimedFlag = false
        endPendingFlag = false
    }

    /// A re-read is coming for the turn fed so far: the capture switching
    /// off must not throw it away. False when there is no live turn.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeFlag else { return false }
        claimedFlag = true
        return true
    }
    var isClaimed: Bool { lock.lock(); defer { lock.unlock() }; return claimedFlag }
    /// The capture switched off while the turn was claimed: the feed ends
    /// when the re-read has taken its tail.
    func deferEnd() { lock.lock(); endPendingFlag = true; lock.unlock() }
    var isEndPending: Bool { lock.lock(); defer { lock.unlock() }; return endPendingFlag }
    /// The claimed turn has been read: the claim is spent. True when the
    /// feed should now go off as well.
    func settleClaim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        claimedFlag = false
        let end = endPendingFlag
        endPendingFlag = false
        return end
    }

    /// False when the feed is off (the frame is dropped).
    func append(_ samples: [Float]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeFlag else { return false }
        pending.append(contentsOf: samples)
        acceptedCount += samples.count
        return true
    }

    /// Everything accepted so far is the turn being read; what follows is
    /// the next one.
    func markBoundary() {
        lock.lock(); defer { lock.unlock() }
        guard activeFlag else { return }
        boundary = pending.count
    }

    /// True when this call should start a pump (one at a time).
    func schedulePump() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pumpScheduled { return false }
        pumpScheduled = true
        return true
    }
    func pumpStarted() { lock.lock(); pumpScheduled = false; lock.unlock() }

    /// A full frame of `count` samples, never crossing the boundary.
    func takeFrame(count: Int) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let available = boundary ?? pending.count
        guard available >= count else { return nil }
        let frame = Array(pending.prefix(count))
        pending.removeFirst(count)
        if let b = boundary { boundary = b - count }
        return frame
    }

    /// Whatever remains before the boundary (or everything, with none),
    /// and the boundary is cleared: the turn is over.
    func takeTail() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let n = boundary ?? pending.count
        let tail = Array(pending.prefix(n))
        pending.removeFirst(n)
        boundary = nil
        return tail
    }
}

/// One AssemblyAI streaming session, kept open across utterances.
///
/// Why one session and not one per utterance: the free tier admits five
/// *new* sessions a minute (docs/streaming/rate-limits) and a lively
/// conversation has more turns than that. So the socket opens when a
/// conversation opens, every utterance is one forced turn on it, and it is
/// terminated after `idleSeconds` without one — properly, with `Terminate`
/// and a read up to `Termination`, because a session that is merely dropped
/// bills until the server's three-hour cap (docs/streaming/message-sequence,
/// "Session termination"). Streaming is billed on wall-clock session time,
/// not audio, so the idle minute costs something; the usage callback
/// reports both numbers.
///
/// Two ways in. **Live**: `beginLiveTurn` opens the session and turns the
/// inbox on, the pipeline calls `feedLive` with every frame as it is heard,
/// `markTurnBoundary` says where the utterance ended, and `transcribe` then
/// sends only the unsent tail and `ForceEndpoint` and waits — measured
/// 2026-09-06, the final lands ~180 ms after the force-end when the audio
/// went up in real time. **Batch**: `transcribe` with no live turn sends
/// the whole buffer in one burst. That is the fallback, and it is slow:
/// the server works through a burst at ~1.25× real time ("You can send
/// audio faster than real time … throughput is throttled at ~1.25× real
/// time. If more than five minutes of audio is buffered ahead of
/// processing, the session closes with error 3007" —
/// docs/streaming/message-sequence), so a ten-second question waits eight.
/// No pacing either way.
public actor AssemblyAIStream {

    public typealias Sleeper = @Sendable (Double) async -> Void
    public typealias UsageReport = @Sendable (_ audioSeconds: Double, _ sessionSeconds: Double) async -> Void

    /// How long a session may sit idle before it is terminated.
    public let idleSeconds: Double
    /// Grace after `ForceEndpoint` for the final to arrive, on top of the
    /// time the server needs to process the audio just sent (1.25× real
    /// time) — which for a live turn is next to nothing.
    public let finalGraceSeconds: Double
    /// Server-side throughput on a burst, from the docs. The batch deadline
    /// is `finalGraceSeconds + audioSeconds / processingRate`.
    public let processingRate: Double = 1.25
    /// After the first final, how long to keep listening for a straggler.
    ///
    /// Pieces the server auto-ended *before* the forced one are already in
    /// the inbox when the forced final is read, so this is only for the
    /// case where the force-end was applied before a burst was fully
    /// processed and the rest came back as a new turn. It is paid on every
    /// utterance, so it is short; whether it can be zero is a thing to
    /// measure live, not decide here.
    public let settleSeconds: Double
    /// `UpdateConfiguration` is sent at most this often.
    public let updateDebounceSeconds: Double = 2
    /// Live frames go up in pieces of this many samples (100 ms).
    public static let liveFrameSamples = AssemblyAIFraming.frameMs * 16

    private let factory: any AssemblyAISocketFactory
    private let connection: @Sendable () async throws -> AssemblyAIConnection
    private let sleep: Sleeper
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let usage: UsageReport?
    private let onFailure: (@Sendable (Error) -> Void)?

    /// The live feed. Public so the app can wire the pipeline straight to
    /// it; `feedLive` is the intended door.
    public nonisolated let live = LiveInbox()

    // Session state.
    private var socket: (any AssemblyAISocket)?
    private var reader: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var opening: Task<Void, Error>?
    private var generation = 0
    private var applied = AssemblyAIContext()
    private var lastUpdateAt: Date?
    private var audioSecondsSent: Double = 0
    private var openedAt: Date?
    private var lastFinalOrder = -1
    private var busy = false
    // Live bookkeeping.
    private var pumping = false
    private var holdingPump = false
    private var liveSamplesSinceForce = 0
    private var liveSamplesThisTurn = 0
    /// Audio that was waiting when a live turn's session finished opening,
    /// and when it went up in one burst: a late open turns the start of a
    /// live turn into a batch the server reads at 1.25× real time.
    private var burstAtOpenSamples = 0
    private var burstAt: Date?
    /// Reads waiting for the wire. A discard stops waiting for its final the
    /// moment one is, rather than holding the read behind it.
    private var readsWaiting = 0

    // Inbox: the reader task pushes, a call pops with a deadline.
    private var inbox: [Result<AssemblyAIMessage, AssemblyAIError>] = []
    private var waiter: CheckedContinuation<Result<AssemblyAIMessage, AssemblyAIError>?, Never>?
    private var waiterGeneration = 0

    public init(factory: any AssemblyAISocketFactory,
                connection: @escaping @Sendable () async throws -> AssemblyAIConnection,
                idleSeconds: Double = 60,
                finalGraceSeconds: Double = 4,
                settleSeconds: Double = 0.2,
                sleep: @escaping Sleeper = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) },
                now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in },
                usage: UsageReport? = nil,
                onFailure: (@Sendable (Error) -> Void)? = nil) {
        self.factory = factory
        self.connection = connection
        self.idleSeconds = idleSeconds
        self.finalGraceSeconds = finalGraceSeconds
        self.settleSeconds = settleSeconds
        self.sleep = sleep
        self.now = now
        self.log = log
        self.usage = usage
        self.onFailure = onFailure
    }

    public var isOpen: Bool { socket != nil }

    // MARK: Live feed

    /// A turn is starting: take frames from now on, and have the session
    /// open by the time they matter. Returns at once — the inbox is on
    /// before this returns, so a frame fed on the next line is kept — and
    /// the open happens behind it; a failure to open reaches `onFailure`
    /// and turns the feed back off, so `transcribe` takes the batch path.
    public nonisolated func beginLiveTurn(context: AssemblyAIContext) {
        live.activate()
        log("stt: assemblyai live turn begins")
        Task { await self.openForLive(context: context) }
    }

    /// Open the session now, with no turn on it — at launch and at the end
    /// of a conversation, so the next turn's `Begin` has already happened.
    /// The idle rule still applies: sixty quiet seconds and it is
    /// terminated, because an open socket is what AssemblyAI bills.
    public func open(context: AssemblyAIContext) async throws {
        if let opening { _ = try? await opening.value }
        guard socket == nil else { return }
        let task = Task<Void, Error> {
            _ = try await ensureOpen(context: context)
        }
        opening = task
        do {
            try await task.value
            opening = nil
            scheduleIdleClose()
        } catch {
            opening = nil
            onFailure?(error)
            await tearDown(after: error)
            throw error
        }
    }

    /// The re-read for the turn fed so far is on its way. Called before the
    /// capture is taken: the machine switches the capture off in the same
    /// breath as it asks for the read, and without this the switch-off
    /// (synchronous) discarded the turn before the read (queued behind the
    /// pipeline) could take it — every turn in the first live run went to
    /// the batch path that way.
    public nonisolated func claimLiveTurn() {
        if live.claim() { log("stt: assemblyai live turn claimed for the re-read") }
    }

    private func openForLive(context: AssemblyAIContext) async {
        idle?.cancel(); idle = nil
        if let opening { _ = try? await opening.value }
        guard live.isActive else { return }
        let task = Task<Void, Error> {
            let socket = try await ensureOpen(context: context)
            try await reconfigureIfNeeded(context: context, socket: socket)
        }
        opening = task
        do {
            try await task.value
            // Cleared before the pump, which refuses to run while an open
            // is in flight — the first version cleared it in a `defer`,
            // after the pump, and no live frame ever went up until the
            // tail at the end of the turn.
            opening = nil
            liveSamplesThisTurn = 0
            burstAtOpenSamples = live.pendingCount
            burstAt = now()
            if live.isActive { await pump() } else { scheduleIdleClose() }
        } catch {
            opening = nil
            // Moe ended the turn while the session was still opening — a
            // refused barge-in, a tap — and the open was torn down with it.
            // That is not the cloud failing, and resting it for that sent six
            // turns from 09-23 to 09-29 to the local ears for nothing.
            let ownEnd = !live.isActive && Self.isOwnTeardown(error)
            live.deactivate()
            if ownEnd {
                log("stt: assemblyai open ended with its turn — \(AssemblyAIRedact.describe(error)); not a cloud failure")
            } else {
                onFailure?(error)
            }
            await tearDown(after: error)
        }
    }

    /// The errors a session shows when it is Moe that closed it.
    static func isOwnTeardown(_ error: Error) -> Bool {
        switch error {
        case AssemblyAIError.cancelled, AssemblyAIError.noBegin: return true
        case is CancellationError: return true
        default: return false
        }
    }

    /// A frame from the microphone. Synchronous, ordered, cheap; dropped
    /// when no live turn is on.
    public nonisolated func feedLive(_ samples16k: [Float]) {
        guard live.append(samples16k) else { return }
        if live.accepted == samples16k.count {
            log(String(format: "stt: assemblyai live: first frame (%.2f s)", Double(samples16k.count) / 16_000))
        }
        if live.schedulePump() { Task { await self.pump() } }
    }

    /// The utterance the next `transcribe` will read ends here; frames
    /// after this belong to the turn after it.
    public nonisolated func markTurnBoundary() { live.markBoundary() }

    /// Whether the next `transcribe` will take the live path.
    public nonisolated var liveTurnActive: Bool { live.isActive }

    /// Send the full frames waiting in the inbox, in order, one pump at a
    /// time. Stops at the turn boundary; `transcribe` sends that tail.
    private func pump() async {
        live.pumpStarted()
        guard let socket, !pumping, !holdingPump, !live.isHeld, opening == nil else { return }
        pumping = true
        defer { pumping = false }
        while let frame = live.takeFrame(count: Self.liveFrameSamples) {
            do {
                try await socket.send(.data(AssemblyAIFraming.pcm16(frame)))
                liveSamplesSinceForce += frame.count
                liveSamplesThisTurn += frame.count
                audioSecondsSent += Double(frame.count) / 16_000
            } catch {
                live.deactivate()
                onFailure?(error)
                await tearDown(after: error)
                return
            }
        }
    }

    /// The turn was abandoned — no re-read is coming. The feed goes off
    /// now, synchronously, so a turn that begins on the next line is not
    /// switched off by this one's clean-up; whatever the server has of the
    /// abandoned turn is then force-ended and its final read and dropped,
    /// so the next utterance's transcript does not begin with these words.
    public nonisolated func endLiveTurn() {
        guard live.isActive else { return }
        if live.isClaimed {
            // The read is coming; it takes the tail and ends the feed. If
            // it never comes (the local model was not ready, an error), a
            // grace later the turn is discarded as below.
            live.deferEnd()
            log("stt: assemblyai live turn ends — held for the re-read")
            Task { await self.expireClaim() }
            return
        }
        let tail = live.takeTail()
        live.deactivate()
        live.hold()
        log("stt: assemblyai live turn ends — not read back, discarding")
        Task { await self.discard(tail: tail) }
    }

    /// How long a claimed turn may wait for its re-read before it is
    /// treated as abandoned.
    public let claimGraceSeconds: Double = 8

    private func expireClaim() async {
        await sleep(claimGraceSeconds)
        guard live.isActive, live.isClaimed, live.isEndPending else { return }
        log("stt: assemblyai claimed turn was never read — discarding")
        let tail = live.takeTail()
        live.deactivate()
        live.hold()
        await discard(tail: tail)
    }

    /// Audio this short since the last force-end is the gap between a turn
    /// being taken and the capture switching off — room tone, not words.
    /// Left as the head of the next turn rather than paid for with a
    /// round trip.
    public static let discardThresholdSamples = 16_000 / 4
    /// How long to wait for the discarded turn's final. Short, because the
    /// next utterance's read waits behind it, and a silent turn may never
    /// produce one.
    public let discardGraceSeconds: Double = 1.0
    /// How often a discard waiting for its final looks up to see whether a
    /// read is waiting behind it.
    static let discardSliceSeconds: Double = 0.05

    private func discard(tail: [Float]) async {
        defer { live.release() }
        guard socket != nil, tail.count + liveSamplesSinceForce >= Self.discardThresholdSamples else {
            if socket != nil { scheduleIdleClose() }
            return
        }
        let gen = generation
        await waitUntilFree()
        // The session this turn was fed into may be gone by now — a read
        // that failed tore it down while this waited. Its words went with
        // it; force-ending a closed socket only stalls the next read.
        guard let socket, gen == generation else {
            log("stt: assemblyai discard dropped — the session it was for has closed")
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await sendTail(tail, socket: socket)
            // The turn the server has open for the discarded words. If a read
            // takes the wire before its final comes, that final is marked
            // read so the read cannot take it as its own.
            let discarding = openTurnOrder()
            try await socket.send(.text(#"{"type":"ForceEndpoint"}"#))
            liveSamplesSinceForce = 0
            liveSamplesThisTurn = 0
            var remaining = discardGraceSeconds
            var sawFinal = false
            var yielded = false
            while remaining > 0 {
                if readsWaiting > 0, !sawFinal {
                    if let d = discarding { lastFinalOrder = max(lastFinalOrder, d) }
                    yielded = true
                    break
                }
                // In slices, so a read that arrives is seen within one.
                let budget = sawFinal ? min(settleSeconds, remaining) : min(Self.discardSliceSeconds, remaining)
                let started = now()
                let next = await nextMessage(within: budget)
                remaining -= max(now().timeIntervalSince(started), next == nil ? budget : 0)
                guard let next else {
                    if sawFinal { break }
                    continue
                }
                switch next {
                case .success(.turn(let t)) where t.endOfTurn:
                    lastFinalOrder = max(lastFinalOrder, t.order)
                    sawFinal = true
                case .failure(let error): throw error
                case .success(.error(let code, let message)): throw AssemblyAIError.server(code: code, message: message)
                default: continue
                }
            }
            log("stt: assemblyai turn discarded" + (sawFinal ? "" : yielded ? " — a read was waiting, so it did not wait for the final" : " (no final came)"))
            scheduleIdleClose()
        } catch {
            if !Self.isOwnTeardown(error) { onFailure?(error) }
            await tearDown(after: error)
        }
        // Frames of a turn that began during the clean-up have been waiting.
        if live.isActive { live.release(); await pump() }
    }

    // MARK: Transcribe one utterance

    /// The final for one utterance.
    ///
    /// With a live turn on, the audio is already up: what goes out is the
    /// tail after the last full frame, then `ForceEndpoint`, and the answer
    /// is every `end_of_turn` turn read after it. Without one, the whole
    /// buffer goes up first. Any failure closes the session and throws; the
    /// caller falls back to a local engine and marks the cloud unhealthy.
    ///
    /// `localHeardSpeech` is the Mac's own ears on the same audio. When they
    /// heard a voice, a server that has opened no turn yet is not taken to
    /// mean the room was quiet: it is waited for like any other final.
    public func transcribe(samples16k: [Float], context: AssemblyAIContext,
                           localHeardSpeech: Bool = false) async throws -> AssemblyAIResult {
        let seconds = Double(samples16k.count) / 16_000
        readsWaiting += 1
        await waitUntilFree()
        readsWaiting -= 1
        busy = true
        defer { busy = false }
        idle?.cancel(); idle = nil
        // A live turn's open is a task `beginLiveTurn` spawned; if the read
        // arrives before that task has even started, wait for it to
        // register rather than opening a second session beside it.
        var waited = 0.0
        while live.isActive, socket == nil, opening == nil, waited < 1 {
            await sleep(0.005)
            waited += 0.005
        }
        if let opening { _ = try? await opening.value }
        // A discard in flight holds the pump; it also holds `busy`, which
        // `waitUntilFree` above already waited out.
        let isLive = live.isActive && socket != nil
        do {
            let socket = try await ensureOpen(context: context)
            let forcedAt: Date
            var liveSent = 0
            var awaiting: Int?
            // Whether the server opened any turn for this utterance. On the
            // live path the audio went up as it was spoken, so a server that
            // has opened no turn by the force-end heard no words; its final
            // is not coming, and waiting the full grace for it held the
            // microphone four seconds a time on noise (26 of 28 "no final"
            // fallbacks from 09-23 to 09-29 were turns with no speech).
            var serverHeardWords = true
            // Audio the server has been sent but cannot have read yet. Zero
            // on a live turn whose audio went up as it was spoken.
            var backlog = 0.0
            if isLive {
                // Hold the pump so nothing from the next turn slips in
                // ahead of the force-end, send what is left of this one.
                holdingPump = true
                while pumping { await sleep(0.005) }
                let tail = live.takeTail()
                backlog = unreadSeconds(tailSamples: tail.count)
                burstAtOpenSamples = 0
                try await sendTail(tail, socket: socket)
                awaiting = openTurnOrder()
                serverHeardWords = awaiting != nil || hasTurnSinceLastFinal()
                try await socket.send(.text(#"{"type":"ForceEndpoint"}"#))
                forcedAt = now()
                liveSent = liveSamplesThisTurn
                liveSamplesThisTurn = 0
                liveSamplesSinceForce = 0
                holdingPump = false
                if live.settleClaim() {
                    // The capture went off while this read was pending:
                    // the feed ends here, and whatever was heard after the
                    // boundary was room tone, dropped.
                    live.deactivate()
                } else if live.pendingCount >= Self.liveFrameSamples, live.schedulePump() {
                    Task { await self.pump() }
                }
            } else {
                if live.settleClaim() { live.deactivate() }
                try await reconfigureIfNeeded(context: context, socket: socket)
                for frame in AssemblyAIFraming.frames(AssemblyAIFraming.pcm16(samples16k)) {
                    try await socket.send(.data(frame))
                }
                audioSecondsSent += seconds
                try await socket.send(.text(#"{"type":"ForceEndpoint"}"#))
                forcedAt = now()
            }
            let wait = isLive ? Self.liveWait(serverHeardWords: serverHeardWords, backlogSeconds: backlog,
                                              localHeardSpeech: localHeardSpeech, finalGrace: finalGraceSeconds)
                              : LiveWait(deadline: batchDeadline(forSeconds: seconds), quiet: false)
            if isLive, !serverHeardWords, !wait.quiet {
                log(String(format: "stt: assemblyai no words back yet, but %@ — waiting %.1f s for the final",
                           backlog > Self.realTimeBacklogSeconds
                               ? String(format: "%.1f s of audio went up late", backlog) as NSString
                               : "the Mac heard a voice" as NSString,
                           wait.deadline))
            }
            let result: AssemblyAIResult
            do {
                result = try await collectFinal(seconds: isLive ? 0 : seconds, socket: socket,
                                                allowReforce: !isLive, awaiting: awaiting,
                                                deadlineOverride: isLive ? wait.deadline : nil)
            } catch AssemblyAIError.noFinal where wait.quiet {
                throw AssemblyAIError.heardNothing(afterSeconds: wait.deadline)
            }
            if isLive {
                let ms = Int(now().timeIntervalSince(forcedAt) * 1000)
                log(String(format: "stt: assemblyai live %.1f s, final %d ms after end", Double(liveSent) / 16_000, ms))
            }
            scheduleIdleClose()
            return result
        } catch {
            live.deactivate()
            await tearDown(after: error)
            throw error
        }
    }

    /// What is left of a live turn after the pump: framed like a batch
    /// (100 ms pieces, a short remnant padded), so nothing under 50 ms is
    /// ever sent on its own.
    private func sendTail(_ tail: [Float], socket: any AssemblyAISocket) async throws {
        guard !tail.isEmpty else { return }
        for frame in AssemblyAIFraming.frames(AssemblyAIFraming.pcm16(tail)) {
            try await socket.send(.data(frame))
        }
        liveSamplesSinceForce += tail.count
        liveSamplesThisTurn += tail.count
        audioSecondsSent += Double(tail.count) / 16_000
    }

    /// One call on the wire at a time. A second caller (a discard while a
    /// read is finishing) waits its turn rather than interleaving.
    private func waitUntilFree() async {
        var waited = 0.0
        while busy, waited < finalGraceSeconds * 2 {
            await sleep(0.01)
            waited += 0.01
        }
    }

    /// How long this session will wait for a final, given how much audio
    /// it just sent in a burst. `TurnReadDeadline` has to stay looser than
    /// this, and a test holds the two against each other.
    public func batchDeadline(forSeconds seconds: Double) -> Double {
        finalGraceSeconds + seconds / processingRate
    }

    /// How long to wait for a final on a live turn the server opened no
    /// turn for. A final that is coming lands ~200 ms after the force-end.
    public static let quietFinalSeconds: Double = 1.0

    /// How long to wait for a final on a live turn whose audio went up as it
    /// was spoken. Measured over 499 live reads to 2026-10-15: the final
    /// came 317 ms after the force-end at the median, 587 ms at p90, 1.75 s
    /// at p99, and only four of 499 later than 2.5 s. The other 29 waits in
    /// that time ran the whole four seconds and got nothing (`no final
    /// within 4.0 s`), then read locally anyway.
    public static let liveFinalGraceSeconds: Double = 2.5

    /// Audio still unread by the server, past which a live turn is read like
    /// a batch: the quiet shortcut is off, and the wait covers the backlog.
    /// A pump keeping up leaves under 100 ms; 2026-10-01 02:45:50 left 8.9 s,
    /// after a credential took 5646 ms to mint.
    public static let realTimeBacklogSeconds: Double = 0.5

    struct LiveWait: Equatable {
        /// Seconds to wait for the final after the force-end.
        let deadline: Double
        /// True when no final in that time means nothing was said.
        let quiet: Bool
    }

    /// The one rule for how long a live turn waits for its final, and
    /// whether silence back means silence.
    ///
    /// "The server opened no turn, so nobody spoke" holds only when the
    /// server has had the audio in real time *and* the Mac's own ears agree.
    /// 2026-10-01 02:45:50: the session opened 5.6 s late, 8.9 s of audio
    /// went up in one burst just before the force-end, no partial had come
    /// back yet, and the read was called silent after one second — the local
    /// re-read made "How does that mean" of the first half and the rest
    /// became a second turn. 2026-10-02 00:33:43: "fifty dollars", level
    /// 0.066, called silent the same way. Every turn the shortcut was right
    /// about (13 from 10-01 to 10-13) had a level of 0.000–0.011.
    static func liveWait(serverHeardWords: Bool, backlogSeconds: Double,
                         localHeardSpeech: Bool, finalGrace: Double) -> LiveWait {
        if backlogSeconds > realTimeBacklogSeconds {
            return LiveWait(deadline: finalGrace + backlogSeconds / 1.25, quiet: false)
        }
        if !serverHeardWords, !localHeardSpeech {
            return LiveWait(deadline: quietFinalSeconds, quiet: true)
        }
        return LiveWait(deadline: min(finalGrace, liveFinalGraceSeconds), quiet: false)
    }

    /// Seconds of this turn's audio the server cannot have read by now: the
    /// tail about to go up, and whatever of the burst sent when the session
    /// opened it is still working through at 1.25× real time.
    private func unreadSeconds(tailSamples: Int) -> Double {
        var burst = 0.0
        if let at = burstAt, burstAtOpenSamples > 0 {
            let sent = Double(burstAtOpenSamples) / 16_000
            let left = sent / processingRate - now().timeIntervalSince(at)
            if left > 0 { burst = left * processingRate }
        }
        return Double(tailSamples) / 16_000 + burst
    }

    /// Whether the inbox holds any turn — partial or final — newer than the
    /// last final read: the server heard words in this utterance.
    private func hasTurnSinceLastFinal() -> Bool {
        for case .success(.turn(let t)) in inbox where t.order > lastFinalOrder { return true }
        return false
    }

    /// The turn the server has told us is open: a partial in the inbox newer
    /// than every final. Read just before a live force-end, when every
    /// frame in flight is this utterance's (the pump is held), so a partial
    /// of the next turn cannot be among them.
    private func openTurnOrder() -> Int? {
        var finalMax = lastFinalOrder
        var partialMax: Int?
        for case .success(.turn(let t)) in inbox {
            if t.endOfTurn { finalMax = max(finalMax, t.order) } else { partialMax = max(partialMax ?? t.order, t.order) }
        }
        guard let p = partialMax, p > finalMax else { return nil }
        return p
    }

    /// The rule for "which turns are this utterance's".
    ///
    /// Every `end_of_turn` turn read after our `ForceEndpoint` belongs to
    /// it, concatenated in order — never just the last. Measured 2026-09-06
    /// with `mode=balanced`: one utterance came back as six turns and a
    /// word went missing at a split; `max_accuracy` split 2 of 20. On the
    /// batch path, a turn still open after the first final (a partial
    /// arriving after it) is the server having applied the force-end before
    /// it finished the burst: it is forced again, once. On the live path
    /// the audio went up in real time, so a partial after the final is the
    /// *next* turn starting and is left alone.
    ///
    /// `awaiting` is the turn the server still had open when the live turn
    /// was force-ended (`openTurnOrder`). Its final is the force-end's
    /// answer and usually most of the utterance, so the settle does not
    /// start until it has come. On 2026-09-09 16:01:31Z a 67.7 s hold came
    /// back as two short auto-ended pieces already in the inbox and one
    /// fifty-second turn still being finalised; the read took the pieces,
    /// heard nothing for the 0.2 s settle, and handed the brain the first
    /// six seconds. If that final never comes the read fails, so the caller
    /// re-reads the whole buffer locally — a fragment is not an answer.
    private func collectFinal(seconds: Double, socket: any AssemblyAISocket,
                              allowReforce: Bool, awaiting: Int? = nil,
                              deadlineOverride: Double? = nil) async throws -> AssemblyAIResult {
        var finals: [AssemblyAITurn] = []
        var seen = Set<Int>()
        let deadline = deadlineOverride ?? batchDeadline(forSeconds: seconds)
        var remaining = deadline
        var forcedAgain = !allowReforce
        var settling = false
        var awaiting = awaiting
        while true {
            let started = now()
            let budget = settling ? min(settleSeconds, remaining) : remaining
            guard budget > 0 else {
                if awaiting != nil { throw AssemblyAIError.noFinal(afterSeconds: deadline) }
                break
            }
            let next = await nextMessage(within: budget)
            remaining -= now().timeIntervalSince(started)
            guard let next else {
                // Quiet. After a final, that is the end of the utterance —
                // unless the turn still open at the force-end has not come
                // back; before one, it is the deadline.
                if awaiting == nil, settling || !finals.isEmpty { break }
                throw AssemblyAIError.noFinal(afterSeconds: deadline)
            }
            switch next {
            case .failure(let error):
                throw error
            case .success(.turn(let turn)):
                if turn.endOfTurn {
                    if let a = awaiting, turn.order >= a { awaiting = nil }
                    guard turn.order > lastFinalOrder, seen.insert(turn.order).inserted else { continue }
                    finals.append(turn)
                    settling = awaiting == nil
                    remaining = max(remaining, settleSeconds)
                } else if settling, turn.order > (finals.last?.order ?? -1), !forcedAgain {
                    // Words still arriving after the final: the force-end
                    // landed before all the audio was through. Once more.
                    forcedAgain = true
                    try await socket.send(.text(#"{"type":"ForceEndpoint"}"#))
                    settling = false
                    remaining = max(remaining, finalGraceSeconds)
                }
            case .success(.error(let code, let message)):
                throw AssemblyAIError.server(code: code, message: message)
            case .success(.termination):
                throw AssemblyAIError.closed(code: 1000, reason: "terminated")
            case .success(.begin), .success(.other):
                continue
            }
        }
        guard !finals.isEmpty else { throw AssemblyAIError.noFinal(afterSeconds: deadline) }
        lastFinalOrder = finals.map(\.order).max() ?? lastFinalOrder
        let text = finals.map { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let confidences = finals.flatMap(\.wordConfidences)
        let confidence: Float? = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
        return AssemblyAIResult(text: text, confidence: confidence, turns: finals.count)
    }

    // MARK: Open / configure / close

    private func ensureOpen(context: AssemblyAIContext) async throws -> any AssemblyAISocket {
        if let socket { return socket }
        let conn = try await connection()
        let url = Self.url(base: conn.socketURL, context: context)
        let socket = try await factory.connect(url: url, authorization: conn.authorization)
        generation += 1
        let gen = generation
        self.socket = socket
        inbox.removeAll()
        applied = context
        lastUpdateAt = now()
        audioSecondsSent = 0
        openedAt = now()
        lastFinalOrder = -1
        liveSamplesSinceForce = 0
        liveSamplesThisTurn = 0
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await socket.receive()
                    guard case .text(let text) = frame else { continue }
                    let message = try AssemblyAIMessage.parse(text)
                    await self?.deliver(.success(message), generation: gen)
                } catch let error as AssemblyAIError {
                    await self?.deliver(.failure(error), generation: gen)
                    return
                } catch {
                    await self?.deliver(.failure(.closed(code: 0, reason: AssemblyAIRedact.describe(error))), generation: gen)
                    return
                }
            }
        }
        // `Begin` comes first and echoes the configuration; a misspelled
        // parameter is ignored rather than rejected, so the echo is the
        // only place a typo shows (docs/streaming/message-sequence).
        while true {
            guard let next = await nextMessage(within: finalGraceSeconds) else { throw AssemblyAIError.noBegin }
            switch next {
            case .success(.begin(let id, let model)):
                log("stt: assemblyai session \(id.prefix(8)) open, model \(model ?? "?")")
                return socket
            case .success(.error(let code, let message)):
                throw AssemblyAIError.server(code: code, message: message)
            case .failure(let error):
                throw error
            default:
                continue
            }
        }
    }

    /// Send `UpdateConfiguration` for whatever differs from what the server
    /// has, no more than once per `updateDebounceSeconds`. A change inside
    /// the window waits for the next utterance; nothing is lost, it just
    /// reaches the server one turn later.
    private func reconfigureIfNeeded(context: AssemblyAIContext, socket: any AssemblyAISocket) async throws {
        guard context != applied else { return }
        if let last = lastUpdateAt, now().timeIntervalSince(last) < updateDebounceSeconds { return }
        var body: [String: Any] = ["type": "UpdateConfiguration"]
        if context.keyterms != applied.keyterms { body["keyterms_prompt"] = context.keyterms }
        if context.languageCodes != applied.languageCodes { body["language_codes"] = context.languageCodes }
        if let agent = context.agentContext, agent != applied.agentContext { body["agent_context"] = agent }
        guard body.count > 1 else { applied = context; return }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        try await socket.send(.text(String(decoding: data, as: UTF8.self)))
        applied = context
        lastUpdateAt = now()
    }

    private func scheduleIdleClose() {
        idle?.cancel()
        let gen = generation
        idle = Task { [weak self, sleep, idleSeconds] in
            await sleep(idleSeconds)
            guard !Task.isCancelled else { return }
            await self?.closeIfIdle(generation: gen)
        }
    }

    private func closeIfIdle(generation gen: Int) async {
        guard gen == generation, !busy, !live.isActive else { return }
        await terminate()
    }

    /// Terminate politely: `{"type":"Terminate"}`, read to `Termination`,
    /// then close. "Closing the socket as soon as you send Terminate
    /// silently discards your last transcript" — and an unterminated
    /// session bills to the three-hour cap.
    public func terminate() async {
        guard let socket else { return }
        live.deactivate()
        var reported = false
        do {
            try await socket.send(.text(#"{"type":"Terminate"}"#))
            var remaining = finalGraceSeconds
            while remaining > 0 {
                let started = now()
                guard let next = await nextMessage(within: remaining) else { break }
                remaining -= now().timeIntervalSince(started)
                if case .success(.termination(let audio, let session)) = next {
                    report(audioSeconds: max(audio, audioSecondsSent), sessionSeconds: session)
                    reported = true
                    break
                }
                if case .failure = next { break }
            }
        } catch {}
        if !reported {
            let session = openedAt.map { now().timeIntervalSince($0) } ?? 0
            report(audioSeconds: audioSecondsSent, sessionSeconds: session)
        }
        await drop()
    }

    private func tearDown(after error: Error) async {
        guard socket != nil || openedAt != nil else { return }
        if case AssemblyAIError.heardNothing = error {
            // Not a failure, but the session is closed all the same: a socket
            // that heard nothing through real speech is the one a proxy has
            // quietly lost, and the next turn opens a fresh one while the
            // person talks.
            log("stt: assemblyai heard no words in that turn — the session is closed, the next turn opens a fresh one")
        } else {
            log("stt: assemblyai session failed — \(AssemblyAIRedact.describe(error))")
        }
        // A socket the server has already closed cannot take a Terminate;
        // one we are abandoning on a timeout should still get one so the
        // meter stops.
        if let socket, Self.stillAnswering(error) {
            try? await socket.send(.text(#"{"type":"Terminate"}"#))
        }
        let session = openedAt.map { now().timeIntervalSince($0) } ?? 0
        if openedAt != nil { report(audioSeconds: audioSecondsSent, sessionSeconds: session) }
        await drop()
    }

    /// Errors after which the socket may still be open and billing.
    static func stillAnswering(_ error: Error) -> Bool {
        switch error {
        case AssemblyAIError.noFinal, AssemblyAIError.heardNothing: return true
        default: return false
        }
    }

    private func drop() async {
        idle?.cancel(); idle = nil
        reader?.cancel(); reader = nil
        let s = socket
        socket = nil
        openedAt = nil
        audioSecondsSent = 0
        applied = AssemblyAIContext()
        inbox.removeAll()
        live.deactivate()
        if let w = waiter { waiter = nil; w.resume(returning: .failure(.cancelled)) }
        await s?.close()
    }

    /// Logged now; sent to the meter behind the call, never in front of it.
    ///
    /// The meter is a request to the edge. Awaited here, it sat between a
    /// failed read and its local re-read: 2026-10-02 00:33:44 a turn the
    /// cloud gave up on at once came back 13.3 s later, on a night the edge
    /// was timing out, with a discard and the next read queued behind it.
    private func report(audioSeconds: Double, sessionSeconds: Double) {
        log(String(format: "stt: assemblyai session closed — %.1f s audio, %.0f s open", audioSeconds, sessionSeconds))
        guard let usage else { return }
        Task.detached { await usage(audioSeconds, sessionSeconds) }
    }

    // MARK: Inbox

    private func deliver(_ result: Result<AssemblyAIMessage, AssemblyAIError>, generation gen: Int) {
        guard gen == generation else { return }
        if let w = waiter {
            waiter = nil
            w.resume(returning: result)
        } else {
            inbox.append(result)
        }
    }

    /// The next message, or nil when `seconds` pass without one.
    private func nextMessage(within seconds: Double) async -> Result<AssemblyAIMessage, AssemblyAIError>? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        // Only one call waits at a time; a second one (terminate() during a
        // transcribe) supersedes the first rather than stranding it.
        if let stale = waiter { waiter = nil; stale.resume(returning: nil) }
        waiterGeneration += 1
        let gen = waiterGeneration
        return await withCheckedContinuation { cont in
            waiter = cont
            Task { [weak self, sleep] in
                await sleep(seconds)
                await self?.expireWaiter(generation: gen)
            }
        }
    }

    private func expireWaiter(generation gen: Int) {
        guard gen == waiterGeneration, let w = waiter else { return }
        waiter = nil
        w.resume(returning: nil)
    }

    // MARK: URL

    /// The credential's socket URL with the session's own parameters
    /// appended: `encoding`, and when set `language_codes`,
    /// `keyterms_prompt` and `agent_context`. Query values are encoded
    /// strictly (RFC 3986 unreserved only), so `["a & b"]` survives the
    /// trip. Parameters already on the URL are left alone.
    public static func url(base: URL, context: AssemblyAIContext) -> URL {
        var items: [(String, String)] = [("encoding", "pcm_s16le")]
        if !context.languageCodes.isEmpty {
            items.append(("language_codes", AssemblyAIKeyterms.json(context.languageCodes)))
        }
        if !context.keyterms.isEmpty {
            items.append(("keyterms_prompt", AssemblyAIKeyterms.json(context.keyterms)))
        }
        if let agent = context.agentContext, !agent.isEmpty {
            items.append(("agent_context", agent))
        }
        let existing = base.query.map { Set($0.split(separator: "&").compactMap { $0.split(separator: "=").first.map(String.init) }) } ?? []
        let tail = items.filter { !existing.contains($0.0) }
            .map { "\($0.0)=\(encode($0.1))" }
            .joined(separator: "&")
        guard !tail.isEmpty else { return base }
        let joiner = (base.query?.isEmpty ?? true) ? "?" : "&"
        return URL(string: base.absoluteString + joiner + tail) ?? base
    }

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
