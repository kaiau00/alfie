import Foundation

// Screen capture during a meeting — the decisions, not the pixels.
//
// Everything here is pure and tested: what the user configured
// (`CapturePolicy`), what the transcript just said that is worth a picture
// (`CaptureCueScan`), whether *now* is a moment to take one or to start a
// clip (`CaptureScheduler`), and what the record of a capture looks like
// (`CaptureRecord`). ScreenCaptureKit, the files and the hotkeys are in the
// app (`Sources/Moe/Meeting/MeetingCapture.swift`); they only ever ask this
// file "should I?" and tell it "I did".
//
// Why a separate decision layer: a screenshot taken by a rule the user
// cannot read is a screenshot the user cannot trust. Each auto capture
// carries the cue that caused it, and the cue is one of a short list the
// pane shows as switches.

// MARK: - Policy

/// Off, on request only, or on request *and* whenever a cue fires.
public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case off, manual, auto

    public var label: String {
        switch self {
        case .off: return "Off"
        case .manual: return "When I ask"
        case .auto: return "Automatically"
        }
    }
}

/// What a capture covers.
public enum CaptureScope: String, Codable, CaseIterable, Sendable {
    /// The display the meeting app is on (or under the mouse).
    case display
    /// The meeting app's own window — the shared screen, the slides, the
    /// faces — and nothing of yours around it.
    case window
    /// A rectangle the user dragged once and Moe remembers.
    case region

    public var label: String {
        switch self {
        case .display: return "Whole screen"
        case .window: return "The meeting window"
        case .region: return "An area I choose"
        }
    }
}

/// A rectangle in screen points, origin top-left of the main display's
/// coordinate space (what ScreenCaptureKit and `CGWindowList` use).
public struct CaptureRegion: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// Too small to be a deliberate selection — a click that slipped.
    public var isUsable: Bool { width >= 40 && height >= 40 }

    /// Clamped into `bounds`, so a region dragged on a display that has
    /// since been unplugged does not ask for pixels that do not exist.
    public func clamped(to bounds: CaptureRegion) -> CaptureRegion? {
        let x0 = max(x, bounds.x), y0 = max(y, bounds.y)
        let x1 = min(x + width, bounds.x + bounds.width), y1 = min(y + height, bounds.y + bounds.height)
        guard x1 > x0, y1 > y0 else { return nil }
        let r = CaptureRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return r.isUsable ? r : nil
    }
}

/// Why a picture was taken without being asked. Each one is a switch in
/// Settings › Meeting Capture; the label is the switch's text.
public enum CaptureCue: String, Codable, CaseIterable, Sendable {
    /// "Let me share my screen", "can you see my screen".
    case screenShare
    /// "Let me show you", "I'll walk you through" — someone is demonstrating.
    case walkthrough
    /// "As you can see", "this slide", "look at this chart".
    case visualReference
    /// The minute scan found a new action item.
    case actionItem
    /// "We agreed", "let's go with", "the decision is".
    case decision
    /// Your name was said.
    case nameMention

    public var label: String {
        switch self {
        case .screenShare: return "Someone shares their screen"
        case .walkthrough: return "Someone shows how something works"
        case .visualReference: return "Someone points at something on screen"
        case .actionItem: return "An action item is agreed"
        case .decision: return "A decision is made"
        case .nameMention: return "My name comes up"
        }
    }

    /// The short word that goes into a file name and a summary line.
    public var slug: String {
        switch self {
        case .screenShare: return "screen-share"
        case .walkthrough: return "walkthrough"
        case .visualReference: return "on-screen"
        case .actionItem: return "action-item"
        case .decision: return "decision"
        case .nameMention: return "name"
        }
    }

    /// Cues that mean *something is being shown*: the ones that can start
    /// a clip rather than only a still, and that keep a running clip alive.
    public var isVisual: Bool { self == .screenShare || self == .walkthrough || self == .visualReference }

    public static let defaults: [CaptureCue] = [.screenShare, .walkthrough, .visualReference, .actionItem, .decision]
}

