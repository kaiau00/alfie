import Foundation

/// How the confirmation dialog tells Moe it is waiting on a person.
///
/// Hermes reports a step as started *before* its pre_tool_call hook runs
/// (hermes-agent `agent/tool_executor.py`: `tool_progress_callback` fires,
/// then `handle_function_call` runs the hook), and the hook is what puts the
/// dialog up and then blocks until someone answers it. So for the whole time
/// the sheet sat on screen, the only thing Moe knew was "a send step is
/// running", and it said so every twelve seconds — "Still getting that ready
/// to send" — to a person who was expected to press a button nobody had
/// mentioned. Neither Moe nor the model can see that dialog; only the dialog
/// can say it is up.
///
/// A distributed notification, because the dialog is a separate process
/// started by a shell script started by Hermes, and this is the one channel
/// that reaches the app without a file or a socket to keep. Any process on
/// the Mac can observe one, so it carries **nothing about the message**: not
/// the recipient, not the words, not the channel. Only what kind of question
/// is on screen and whether the words in it can be changed.
public enum ConfirmSignal {
    /// Posted once, when the sheet is on screen and able to take an answer.
    public static let waiting = Notification.Name("com.moe.confirm.waiting")
    /// Posted when the dialog process ends, however it ends — answered,
    /// cancelled, or killed by a quit. A SIGKILL posts nothing, which is why
    /// the app also clears its wait when the step or the turn ends.
    public static let answered = Notification.Name("com.moe.confirm.answered")
    /// Posted, just before `answered`, when the card left without an answer
    /// because whoever asked for it went away or nobody answered in time
    /// (`ConfirmLifecycle`). Carries only the pid, like the others: the
    /// sentence about what was not sent goes to the inbox, a 0600 file,
    /// never onto a notification every process on the Mac can read.
    public static let withdrawn = Notification.Name("com.moe.confirm.withdrawn")

    /// "send" or "act", as the dialog was asked.
    public static let kindKey = "kind"
    /// "yes" when the message on the sheet is an editable field.
    public static let editableKey = "editable"
    /// The dialog's process id, as a string, so a waiting and an answered can
    /// be paired when two dialogs are up at once.
    public static let pidKey = "pid"
    /// On `withdrawn`: "yes" when the card left a note in the inbox, "no"
    /// when it was only logged (the person saw the card, or is at the Mac).
    public static let notedKey = "noted"
}
