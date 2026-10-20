import Foundation

/// What Moe says while a confirmation sheet is waiting on the person.
///
/// On this Mac nothing goes out until a person presses Send on the sheet
/// (`Sources/MoeConfirm`). Before this, Moe did not know the sheet was up:
/// Hermes had reported the send step as running, the hook was blocked on the
/// dialog, and every twelve seconds Moe said "Still getting that ready to
/// send" — which reads as Moe being stuck, when it is Moe waiting on you.
///
/// The dialog now says when it is up (`ConfirmSignal`), and these are the
/// words for that. The rule is the same as `SpokenStep`'s: say only what is
/// true. The sheet is on screen, the person has to press Send, and — when the
/// sheet allows it — they can change the words first. Nothing here says
/// "sending" or "sent": neither is true until they answer, and what happened
/// then is the model's to report from the tool's result.
///
/// Mac only. The away machine asks on the phone instead (`confirm-away.py`)
/// and never runs this dialog, so it never posts the signal.
public enum ConfirmWait {

    public enum Kind: Equatable {
        /// A message is going to a person: Send / Cancel.
        case send
        /// A tool that changes something: Do it / Always allow / Cancel.
        case act

        /// The dialog's own word for it; anything unrecognised is a send,
        /// which is the question that matters most to have named.
        public init(wire: String?) {
            self = (wire == "act") ? .act : .send
        }
    }

    /// Said once, the moment the sheet appears.
    public static func announcement(kind: Kind, editable: Bool) -> String {
        switch kind {
        case .send where editable:
            return "It's up on your screen — press Send when it looks right, or change the words first."
        case .send:
            return "It's up on your screen — press Send when it looks right."
        case .act:
            return "That needs your OK — it's up on your screen."
        }
    }

    /// Said at most once more, if the sheet is still waiting a while later.
    /// After that Moe is quiet: the person knows, and nagging them to press a
    /// button that sends a message is the wrong kind of pressure.
    public static func reminder(kind: Kind) -> String {
        switch kind {
        case .send: return "Still waiting for you to press Send."
        case .act:  return "Still waiting for your OK on screen."
        }
    }

    /// The island's status line for as long as the sheet is up — the typed
    /// turn's version of the announcement, for someone reading, not listening.
    public static func status(kind: Kind) -> String {
        switch kind {
        case .send: return "Waiting for you to press Send"
        case .act:  return "Waiting for your OK"
        }
    }

    /// How long after the announcement the one reminder may come.
    public static let reminderAfter: TimeInterval = 25
}