/// Settings › Meeting Capture, as one value: what to capture, of what,
/// and when. Stored in config.json; every key has a default so an older
/// file — or a hand-edited one missing a key — still reads.
public struct CapturePolicy: Equatable, Codable, Sendable {
    public var screenshots: CaptureMode = .manual
    public var recording: CaptureMode = .manual
    public var scope: CaptureScope = .display
    public var region: CaptureRegion? = nil
    public var cues: [CaptureCue] = CaptureCue.defaults
    /// Two automatic stills are never closer than this.
    public var minGapSeconds: Double = 20
    /// And there are never more than this many in one meeting; the user's
    /// own do not count.
    public var maxAutoShots: Int = 60
    /// A clip a cue started ends by itself at this length…
    public var clipMaxSeconds: Double = 180
    /// …or this long after the last visual cue, whichever is first.
    public var clipIdleSeconds: Double = 45
    /// Ask the AI what is in each picture — one line, kept with it and read
    /// by the notes. Only with "Summarise with your AI" on.
    public var caption: Bool = true

    public init() {}

    /// Anything at all can be captured.
    public var isEnabled: Bool { screenshots != .off || recording != .off }
    /// Something can happen without the user asking.
    public var isAutomatic: Bool { screenshots == .auto || recording == .auto }

    public func wants(_ cue: CaptureCue) -> Bool { cues.contains(cue) }

    enum CodingKeys: String, CodingKey {
        case screenshots, recording, scope, region, cues, minGapSeconds, maxAutoShots
        case clipMaxSeconds, clipIdleSeconds, caption
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CapturePolicy()
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil)
        }
        screenshots = opt(CaptureMode.self, .screenshots) ?? d.screenshots
        recording = opt(CaptureMode.self, .recording) ?? d.recording
        scope = opt(CaptureScope.self, .scope) ?? d.scope
        region = opt(CaptureRegion.self, .region)
        cues = opt([CaptureCue].self, .cues) ?? d.cues
        minGapSeconds = max(0, opt(Double.self, .minGapSeconds) ?? d.minGapSeconds)
        maxAutoShots = max(0, opt(Int.self, .maxAutoShots) ?? d.maxAutoShots)
        clipMaxSeconds = max(5, opt(Double.self, .clipMaxSeconds) ?? d.clipMaxSeconds)
        clipIdleSeconds = max(5, opt(Double.self, .clipIdleSeconds) ?? d.clipIdleSeconds)
        caption = opt(Bool.self, .caption) ?? d.caption
    }
}

// MARK: - The record of a capture

public enum CaptureKind: String, Codable, Sendable {
    case screenshot, recording

    public var folder: String { self == .screenshot ? "shots" : "clips" }
    public var ext: String { self == .screenshot ? "jpg" : "mp4" }
}

/// Who asked for it. `user` is a hotkey, a menu item, a button; `agent` is
/// the AI (through `Moe --meeting-capture`); `auto` is a cue.
public enum CaptureTrigger: String, Codable, Sendable {
    case user, agent, auto
}

/// One picture or clip, as `meeting.json` keeps it and `summary.md` lists it.
public struct CaptureRecord: Equatable, Codable, Sendable {
    /// Relative to the meeting folder: `shots/003-00m32s-screen-share.jpg`.
    public var file: String
    public var kind: CaptureKind
    /// Meeting seconds when it was taken (for a clip: when it started).
    public var at: Double
    public var trigger: CaptureTrigger
    /// A cue's slug, or whatever the user or the agent said.
    public var reason: String
    /// What the AI saw in it, one line, when captioning is on.
    public var caption: String?
    public var durationSeconds: Double?

    public init(file: String, kind: CaptureKind, at: Double, trigger: CaptureTrigger, reason: String,
                caption: String? = nil, durationSeconds: Double? = nil) {
        self.file = file; self.kind = kind; self.at = at; self.trigger = trigger
        self.reason = reason; self.caption = caption; self.durationSeconds = durationSeconds
    }

