import Foundation

// The small, pure pieces around a meeting: bookmarks ("note this"),
// per-channel health, off-the-record stretches, and whose assistant is in
// the room. All unit-tested; none of it touches audio.

// MARK: - Bookmarks

/// A moment the user marked during the meeting — the agent hotkey tapped
/// once. The label is the last few words heard around that time, filled
/// in once the transcript is final.
public struct Bookmark: Equatable, Codable, Sendable {
    public var time: Double
    public var label: String

    public init(time: Double, label: String = "") {
        self.time = time
        self.label = label
    }

    public var line: String { "[\(Timeline.clock(time))] \(label.isEmpty ? "bookmark" : label)" }
}

public enum Bookmarks {
    /// The last `words` words spoken at or before the bookmark (within
    /// `window` seconds), else the first words after it; empty if nothing
    /// was said near it.
    public static func label(for time: Double, in segments: [Segment], words: Int = 3, window: Double = 20) -> String {
        func tail(_ text: String) -> String {
            let parts = text.split(separator: " ")
            return parts.suffix(words).joined(separator: " ")
        }
        func head(_ text: String) -> String {
            text.split(separator: " ").prefix(words).joined(separator: " ")
        }
        if let before = segments.last(where: { $0.start <= time && time - $0.start <= window + ($0.end - $0.start) }) {
            let t = tail(before.text)
            if !t.isEmpty { return t } else { return t }
        }
        if let after = segments.first(where: { $0.start > time && $0.start - time <= window }) {
            return head(after.text)
        }
        return ""
    }

    /// Every bookmark labelled from the final transcript.
    public static func labelled(_ marks: [Bookmark], in segments: [Segment]) -> [Bookmark] {
        marks.map { Bookmark(time: $0.time, label: $0.label.isEmpty ? label(for: $0.time, in: segments) : $0.label) }
    }

    /// The lines for the summary prompt: "[12:34] …", one per bookmark.
    public static func promptLines(_ marks: [Bookmark]) -> String {
        marks.map(\.line).joined(separator: "\n")
    }
}

// MARK: - Channel health

/// "mic silent" / "no meeting audio": a channel that has been quiet for
/// `quietAfter` seconds. Levels arrive once a second from the recorder;
/// the last time each was above `soundDb` is all that is kept.
public struct ChannelHealth: Equatable, Sendable {
    public var lastMicSound: Double?
    public var lastSystemSound: Double?
    public var quietAfter: Double
    public var soundDb: Float

    /// How much of the meeting each stream spent above `soundDb`, in
    /// seconds. The live status only needs the *last* time a stream
    /// sounded; the keep-audio decision at the end needs *how much*,
    /// because "this channel carried audio and transcribed nothing" must
    /// not be provable by a single cough in a webinar (`ChannelEvidence`).
    ///
    /// Accumulated from the gaps between readings rather than from a
    /// reading count, so it stays in seconds whatever rate the caller
    /// polls at; a gap longer than a second (a stalled timer, a machine
    /// asleep) counts as one second, so a pause cannot inflate it.
    public private(set) var micSoundSeconds: Double = 0
    public private(set) var systemSoundSeconds: Double = 0
    private var lastObserved: Double?

    /// "The microphone is producing something."
    ///
    /// This was defined as `Windowing.speechFloorDb`, on the reasoning that
    /// a channel the UI calls live must be one the transcriber will read.
    /// The two numbers were five decibels apart and the gap did hide a real
    /// failure — but tying them together was the wrong repair, because they
    /// are not answering the same question. This one asks whether a device
    /// is delivering audio at all over the last twenty seconds; the
    /// recognition gate asks whether a particular thirty-second window
    /// contains speech, and it answers that against the window's own noise
    /// floor rather than against any fixed level (`Windowing.hasSpeech`).
    ///
    /// The pressure on them is opposite, too. This one wants to be low: a
    /// live-but-quiet microphone reported as "mic silent" sends the user to
    /// System Settings for a permission that is already granted. The
    /// recognition gate wants to be strict, because what it lets through a
    /// recogniser turns into invented sentences. A single constant cannot
    /// move in both directions, and while it was one, tightening either
    /// end broke the other.
    ///
    /// -50 dBFS: the level the one microphone we have measurements for
    /// hovered around while it was working, and below which a laptop input
    /// is indistinguishable from its own noise.
    public static let defaultSoundDb: Float = -50

