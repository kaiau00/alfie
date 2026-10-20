import Foundation

// The transcript's shape, and every pure step that produces it: tokens →
// utterances, two streams → one timeline, diarization → speaker numbers,
// segments → `[mm:ss] who: text` lines. Nothing here touches audio, models
// or files, so all of it is unit-tested (Tests/MoeMeetingTests).

/// Who said a segment. The mic stream is always `you`; the system stream is
/// `them`, numbered once diarization has run at the end of the meeting.
public enum Speaker: Equatable, Hashable, Codable, Sendable {
    case you
    case them(Int?)

    /// The label written in the transcript: `you`, `them`, `them (speaker 2)`.
    public var label: String {
        switch self {
        case .you: return "you"
        case .them(nil): return "them"
        case .them(let n?): return "them (speaker \(n))"
        }
    }

    public var isYou: Bool { if case .you = self { return true } else { return false } }
}

/// One line of the transcript.
public struct Segment: Equatable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: Speaker
    public var text: String

    public init(start: Double, end: Double, speaker: Speaker, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }

    /// `[mm:ss] you: text`
    public var line: String { "[\(Timeline.clock(start))] \(speaker.label): \(text)" }

    /// The same with the meeting's names applied: `[mm:ss] Dan: text` for a
    /// voice that has one, and the numbered label for one that does not
    /// (Phase B — see `SpeakerNameBook`).
    public func line(names: SpeakerNameBook) -> String {
        "[\(Timeline.clock(start))] \(names.label(for: speaker)): \(text)"
    }
}

/// A recognised token with its times, relative to the audio it came from.
/// Mirrors FluidAudio's `TokenTiming` without depending on it, so the
/// utterance logic stays pure.
public struct TimedToken: Equatable, Sendable {
    public var token: String
    public var start: Double
    public var end: Double

    public init(_ token: String, _ start: Double, _ end: Double) {
        self.token = token
        self.start = start
        self.end = end
    }
}

/// A stretch of one diarized speaker in the system stream.
public struct SpeakerSpan: Equatable, Sendable {
    public var speakerID: String
    public var start: Double
    public var end: Double

