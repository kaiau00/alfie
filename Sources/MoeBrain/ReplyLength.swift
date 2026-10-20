import Foundation

/// How much Moe says: Settings › Replies › "How much Moe says".
///
/// Before this, the length of a reply was written into three places and
/// nobody could change it: "one or two short spoken sentences" in the voice
/// prompt, "Two spoken sentences is the default" in AGENTS.md, and "the
/// length the question actually needs" for a typed turn. Balanced is those
/// rules exactly, so it adds nothing to a turn and nobody's Moe changes until
/// they choose to change it.
///
/// Where it goes, and why there. The line rides on the user's message
/// (`Conductor.submit`), after the delivery reminder — the same carrier as
/// `BrainPrompt.typedTurnMarker`, for the same reason: Hermes bakes the system
/// prompt into its Claude Code child at spawn, and a system prompt that
/// changes respawns it (6.8 s, measured). It is also the last thing before the
/// answer, which is how it wins over the older default rules that are still
/// in the system prompt and in AGENTS.md files already on people's Macs.
///
/// The chat channels (Telegram, WhatsApp…) never see the notch's turn text;
/// they get the same choice through Hermes's own `platform_hints`, written by
/// `configure-hermes.py` from `replyLength` in Moe's config.json.
public enum ReplyLength: String, CaseIterable, Sendable {
    case short
    case balanced
    case detailed

    /// Anything unrecognised is Balanced: a typo in config.json should give
    /// the Moe everyone already has, not a surprising one.
    public init(configValue: String) {
        self = ReplyLength(rawValue: configValue.trimmingCharacters(in: .whitespaces).lowercased()) ?? .balanced
    }

    public var label: String {
        switch self {
        case .short:    return "Short"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }

    /// The line added to a turn, or nil when there is nothing to add.
    ///
    /// - Parameter readable: the turn is typed and will be read as writing
    ///   (`typedTurnMarker` is on it). A spoken turn is always tighter than a
    ///   written one at the same setting, because a listener cannot skim.
    public func turnLine(readable: Bool) -> String? {
        switch (self, readable) {
        case (.balanced, _):
            return nil
        case (.short, false):
            return """
            (Reply length, set by the user: short. Say it in one sentence — the \
            answer and nothing around it. This replaces any other length rule \
            in your instructions. If they ask for more, give more.)
            """
        case (.short, true):
            return """
            (Reply length, set by the user: short. A few lines at most — the \
            answer, then only what they need to act on it. No preamble, no \
            recap. This replaces any other length rule in your instructions. \
            If they ask for more, give more.)
            """
        case (.detailed, false):
            return """
            (Reply length, set by the user: detailed. Up to a short paragraph \
            out loud — the answer first, then the why and anything worth \
            knowing. Anything longer goes in writing, and you say where. This \
            replaces any other length rule in your instructions.)
            """
        case (.detailed, true):
            return """
            (Reply length, set by the user: detailed. Go in depth — the answer \
            first, then the reasoning, the options and their trade-offs, and \
            what to watch out for, organised with headings or short lists \
            where they help. This replaces any other length rule in your \
            instructions.)
            """
        }
    }
}
