import Foundation

/// One finished answer to something the user asked.
///
/// The text is whatever the turn ended with. `failed` says the turn ended
/// badly — an error, a brain that would not launch, a process that exited
/// mid-thought. It is *still* an answer: a question that got an error is
/// answered, and anything watching this signal must be told, because
/// silence is the one outcome that reads as "Moe ignored me".
public struct Reply: Equatable, Sendable {
    public let text: String
    public let failed: Bool

    public init(text: String, failed: Bool) {
        self.text = text
        self.failed = failed
    }
}

/// "A turn ended with an answer", as a signal a view can act on.
///
/// docs/PANEL-FINDINGS.md §5: the island could see `mode`, `statusLine` and a
/// growing array of turns, none of which distinguishes *Moe answered you*
/// from *Moe started a tool call* or *the clock ticked*. This is the missing
/// distinction, kept deliberately small and out of the app target so it can
/// be tested without a Conductor, a brain or a window.
///
/// The rules, all of which are the shape of this type rather than the
/// discipline of its callers:
///
///  - **Armed by the question, not by the answer.** `asked()` is called from
///    exactly one place — the same place `awaitingReply` is set, which is the
///    user submitting something. The silent background turns that keep the
///    session warm or file a meeting never arm it, so they never fire it.
///  - **Fires once per turn.** `ended` disarms. A stream of deltas cannot
///    fire it at all; an `error` followed by a `turnFinished` fires once,
///    at the first of them, because that is the moment there is something
///    to show and the second one has nothing to add.
///  - **Failure fires.** See `Reply.failed`.
///  - **An abandoned turn is not an answer.** ⌘N, a new conversation, a stop
///    or a reset call `abandoned()`: the question went away, so no answer to
///    it will ever arrive and nothing should be announced.
public struct ReplySignal: Sendable {
    private var armed = false

    public init() {}

    /// Whether a question is outstanding. Test seam; the app does not read it.
    public var isArmed: Bool { armed }

    /// The user asked something.
    public mutating func asked() { armed = true }

    /// The turn ended. Returns the reply to hand out, or nil when there was
    /// no question waiting on it.
    public mutating func ended(_ text: String, failed: Bool = false) -> Reply? {
        guard armed else { return nil }
        armed = false
        return Reply(text: text, failed: failed)
    }

    /// The question was withdrawn before anything answered it.
    public mutating func abandoned() { armed = false }
}