    public init(_ speakerID: String, _ start: Double, _ end: Double) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public enum Timeline {

    /// `mm:ss`, minutes growing past 59 so an hour-long meeting reads
    /// `75:12` rather than wrapping — and total.
    ///
    /// `Int(someDouble)` traps on a NaN, an infinity, or anything past
    /// Int.max, and the durations and bookmark times this is called with
    /// come out of `meeting.json` — an editable file on disk. A record
    /// saying `"durationSeconds": 1e19` crashed the app the moment the
    /// Meetings tab drew its row. A number that cannot be a clock reads as
    /// one that ran off the end of the dial.
    public static let maxClockSeconds: Double = 100 * 60 * 60   // 100:00:00
    public static func clock(_ t: Double) -> String {
        // `t > 0` is false for a NaN as well as for a negative and for
        // -infinity, so this one comparison covers the whole low end.
        guard t > 0 else { return "00:00" }
        let s = Int(Swift.min(t, maxClockSeconds).rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Joins SentencePiece tokens into words, splitting into segments on
    /// pauses longer than `gap`. `offset` shifts the token times into the
    /// meeting's clock (the window's start). Sentence-final punctuation
    /// that lands at the head of the next segment is dropped.
    public static func segments(from tokens: [TimedToken], speaker: Speaker,
                                offset: Double = 0, gap: Double = 0.8) -> [Segment] {
        var out: [Segment] = []
        var text = ""
        var start = 0.0, end = 0.0
        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            if !t.isEmpty { out.append(Segment(start: start + offset, end: end + offset, speaker: speaker, text: t)) }
            text = ""
        }
        for tok in tokens {
            if text.isEmpty {
                start = tok.start
            } else if tok.start - end > gap {
                flush()
                start = tok.start
            }
            var piece = tok.token
            if piece.hasPrefix("▁") { piece = " " + piece.dropFirst() }
            text += piece
            end = max(end, tok.end)
        }
        flush()
        return out
    }

    /// The same, with the speaker looked up per token — the end-of-meeting
    /// pass, once diarization is in: a segment also splits where the
    /// speaker changes, so one long recognised stretch with two people in
    /// it becomes two lines. `speakerAt` gets the token's midpoint in the
    /// meeting clock (offset applied).
    public static func segments(from tokens: [TimedToken], offset: Double = 0, gap: Double = 0.8,
                                speakerAt: (Double) -> Speaker) -> [Segment] {
        var out: [Segment] = []
        var text = ""
        var start = 0.0, end = 0.0
        var speaker = Speaker.them(nil)
        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            if !t.isEmpty { out.append(Segment(start: start + offset, end: end + offset, speaker: speaker, text: t)) }
            text = ""
        }
        for tok in tokens {
            let who = speakerAt((tok.start + tok.end) / 2 + offset)
            if text.isEmpty {
                start = tok.start; speaker = who
            } else if who != speaker || tok.start - end > gap {
                flush()
                start = tok.start; speaker = who
            }
            var piece = tok.token
            if piece.hasPrefix("▁") { piece = " " + piece.dropFirst() }
            text += piece
            end = max(end, tok.end)
        }
        flush()
        return out
    }

    /// A speaker-at-time function from diarization: the span containing
    /// the instant, else the nearest span by midpoint; numbered 1..N by
    /// first appearance. Empty spans → always `them` unnumbered.
    public static func speakerLookup(_ spans: [SpeakerSpan]) -> (Double) -> Speaker {
        guard !spans.isEmpty else { return { _ in .them(nil) } }
        var order: [String: Int] = [:]
        for span in spans.sorted(by: { $0.start < $1.start }) where order[span.speakerID] == nil {
            order[span.speakerID] = order.count + 1
        }
        return { t in
            let hit = spans.first { $0.start <= t && t <= $0.end }
                ?? spans.min { abs(($0.start + $0.end) / 2 - t) < abs(($1.start + $1.end) / 2 - t) }!
            return .them(order[hit.speakerID])
        }
    }

    /// Both streams as one transcript, by start time. Stable for equal
    /// starts: `you` first, so a reply never lands before what it answered
    /// when both begin on the same second.
    public static func merge(_ a: [Segment], _ b: [Segment]) -> [Segment] {
        (a + b).sorted { l, r in
            if l.start != r.start { return l.start < r.start }
            return l.speaker.isYou && !r.speaker.isYou
        }
    }

    /// Drop `you` lines that are really the far end leaking into the mic.
    ///
    /// Echo cancellation converges when far-end audio *starts*, not when the
    /// recording does, so the first second or two of a call arrives on both
    /// channels. On the first controlled test that put the opening of a
    /// sentence under `you` and the whole sentence under `them`, word for
    /// word — the user had not said anything at all.
    ///
    /// Matching on text rather than on level is what makes this safe: two
    /// people really do both say "yeah", so a short echo of a real word is
    /// indistinguishable and is left alone. A run of `minimumWords` or more
    /// that also appears in an overlapping `them` line is not a coincidence.
    public static func withoutEcho(_ segments: [Segment], minimumWords: Int = 4) -> [Segment] {
        let them = segments.filter { !$0.speaker.isYou }
        guard !them.isEmpty else { return segments }
        return segments.filter { seg in
            guard seg.speaker.isYou else { return true }
            let mine = normalisedWords(seg.text)
            guard mine.count >= minimumWords else { return true }
            let phrase = mine.joined(separator: " ")
            return !them.contains { far in
                // Overlap in time, allowing for the two streams' own clocks.
                far.start < seg.end + 1 && seg.start < far.end + 1
                    && normalisedWords(far.text).joined(separator: " ").contains(phrase)
            }
        }
    }

    /// Lowercased, punctuation dropped — an echo is the same words, not the
    /// same string: the two passes punctuate and capitalise differently.
    static func normalisedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Give every `them` segment the diarized speaker that overlaps it most;
    /// when nothing overlaps, the nearest span by midpoint. Speakers are
    /// numbered 1..N in order of first appearance, so the first person to
    /// talk is always "speaker 1" whatever id the diarizer chose. `you`
    /// segments and an empty diarization are left alone.
    public static func relabel(_ segments: [Segment], with spans: [SpeakerSpan]) -> [Segment] {
        guard !spans.isEmpty else { return segments }
        var order: [String: Int] = [:]
        for span in spans.sorted(by: { $0.start < $1.start }) where order[span.speakerID] == nil {
            order[span.speakerID] = order.count + 1
        }
        return segments.map { seg in
            guard case .them = seg.speaker else { return seg }
            var best: (id: String, overlap: Double)?
            for span in spans {
                let overlap = min(seg.end, span.end) - max(seg.start, span.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (span.speakerID, overlap) }
            }
            let id = best?.id ?? spans.min {
                abs(($0.start + $0.end) / 2 - (seg.start + seg.end) / 2)
                    < abs(($1.start + $1.end) / 2 - (seg.start + seg.end) / 2)
            }!.speakerID
            var s = seg
            s.speaker = .them(order[id])
            return s
        }
    }

    /// The transcript as text, one segment per line.
    public static func format(_ segments: [Segment]) -> String {
        segments.map(\.line).joined(separator: "\n")
    }

    /// The same, with a name for every voice that has one (Phase B). A book
    /// with no names in it gives exactly what `format(_:)` gives, which is
    /// what makes "no calendar access" and "nobody was named" the same code
    /// path as today.
    public static func format(_ segments: [Segment], names: SpeakerNameBook) -> String {
        guard names.hasNames else { return format(segments) }
        return segments.map { $0.line(names: names) }.joined(separator: "\n")
    }

    /// Distinct `them` speaker numbers, ascending.
    public static func speakerNumbers(_ segments: [Segment]) -> [Int] {
        Array(Set(segments.compactMap { if case .them(let n?) = $0.speaker { return n } else { return nil } })).sorted()
    }

    /// Parses lines this module wrote (`[mm:ss] who: text`) back into
    /// segments. `end` is the next line's start, or `start` for the last;
    /// lines that do not match are skipped.
    /// `names` is how a transcript that was written with names is read back
    /// in: a `who` that is not `you`, `them` or `them (speaker N)` is looked
    /// up there, so "Dan:" returns as the voice it was written for. A name
    /// the book does not know is skipped, like any other unparseable line.
    public static func parse(_ text: String, names: SpeakerNameBook = SpeakerNameBook()) -> [Segment] {
        var out: [Segment] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = line[line.index(after: line.startIndex)..<close]
            let parts = stamp.split(separator: ":")
            guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) else { continue }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let colon = rest.range(of: ": ") else { continue }
            let who = String(rest[..<colon.lowerBound])
            let body = String(rest[colon.upperBound...])
            let speaker: Speaker
            if who == "you" { speaker = .you }
            else if who == "them" { speaker = .them(nil) }
            else if who.hasPrefix("them (speaker "), let n = Int(who.dropFirst("them (speaker ".count).dropLast()) { speaker = .them(n) }
            else if let n = names.speaker(named: who) { speaker = .them(n) }
            else { continue }
            let t = Double(m * 60 + s)
            out.append(Segment(start: t, end: t, speaker: speaker, text: body))
        }
        for i in out.indices.dropLast() { out[i].end = max(out[i].start, out[i + 1].start) }
        return out
    }
}