    /// `[12:34] screen share — the Q3 dashboard, revenue up 12% (shots/003-….jpg)`
    public var line: String {
        var s = "[\(Timeline.clock(at))] "
        s += kind == .recording ? "clip" : "screenshot"
        if let durationSeconds, kind == .recording { s += " \(Timeline.clock(durationSeconds))" }
        let why = reason.replacingOccurrences(of: "-", with: " ")
        if !why.isEmpty { s += " · \(why)" }
        if let caption, !caption.isEmpty { s += " — \(caption)" }
        s += " (\(file))"
        return s
    }

    enum CodingKeys: String, CodingKey { case file, kind, at, trigger, reason, caption, durationSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        kind = ((try? c.decodeIfPresent(CaptureKind.self, forKey: .kind)) ?? nil) ?? .screenshot
        at = ((try? c.decodeIfPresent(Double.self, forKey: .at)) ?? nil) ?? 0
        trigger = ((try? c.decodeIfPresent(CaptureTrigger.self, forKey: .trigger)) ?? nil) ?? .user
        reason = ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil) ?? ""
        caption = (try? c.decodeIfPresent(String.self, forKey: .caption)) ?? nil
        durationSeconds = (try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)) ?? nil
    }
}

/// File names for captures: numbered so they sort, stamped so a person
/// browsing the folder can find "the one from ten minutes in", and tagged
/// with the reason.
public enum CaptureFile {
    /// `shots/003-00m32s-screen-share.jpg`
    public static func name(index: Int, at seconds: Double, kind: CaptureKind, reason: String) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        let stamp = String(format: "%02dm%02ds", t / 60, t % 60)
        let tag = slug(reason)
        return "\(kind.folder)/\(String(format: "%03d", index))-\(stamp)" + (tag.isEmpty ? "" : "-\(tag)") + ".\(kind.ext)"
    }

    /// Lowercase letters, digits and dashes, at most 24 characters: a reason
    /// typed by the user or the agent is arbitrary text, and it is going
    /// into a file name.
    public static func slug(_ reason: String) -> String {
        var out = ""
        var dash = false
        for ch in reason.lowercased() {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                out.append(ch); dash = false
            } else if !dash, !out.isEmpty {
                out.append("-"); dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        // Cut at a dash where possible, so the tail is a whole word.
        if out.count > 24 {
            let head = String(out.prefix(24))
            if let cut = head.lastIndex(of: "-"), head.distance(from: head.startIndex, to: cut) >= 8 {
                out = String(head[..<cut])
            } else {
                out = head
            }
        }
        return out
    }

    /// The safe form of a `file` read back from `meeting.json`: inside the
    /// meeting folder, one of the two capture folders, no traversal. The
    /// same guard `TranscriptFile.safeName` gives the transcript.
    public static func isSafe(_ file: String) -> Bool {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, ["shots", "clips"].contains(parts[0]) else { return false }
        let name = parts[1]
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("..") else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }
    }
}

// MARK: - Cues in the transcript

/// Phrases in the transcript that mean a picture would help. Local and
/// instant: nothing goes to a model for this, so it runs on every new line.
///
/// The lists are deliberately literal. "Look at this" is a cue; "look" is
/// not. A false cue costs one screenshot inside the rate limit, a missed
/// one costs nothing the summary needs — so the lists lean specific.
public enum CaptureCueScan {

    static let screenShare = [
        "share my screen", "sharing my screen", "share screen", "share the screen",
        "see my screen", "can you see my screen", "can everyone see", "can you all see",
        "let me share", "i'll share", "i will share", "going to share", "gonna share",
        "you should see my screen", "presenting now", "let me present",
    ]

    static let shareEnded = [
        "stop sharing", "stopped sharing", "stop the share", "stop presenting", "stopped presenting",
        "i'll stop sharing", "let me stop sharing",
    ]

    static let walkthrough = [
        "let me show you", "i'll show you", "i will show you", "show you how", "walk you through",
        "walk through it", "walk through this", "let me walk", "let me demo", "quick demo",
        "watch this", "here's how", "here is how", "i'll go through", "let me go through",
        "let me pull up", "let me open", "i'll pull up",
    ]

