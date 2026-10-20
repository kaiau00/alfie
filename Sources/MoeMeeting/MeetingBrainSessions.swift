import CryptoKit
import Foundation

/// Which of a meeting's five conversations with the brain a request belongs
/// to, and the session it goes on.
///
/// # The bug this exists to prevent
///
/// A meeting asks the brain five different things: action items every
/// minute, a recap when the user comes back, a caption for a screenshot,
/// the notes at the end, and a request to hand those notes to Telegram.
/// They all went through one object with one session id — and one session
/// id is one conversation.
///
/// The action scan runs about sixty times an hour and its whole prompt is
/// *reply with `{"actions":[…]}` and nothing else*. By the end of a long
/// meeting the session has been told that sixty times, so when the notes
/// request arrives asking for a six-key object, the model answers in the
/// shape it has been answering in all hour. `MeetingNotes.parse` rejects
/// it, the record reads "the brain's reply was not notes", and an
/// hour-long meeting has none.
///
/// Measured on 2026-09-08's 16:10 transcript against that Mac's own
/// gateway — same prompt, same model, same 59 KB of transcript:
///
///   * **on the meeting's shared session** — 11.6 s, and the reply is
///     `{"actions":[{"who":…,"what":…,"when":…}]}`: the scan's format, for
///     a request that never mentioned actions;
///   * **on a session of its own** — 64.7 s, and the reply is the notes.
///
/// The eleven seconds are the tell, and they match the original failure to
/// the second: that meeting stopped at 21:12:30 and was recorded as having
/// no notes at 21:12:45. It was never a timeout and never a dead child. The
/// model was answering the wrong question, quickly, because it had been
/// asked that question sixty times.
public enum MeetingBrainPurpose: String, CaseIterable, Sendable {
    /// Action items, every two minutes.
    case scan
    /// "You were away — here is what you missed."
    case recap
    /// One line describing a screenshot.
    case caption
    /// The notes, once, at the end.
    case notes
    /// Handing the finished notes to `send_message`.
    case delivery

    /// Hermes scopes its long-term memory by this.
    public var sessionKey: String { "\(MeetingSummaryPrompt.sessionKey)-\(rawValue)" }

    /// Whether the conversation carries over between requests.
    ///
    /// The recurring jobs keep one session for the length of a meeting,
    /// which keeps Hermes's child warm and is what they had before. The
    /// notes take a clean one every time: the whole transcript is in the
    /// prompt, there is nothing to carry over, and nothing may leak in.
    public var isContinuous: Bool { self != .notes }

    /// Whether this job runs on the provider's cheapest model
    /// (`MoeBrain.ModelTiers`) rather than the one the person chose.
    ///
    /// Everything but the notes. The scan, recap, caption and delivery are
    /// mechanical and recurring, and on 2026-09-15 the scan alone was 61
    /// Opus turns in one meeting. The notes are the one thing a person reads
    /// afterwards — speakers named, decisions pulled out — and happen once,
    /// so they keep the person's model. Decided by the owner, 2026-09-15.
    public var usesCheapestModel: Bool { self != .notes }
}

public enum MeetingBrainSession {

    /// A UUID that is a pure function of the meeting and the purpose.
    ///
    /// Both halves matter. The **purpose** has to be in the id, not only in
    /// the session key, because Hermes keys its transcript on the id — two
    /// purposes sharing an id share a conversation, which is the bug. The
    /// **meeting** has to be in it so that an hour of last week's action
    /// items is not still in the context of this week's.
    ///
    /// Derived rather than stored, so a retry inside one meeting lands on
    /// the same warm session and nothing has to remember what it minted.
    public static func id(meetingID: String, purpose: MeetingBrainPurpose) -> String {
        let digest = SHA256.hash(data: Data("moe-meeting/\(purpose.rawValue)/\(meetingID)".utf8))
        var bytes = Array(digest.prefix(16))
        // Shaped as a v4 UUID, so anything downstream that parses one can.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return parts.map(String.init).joined(separator: "-")
    }
}