// MARK: - Windows

public enum Windowing {
    /// The frame to cut a window at: the quietest 100 ms in the last
    /// `searchSeconds` of `samples` (16 kHz), so a 30 s window ends in a
    /// pause rather than mid-word. Returns `samples.count` when the window
    /// is too short to search or nothing is quieter than the rest.
    public static func bestCut(_ samples: [Float], searchSeconds: Double = 3,
                               sampleRate: Double = meetingSampleRate) -> Int {
        let hop = Int(sampleRate * 0.1)
        let searchFrames = Int(sampleRate * searchSeconds)
        guard hop > 0, samples.count > searchFrames + hop else { return samples.count }
        let from = samples.count - searchFrames
        var best = samples.count
        var bestEnergy = Double.greatestFiniteMagnitude
        var i = from
        while i + hop <= samples.count {
            var e = 0.0
            for j in i..<(i + hop) { e += Double(samples[j] * samples[j]) }
            if e < bestEnergy { bestEnergy = e; best = i + hop / 2 }
            i += hop
        }
        return best
    }

    /// True when a buffer holds nothing worth transcribing: below
    /// `thresholdDb` rms (-60 dBFS is digital near-silence; room tone on a
    /// laptop mic is around -50).
    public static func isSilent(_ samples: [Float], thresholdDb: Float = -60) -> Bool {
        guard !samples.isEmpty else { return true }
        var sum: Double = 0
        for v in samples { sum += Double(v * v) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return 20 * log10(max(Float(rms), 1e-10)) < thresholdDb
    }

    /// The hard floor a 100 ms frame has to clear before it can count as
    /// speech at all, whatever the room it was recorded in.
    ///
    /// It is the *second* of two conditions, not the gate — see
    /// `hasSpeech`. An absolute floor on its own cannot do this job, and
    /// the attempt to make it is what this constant is left over from. It
    /// was -45, and -45 silenced the first real meeting: 95 seconds of
    /// talking became one transcript line, because that microphone sat
    /// around -52 dBFS. Raising it to -50 recovered that meeting and
    /// admitted, measured on this module's own fixtures, everything a
    /// laptop room produces: steady room tone at -49, a fan at -47 and at
    /// -51, an AGC'd near-silence at -50, a far-end leak at -52. A single
    /// number cannot separate "quiet speech" from "quiet noise" because
    /// the two overlap in level; only the *contrast* with the room
    /// separates them.
    ///
    /// So -50 stays, and it now means only: a frame quieter than this is
    /// not worth handing to a recogniser however far above its room it
    /// sits. It is where the one microphone we have measurements for
    /// stopped being distinguishable from its own noise, and it is 15 dB
    /// under ordinary speech at a laptop (-20…-35). Rejecting steady noise
    /// is `speechOverNoiseDb`'s job now, so nothing pushes this number up
    /// any more.
    public static let absoluteFloorDb: Float = -50

    /// How far above the enclosing window's own noise floor a 100 ms frame
    /// must sit to count as speech.
    ///
    /// This is what actually rejects noise, and it rejects it for the
    /// right reason: room tone, a fan, an echo canceller's comfort noise
    /// and an AGC riding near-silence are all *steady*, so no frame of
    /// them stands out from the rest, at any level. Speech is not steady —
    /// syllables against pauses put 15–30 dB between the loud frames of a
    /// 100 ms analysis and the quiet ones, even for someone talking softly.
    ///
    /// 12 dB is deliberately below that range and well above what steady
    /// noise reaches. Measured (SpeechFloorTests): the noise cases here
    /// span 0.1–0.3 dB between their 10th percentile and their loudest
    /// frame, and a syllable-modulated far-end leak about 6 dB; ordinary
    /// speech clears the bar by 15 dB and more. The cost of 12 dB is real
    /// but narrow: a channel whose speech sits less than 12 dB above its
    /// own room is now rejected, and a recogniser given audio at that
    /// signal-to-noise ratio produces guesses anyway.
    public static let speechOverNoiseDb: Float = 12

    /// Which frame level counts as "the room": the 10th percentile.
    ///
    /// Not the minimum — one digitally-silent frame in a window would drag
    /// the baseline to -200 dBFS and let everything through. Not the
    /// median either: half of a busy window is speech, so the median moves
    /// with the talking it is supposed to be measured against. A tenth of
    /// a 30 s window is 3 s, and a 30 s window with less than 3 s of room
    /// in it is one where the relative test cannot help and the absolute
    /// floor is doing the work.
    public static let noisePercentile: Double = 0.10

    /// The rms level of every whole 100 ms frame, dBFS.
    public static func frameLevelsDb(_ samples: [Float], sampleRate: Double = meetingSampleRate) -> [Float] {
        let hop = Int(sampleRate * 0.1)
        guard hop > 0, samples.count >= hop else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / hop)
        var i = 0
        while i + hop <= samples.count {
            var e: Double = 0
            for j in i..<(i + hop) { e += Double(samples[j] * samples[j]) }
            out.append(Float(10 * log10(max(e / Double(hop), 1e-20))))
            i += hop
        }
        return out
    }

