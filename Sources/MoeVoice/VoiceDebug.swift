import Foundation

/// The parts of the voice loop's diagnostics that are arithmetic, so they
/// are tests: VAD statistics for the turn trace, and the optional debug
/// clips — their WAV bytes, their names, and which to delete to stay under
/// the cap. The host does the file I/O. Nothing here leaves the Mac.
public enum VoiceDebug {

    /// Running statistics of Silero's per-chunk probability.
    public struct VadStats: Equatable, Sendable {
        public private(set) var count = 0
        public private(set) var sum = 0.0
        public private(set) var max = 0.0
        public init() {}
        public mutating func add(_ p: Float) {
            guard p.isFinite else { return }
            count += 1
            sum += Double(p)
            max = Swift.max(max, Double(p))
        }
        public var mean: Double? { count > 0 ? sum / Double(count) : nil }
    }

    /// The whole budget for clips on disk.
    public static let capBytes = 200 * 1024 * 1024

    /// Mono 16-bit PCM WAV.
    public static func wav(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples {
            let v = Int16(Swift.max(-1, Swift.min(1, s.isFinite ? s : 0)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return d
    }

    /// `20260922T231502Z-rejected-no-words.wav` — sortable, and the reason is
    /// in the name so a folder listing is already a label.
    public static func fileName(at date: Date, reason: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let safe = reason.lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
        return "\(f.string(from: date))-\(safe).wav"
    }

    public struct Stored: Equatable, Sendable {
        public let name: String
        public let bytes: Int
        public init(name: String, bytes: Int) { self.name = name; self.bytes = bytes }
    }

    /// Which files to delete, oldest first, so that what stays plus
    /// `incoming` fits under `cap`. Names sort by time (`fileName`).
    ///
    /// A clip and its sidecar (`X.wav`, `X.json`) share a stem and go
    /// together: a label with no audio is worthless, and audio with no
    /// label is an unlabelled clip in a folder that exists to be labelled.
    public static func prune(_ stored: [Stored], incoming: Int, cap: Int = capBytes) -> [String] {
        var total = stored.reduce(0) { $0 + $1.bytes } + incoming
        var groups: [String: [Stored]] = [:]
        for file in stored { groups[stem(file.name), default: []].append(file) }
        var out: [String] = []
        for key in groups.keys.sorted() {
            guard total > cap else { break }
            for file in groups[key]!.sorted(by: { $0.name < $1.name }) {
                out.append(file.name)
                total -= file.bytes
            }
        }
        return out
    }

    static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    // MARK: - Decision clips (voice-turns, Step 0)

    /// What a clip was saved for, written beside it as `<stem>.json`: the
    /// decision and the numbers it was made on, so a folder of clips is a
    /// folder of labelled examples rather than audio someone has to guess
    /// about. Never the words.
    public struct Sidecar: Codable, Equatable, Sendable {
        /// "turn" (an end-of-turn decision) or "barge-in".
        public var kind: String
        /// The endpoint (`VoiceMachine.EndReason`) or the onset outcome.
        public var reason: String
        /// Where in the clip the decision fell, in seconds.
        public var decidedAtSeconds: Double
        public var clipSeconds: Double
        public var turnModelP: [Double]?
        public var words: Int?
        public var bargeIn: BargeInDecision?
        /// Pauses in the clip the person talked through, in clip seconds —
        /// each one a labelled hold (`TurnPauses`). A held-key turn's are all
        /// of its pauses; a continued turn's include the one it was decided in.
        public var holds: [TurnPauses.Span]?
        /// What the clip is an example of, when that is known:
        /// "hold-to-talk" (the key said when the turn really ended),
        /// "continued" (decided in a pause the person then talked on after —
        /// a false endpoint), or nil.
        public var label: String?
        public init(kind: String, reason: String, decidedAtSeconds: Double, clipSeconds: Double,
                    turnModelP: [Double]? = nil, words: Int? = nil, bargeIn: BargeInDecision? = nil,
                    holds: [TurnPauses.Span]? = nil, label: String? = nil) {
            self.kind = kind; self.reason = reason
            self.decidedAtSeconds = decidedAtSeconds; self.clipSeconds = clipSeconds
            self.turnModelP = turnModelP; self.words = words; self.bargeIn = bargeIn
            self.holds = holds; self.label = label
        }
        public func json() -> Data {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            return (try? enc.encode(self)) ?? Data()
        }
    }

    /// Seconds of the turn kept before its decision, and after it — the
    /// window the turn model reads (8 s), and long enough past it to hear
    /// whether the person went on (the continuation window measured 1–3 s).
    public static let beforeDecisionSeconds = 8.0
    public static let afterDecisionSeconds = 2.5
    /// A held-key turn is kept whole up to this: every pause in it is a
    /// labelled hold, and 8 s would drop most of them (~1 MB a clip).
    public static let heldKeyClipSeconds = 30.0

    /// The labelled holds of a decision clip, in clip seconds.
    ///
    /// - Parameters:
    ///   - holds: pauses the person talked through before the decision, on
    ///     the same clock as `decisionT` (`TurnPauses`).
    ///   - lastWordT: the last word before a hands-free decision; nil for a
    ///     held key (its end is the key, not a pause).
    ///   - resumedT: when the person went on after the decision, if they did.
    ///     Inside the clip's after-part it makes the decision's own pause a
    ///     hold and the clip "continued" — a false endpoint, the example the
    ///     turn model most lacks.
    ///   - decidedAt: where the decision falls in the clip.
    /// Spans that fall outside the clip are dropped, not clipped: a half
    /// pause is not a measurement of one.
    public static func labelledHolds(_ holds: [TurnPauses.Span], decisionT: Double, lastWordT: Double?,
                                     resumedT: Double?, decidedAt: Double, clipSeconds: Double,
                                     label: String?) -> (holds: [TurnPauses.Span], label: String?) {
        func inClip(_ s: TurnPauses.Span) -> TurnPauses.Span {
            TurnPauses.Span(start: decidedAt - (decisionT - s.start), end: decidedAt - (decisionT - s.end))
        }
        var spans = holds.map(inClip)
        var label = label
        if let lastWordT, let resumedT, resumedT > decisionT, resumedT - decisionT <= afterDecisionSeconds,
           resumedT - lastWordT >= TurnPauses.shortest {
            spans.append(inClip(TurnPauses.Span(start: lastWordT, end: resumedT)))
            label = "continued"
        }
        let kept = spans.filter { $0.start >= -1e-9 && $0.end <= clipSeconds + 1e-9 && $0.duration > 0 }
        return (kept, label)
    }

    /// The clip around a decision: the last `beforeDecisionSeconds` of what
    /// led to it and whatever followed, joined. Returns the samples and where
    /// the decision falls in them.
    public static func decisionClip(before: [Float], after: [Float], sampleRate: Int = 16_000,
                                    beforeSeconds: Double = beforeDecisionSeconds,
                                    afterSeconds: Double = afterDecisionSeconds) -> (samples: [Float], decidedAt: Double) {
        let keepBefore = min(before.count, Int(beforeSeconds * Double(sampleRate)))
        let keepAfter = min(after.count, Int(afterSeconds * Double(sampleRate)))
        let head = before.suffix(keepBefore)
        let tail = after.suffix(keepAfter)
        return (Array(head) + Array(tail), Double(keepBefore) / Double(sampleRate))
    }
}