    public init(quietAfter: Double = 20, soundDb: Float = ChannelHealth.defaultSoundDb) {
        self.quietAfter = quietAfter
        self.soundDb = soundDb
    }

    /// Feed one reading. `at` is meeting time in seconds.
    public mutating func observe(micDb: Float, systemDb: Float, at: Double) {
        let elapsed = lastObserved.map { Swift.max(0, Swift.min(at - $0, 1)) } ?? 0
        lastObserved = at
        if micDb > soundDb { lastMicSound = at; micSoundSeconds += elapsed }
        if systemDb > soundDb { lastSystemSound = at; systemSoundSeconds += elapsed }
    }

    public func micSilent(at now: Double) -> Bool { now - (lastMicSound ?? 0) >= quietAfter }
    public func systemSilent(at now: Double) -> Bool { now - (lastSystemSound ?? 0) >= quietAfter }

    /// The line for the island and the menu, or empty when both channels
    /// have sounded recently. Paused: nothing, by design — silence is the
    /// point.
    public func status(at now: Double, paused: Bool = false) -> String {
        guard !paused else { return "" }
        switch (micSilent(at: now), systemSilent(at: now)) {
        case (true, true): return "mic silent · no meeting audio"
        case (true, false): return "mic silent"
        case (false, true): return "no meeting audio"
        case (false, false): return ""
        }
    }
}

// MARK: - Off the record

/// The stretches a meeting was paused. Half-open while paused; `stop`
/// closes the last one.
public struct PauseLog: Equatable, Codable, Sendable {
    public struct Span: Equatable, Codable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
        public var seconds: Double { max(0, end - start) }
    }

    public private(set) var spans: [Span] = []
    private var openAt: Double?

    public init() {}

    public var isOpen: Bool { openAt != nil }

    public mutating func pause(at t: Double) {
        guard openAt == nil else { return }
        openAt = t
    }

    public mutating func resume(at t: Double) {
        guard let start = openAt else { return }
        openAt = nil
        spans.append(Span(start: start, end: max(start, t)))
    }

    public var totalSeconds: Double { spans.reduce(0) { $0 + $1.seconds } }

    /// True when `t` falls inside a closed span — a segment there is dropped.
    public func covers(_ t: Double) -> Bool { spans.contains { $0.start <= t && t < $0.end } }

    /// "Off the record: 01:10–02:05, 07:00–07:30 (1:25 in all)", or empty.
    public var note: String {
        guard !spans.isEmpty else { return "" }
        let list = spans.map { "\(Timeline.clock($0.start))–\(Timeline.clock($0.end))" }.joined(separator: ", ")
        return "Off the record: \(list) (\(Timeline.clock(totalSeconds)) in all, nothing kept)."
    }

    enum CodingKeys: String, CodingKey { case spans }
}

// MARK: - Whose assistant

/// The line everyone in the meeting should hear or read: "<Name>'s
/// assistant is taking notes". Not a vendor's bot — the user's own agent
/// in the room, and it says so.
public enum MeetingOwner {
    /// The first name in Hermes's USER.md ("Name: Jordan Avery. Goes by
    /// Ada." → "Ada"; "Name: Dan" → "Dan"), or nil when there is none.
    public static func name(fromUserMD text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("name:") else { continue }
            let rest = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            // A "goes by" alias wins: that is what people in the meeting call them.
            if let r = rest.range(of: "goes by ", options: .caseInsensitive) {
                let alias = rest[r.upperBound...].split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }).first
                if let alias, !alias.isEmpty { return String(alias) }
            }
            let first = rest.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }).first
            if let first, !first.isEmpty { return String(first) }
        }
        return nil
    }

    /// "Ada's assistant" / "my assistant".
    public static func assistantLabel(userName: String?) -> String {
        guard let n = userName?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "my assistant" }
        return n.hasSuffix("s") ? "\(n)' assistant" : "\(n)'s assistant"
    }

    /// The announcement, for the consent sheet, the clipboard, or a chat.
    public static func announcement(userName: String?) -> String {
        let who = assistantLabel(userName: userName)
        let cap = who.prefix(1).uppercased() + who.dropFirst()
        return "\(cap) is taking notes for this meeting. The recording stays on \(userName == nil ? "my" : "their") Mac."
    }
}