    /// The window's own noise floor — the `noisePercentile` frame level —
    /// or nil when there is not even one whole frame to measure.
    public static func noiseFloorDb(_ samples: [Float], sampleRate: Double = meetingSampleRate) -> Float? {
        let levels = frameLevelsDb(samples, sampleRate: sampleRate).sorted()
        guard !levels.isEmpty else { return nil }
        return levels[Swift.min(levels.count - 1, Int(Double(levels.count) * noisePercentile))]
    }

    /// True when at least `minFrames` 100 ms frames are both
    /// `overNoiseDb` above the enclosing window's noise floor **and**
    /// above `floorDb`. This is the gate before recognition.
    ///
    /// It has to be both. The echo-cancelled mic still carries the far end
    /// at -55…-70 dBFS (MEETING-MODE.md) and a recogniser handed that
    /// invents sentences — but so does one handed room tone at -49, a fan
    /// at -47, or an AGC holding silence at -50, all of which an absolute
    /// floor low enough to hear a quiet meeting must admit. What none of
    /// them do is *vary*: the relative half rejects them without knowing
    /// their level, and the absolute half stops the relative one firing on
    /// a faint tick in a digitally silent room, where the 10th percentile
    /// is -200 dBFS and everything is "12 dB above the floor".
    ///
    /// `noiseFloorDb` is the baseline to measure against. Pass the
    /// enclosing window's when checking part of one: a segment's own span
    /// is a second of speech with 100 ms of slack, and its own 10th
    /// percentile is the speech, so measuring a segment against itself
    /// passes everything.
    public static func hasSpeech(_ samples: [Float], minFrames: Int = 3,
                                 noiseFloorDb baseline: Float? = nil,
                                 overNoiseDb: Float = speechOverNoiseDb,
                                 floorDb: Float = absoluteFloorDb,
                                 sampleRate: Double = meetingSampleRate) -> Bool {
        let levels = frameLevelsDb(samples, sampleRate: sampleRate)
        guard !levels.isEmpty else { return false }
        let floor: Float
        if let baseline {
            floor = baseline
        } else {
            let sorted = levels.sorted()
            floor = sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * noisePercentile))]
        }
        let bar = floor + overNoiseDb
        var loud = 0
        for db in levels where db >= bar && db > floorDb {
            loud += 1
            if loud >= minFrames { return true }
        }
        return false
    }
}