    static let visualReference = [
        "as you can see", "as you see here", "you can see here", "look at this", "looking at this",
        "this slide", "next slide", "on this slide", "this chart", "this graph", "this dashboard",
        "this diagram", "this table", "this page", "this screen", "on the screen", "on screen",
        "this number here", "over here", "right here", "this one here", "up here", "down here",
        "this section", "this part here", "see this", "if you look at",
    ]

    static let decision = [
        "we agreed", "we've agreed", "we have agreed", "let's go with", "lets go with",
        "we'll go with", "we will go with", "the decision is", "decision made", "so it's decided",
        "it's decided", "final answer", "let's lock", "we're going with", "we are going with",
        "agreed then", "that's settled", "settled then",
    ]

    /// Every cue this text carries, in the order of `CaptureCue.allCases`.
    /// `actionItem` and `nameMention` are never found here — they come from
    /// the minute scan and from `NameMention`.
    public static func cues(in text: String) -> [CaptureCue] {
        let t = fold(text)
        var out: [CaptureCue] = []
        if screenShare.contains(where: { has(t, $0) }) { out.append(.screenShare) }
        if walkthrough.contains(where: { has(t, $0) }) { out.append(.walkthrough) }
        if visualReference.contains(where: { has(t, $0) }) { out.append(.visualReference) }
        if decision.contains(where: { has(t, $0) }) { out.append(.decision) }
        return out
    }

    /// "Stop sharing" and its kin: the end of a clip a share started.
    public static func endsShare(_ text: String) -> Bool {
        let t = fold(text)
        return shareEnded.contains(where: { has(t, $0) })
    }

    /// A whole-phrase match, not a substring one. `fold` pads the text with
    /// spaces and single-spaces every token, so a phrase surrounded by
    /// spaces matches only on word boundaries: "the decision is" no longer
    /// fires on "the decision isn't", nor "this slide" on "this slideshow".
    static func has(_ folded: String, _ phrase: String) -> Bool {
        folded.contains(" \(phrase) ")
    }

    /// Cues in the lines from `index` on, each with the line it came from.
    public static func scan(_ segments: [Segment], from index: Int) -> [(cue: CaptureCue, segment: Segment)] {
        guard index < segments.count else { return [] }
        var out: [(CaptureCue, Segment)] = []
        for s in segments[index...] {
            for c in cues(in: s.text) { out.append((c, s)) }
        }
        return out
    }

    /// Lowercase, curly apostrophes straightened, every character that is
    /// not a letter, digit or apostrophe turned into a space, then collapsed
    /// to single spaces and padded. Punctuation becomes a boundary — so
    /// "share my screen." matches the phrase "share my screen", while
    /// "the decision isn't" keeps the apostrophe and so does *not* match
    /// "the decision is". This is what makes `has` a whole-word match.
    static func fold(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        let cleaned = String(lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "'") ? ch : " "
        })
        let words = cleaned.split(separator: " ").map(String.init)
        return " " + words.joined(separator: " ") + " "
    }
}

// MARK: - When to capture

/// The rate limits and the clip life cycle, as one value the app updates
/// as the meeting goes. Times are meeting seconds.
public struct CaptureScheduler: Equatable, Sendable {

    public enum Decision: Equatable, Sendable {
        case screenshot(reason: String)
        case startClip(reason: String)
        case stopClip
    }

    public struct Clip: Equatable, Sendable {
        public var startedAt: Double
        public var reason: String
        public var trigger: CaptureTrigger
        public var lastCueAt: Double
    }

    public private(set) var lastShotAt: Double?
    public private(set) var autoShots = 0
    public private(set) var clip: Clip?
    /// "Stop sharing" was heard while no clip ran; nothing to do, but
    /// remembered so the next visual cue within a few seconds — "…and
    /// share this one instead" — does not immediately start another.
    private var shareEndedAt: Double?

    public init() {}

