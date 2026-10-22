import Foundation

/// Settings › Brain › "How long Moe may work on one thing" (docs/DEFAULTS.md
/// row 32): 5, 15, 30 or 60 minutes, default 30.
///
/// It is `claude_code.turn_timeout` in Hermes's config — the WHOLE-turn
/// ceiling for the Claude Code child, not a silence check. A turn still
/// running when it passes is stopped (the child is retired) and the gateway
/// ends the reply with `finish_reason: "error"` and "claude turn exceeded
/// N s" (hermes-agent claude_code_session.py). `HermesBrain` turns that into
/// the sentence below, so the pane's promise — "Moe stops it and tells you" —
/// is what the person actually sees.
///
/// Where it travels: the pane saves `Config.workLimitMinutes` and runs
/// `configure-hermes.py --set-turn-timeout SECONDS`; every launch's plain
/// configure run reads `workLimitMinutes` from config.json again (the way
/// `replyLength` reaches the chat channels), so Moe's own 300 → 1800 repair
/// can never undo a person's 5 minutes.
///
/// Never chosen is its own answer: `Config.workLimitMinutes` is nil and the
/// key is absent from config.json, so the launch run leaves a hand-set
/// `turn_timeout` (say 7200) alone. The pane still shows 30 selected.
enum WorkLimit {
    /// Minutes, in the order the chips show them.
    static let choices = [5, 15, 30, 60]
    static let defaultMinutes = 30

    /// The person's choice if it is one of `choices`; nil for none at all,
    /// and for a hand-edited 45 — which is not a choice the pane offered.
    static func chosen(_ minutes: Int?) -> Int? {
        guard let minutes, choices.contains(minutes) else { return nil }
        return minutes
    }

    /// One of `choices`; anything else — absent, a hand-edited 45 — is 30.
    static func normalised(_ minutes: Int?) -> Int {
        chosen(minutes) ?? defaultMinutes
    }

    static func label(_ minutes: Int) -> String {
        minutes == 60 ? "1 hour" : "\(minutes) minutes"
    }

    static func caption(_ minutes: Int) -> String {
        switch minutes {
        case 5:  return "Quick jobs only"
        case 15: return "Most errands"
        case 30: return "The usual choice"
        default: return "Long research"
        }
    }

    /// What the Claude Code child's turn ceiling says when it fires. Spelled
    /// as the fork spells it (`f"claude turn exceeded {elapsed}s"`).
    static let exceededMarker = "claude turn exceeded"

    /// The person's words for a turn the work limit stopped, or nil when the
    /// error is something else.
    static func personWords(forTurnError message: String) -> String? {
        guard message.contains(exceededMarker) else { return nil }
        return "That was taking longer than Alfie may work on one thing, so Alfie stopped it. "
            + "You can give it longer in Settings › Brain."
    }
}