// MARK: - Clocks

/// How far the two streams' clocks wandered apart over the meeting.
/// The tap is clocked by the tapped app's output device, the mic by the
/// input device (MEETING-MODE.md, "Clocks"); after leading-silence padding
/// both files start at the same instant, so any difference in length at the
/// end is drift plus at most one IO buffer of stop jitter.
public struct DriftReport: Equatable, Codable, Sendable {
    public var systemSeconds: Double
    public var micSeconds: Double
    public var wallSeconds: Double
    /// mic − system, seconds. Positive: the mic clock ran fast.
    public var differenceSeconds: Double { micSeconds - systemSeconds }
    public var partsPerMillion: Double {
        wallSeconds > 0 ? differenceSeconds / wallSeconds * 1_000_000 : 0
    }
    /// Above this the interleave at the end of a long call may flip two
    /// short utterances (MEETING-MODE.md): worth a line in the notes.
    public static let noteworthySeconds = 0.1

    public init(systemSeconds: Double, micSeconds: Double, wallSeconds: Double) {
        self.systemSeconds = systemSeconds
        self.micSeconds = micSeconds
        self.wallSeconds = wallSeconds
    }

    public init(systemFrames: Int, micFrames: Int, wallSeconds: Double, sampleRate: Double = meetingSampleRate) {
        self.init(systemSeconds: Double(systemFrames) / sampleRate,
                  micSeconds: Double(micFrames) / sampleRate, wallSeconds: wallSeconds)
    }

    public var isNoteworthy: Bool { abs(differenceSeconds) > Self.noteworthySeconds }

    /// One line for `meeting.json` and the notes; empty when there is
    /// nothing to say.
    public var note: String {
        guard isNoteworthy else { return "" }
        let ms = Int((abs(differenceSeconds) * 1000).rounded())
        let which = differenceSeconds > 0 ? "mic ran ahead of the call audio" : "call audio ran ahead of the mic"
        return "Clock drift: \(which) by \(ms) ms over \(Timeline.clock(wallSeconds)) "
             + "(~\(Int(abs(partsPerMillion).rounded())) ppm); timestamps near the end may be off by that much."
    }
}