    public var isRecording: Bool { clip != nil }

    /// A cue fired at `t`. Zero, one or two decisions: a still, a clip, both.
    public mutating func cue(_ cue: CaptureCue, at t: Double, policy: CapturePolicy) -> [Decision] {
        guard policy.wants(cue) else { return [] }
        var out: [Decision] = []
        if cue.isVisual, var running = clip {
            running.lastCueAt = t
            clip = running
        } else if cue.isVisual, policy.recording == .auto, clip == nil {
            // Not within a breath of "stop sharing": that is the same share
            // being tidied, not a new one.
            if let ended = shareEndedAt, t - ended < 5 {
                // fall through to the still below
            } else {
                clip = Clip(startedAt: t, reason: cue.slug, trigger: .auto, lastCueAt: t)
                out.append(.startClip(reason: cue.slug))
            }
        }
        if policy.screenshots == .auto, autoShots < policy.maxAutoShots,
           lastShotAt.map({ t - $0 >= policy.minGapSeconds }) ?? true {
            out.append(.screenshot(reason: cue.slug))
        }
        return out
    }

    /// The transcript said the share is over: an automatic clip ends. One
    /// the user started is theirs to stop.
    public mutating func shareEnded(at t: Double) -> Decision? {
        shareEndedAt = t
        guard let running = clip, running.trigger == .auto else { return nil }
        return .stopClip
    }

    /// Once a second or so: the clip limits.
    public mutating func tick(at t: Double, policy: CapturePolicy) -> Decision? {
        guard let running = clip, running.trigger == .auto else { return nil }
        if t - running.startedAt >= policy.clipMaxSeconds { return .stopClip }
        if t - running.lastCueAt >= policy.clipIdleSeconds { return .stopClip }
        return nil
    }

    /// The app took a still. Any trigger resets the gap — a picture the
    /// user just took is a picture the next cue need not repeat — but only
    /// automatic ones count towards the ceiling.
    public mutating func tookScreenshot(at t: Double, trigger: CaptureTrigger) {
        lastShotAt = t
        if trigger == .auto { autoShots += 1 }
    }

    /// The app started a clip on its own account (hotkey, menu, agent).
    public mutating func startedClip(at t: Double, reason: String, trigger: CaptureTrigger) {
        clip = Clip(startedAt: t, reason: reason, trigger: trigger, lastCueAt: t)
    }

    /// The clip is on disk (or failed): whichever, it is not running.
    public mutating func stoppedClip() {
        clip = nil
    }
}

// MARK: - Captioning

/// The one-line "what is in this picture" request, on the meeting session
/// with the picture attached. The reply is stored beside the file and read
/// by the summary; a picture is worth nothing to a text model otherwise.
public enum CaptureCaption {
    public static let system = """
    You are given one screenshot taken during a meeting, and the reason it was \
    taken. Describe what is on it in ONE line of at most 25 words — the kind of \
    thing (a slide, a dashboard, a document, code, a video call grid, a web \
    page), its title if it has one, and the one fact or number that matters. \
    Reply with the line only: no preamble, no quotes, no markdown. Never call a tool.
    """

    public static func user(reason: String, recentLines: String) -> String {
        var s = "Reason for the picture: \(reason.isEmpty ? "the user asked" : reason)."
        if !recentLines.isEmpty { s += "\nWhat was being said just before:\n\(recentLines)" }
        return s
    }

    /// The reply, as one clean line — or nil when the model returned
    /// nothing usable (empty, a refusal, a paragraph of markdown).
    public static func clean(_ reply: String) -> String? {
        var line = reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        while line.hasPrefix("\"") || line.hasPrefix("“") || line.hasPrefix("-") || line.hasPrefix("*") {
            line.removeFirst()
        }
        while line.hasSuffix("\"") || line.hasSuffix("”") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.count <= 200 else { return nil }
        let lower = line.lowercased()
        if lower.hasPrefix("i can't") || lower.hasPrefix("i cannot") || lower.hasPrefix("sorry") { return nil }
        return line
    }
}
