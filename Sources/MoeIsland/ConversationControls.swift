import Foundation

/// Where the island puts the controls a spoken conversation needs.
///
/// **Mute** (docs/FIXABLE-FAILURES.md bug 10). It arrived in 1cff8f1e on the
/// working row, and the working row is only there while the brain's turn
/// runs. The moment the turn ended — while Moe was still speaking the answer,
/// and all through the follow-up window after it — the island had no mute at
/// all. On 2026-09-23 at 21:39 the owner pressed mute, the turn ended, and
/// Moe "still heard" them: there was no button left to see that it was on,
/// or to press again. So mute is on whichever row the open panel is showing,
/// for the whole conversation — thinking, speaking, the follow-up and
/// listening — and on exactly one of them, so it is never offered twice.
///
/// **Per-answer ▶ ⏸ ↺** (bug 11). The rule for when an answer can be played
/// is the chat's, moved here so the chat and the island read one answer.
public enum ConversationControls {

    // MARK: - Muted, unmistakably (the owner, 2026-09-24)

    /// The red tab under the notch while muted and folded. A small grey
    /// mic-with-a-slash was not enough (2026-09-24: six mutes in half an
    /// hour and nothing on screen said which state he was in). It is a
    /// label, not a button: a click on it opens the island
    /// (`IslandBehaviour.click`). It said "Muted · tap to talk" and a tap
    /// unmuted, so reaching for the notch to look switched the mute off
    /// (2026-09-25).
    public static let mutedPill = "Muted"
    /// The one control that unmutes, on the open panel: a red pill with the
    /// slashed mic and this word, at the far end of the row from the ⋯ so a
    /// click aimed at the ⋯ cannot land on it.
    public static let unmuteButton = "Unmute"
    /// The same state as a sentence, for the chat's live bar.
    public static let mutedLine = "Muted — Alfie can't hear you until you unmute"
    public static let muteHelp = "Mute yourself — Alfie carries on, and stays deaf until you tap again"
    public static let unmuteHelp = "Unmute — Alfie hears you again. Holding the talk key talks through the mute."
    /// The conversation row's words while muted.
    public static let mutedRowLine = "Alfie can't hear you"

    /// Whether the collapsed island draws the red "Muted" tab under the
    /// notch. Muted is only ever true inside a conversation (it ends with
    /// one), so this is "muted, and nothing else owns the collapsed island":
    /// a meeting has its own tab and dictation its own strip.
    public static func showsMutedTab(presentation: IslandPresentation, muted: Bool,
                                     meetingOn: Bool, dictating: Bool) -> Bool {
        presentation == .collapsed && muted && !meetingOn && !dictating
    }

    /// The rows of the open island that can carry a live control.
    public enum Row: Equatable, Sendable {
        /// The one working row, while a turn runs (`WorkingRow`).
        case working
        /// ⏸ ▶ ↺ for the reply whose voice is out.
        case reply
        /// "Hide transcript", while Moe listens or works with it shown.
        case transcript
        /// The conversation's own line — "your turn", "muted" — when none
        /// of the rows above is showing.
        case conversation
    }

    /// The row that carries mute, or nil when there is nothing to mute.
    ///
    /// - Parameters:
    ///   - working: the panel is the working row (`WorkingRow.shows`, and
    ///     the transcript not asked for).
    ///   - voiced: a reply's voice is out, playing or paused.
    ///   - transcriptShown: the transcript row is up.
    ///   - inConversation: a spoken conversation is open.
    ///   - muted: the microphone is muted. Mute stays reachable while it is
    ///     on, whatever else is true, because it is also the way to unmute.
    public static func muteRow(working: Bool, voiced: Bool, transcriptShown: Bool,
                               inConversation: Bool, muted: Bool) -> Row? {
        guard inConversation || muted else { return nil }
        if working { return .working }
        if voiced { return .reply }
        if transcriptShown { return .transcript }
        return .conversation
    }

    /// Whether ▶ is offered on an answer. Never on anything but Moe's own
    /// finished, non-empty reply, and never while a turn is being worked on
    /// — that reply owns the voice — unless this answer's voice is already
    /// out, when ▶/⏸ is how it is held and let go (`Conductor.playReply`
    /// refuses the same cases).
    public static func canPlay(isMoe: Bool, streaming: Bool, hasText: Bool,
                               voiced: Bool, thinking: Bool) -> Bool {
        isMoe && !streaming && hasText && (voiced || !thinking)
    }
}
