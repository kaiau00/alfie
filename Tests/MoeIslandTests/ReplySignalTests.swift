import Testing
@testable import MoeIsland

/// docs/PANEL-FINDINGS.md §5. The signal that did not exist, and the reason
/// the panel could not open itself when Moe replied.
///
/// These tests replay the brain's event stream in the order `Conductor`
/// receives it, because every rule here is about *when* the signal fires, not
/// what it carries. The Conductor's own wiring is one line per case: `asked()`
/// where `awaitingReply = true`, `ended()` at each of the four ways a turn can
/// terminate, `abandoned()` where a turn is thrown away.
struct ReplySignalTests {

    // MARK: - It fires once, at the end, with the answer

    @Test func firesOnceAtTheEndOfATurn() {
        var signal = ReplySignal()
        signal.asked()
        #expect(signal.ended("The 3pm moved to 4.") == Reply(text: "The 3pm moved to 4.", failed: false))
    }

    /// Not on a streaming delta. There is no `delta` entry point at all —
    /// that is the point — so the check is that nothing but a terminal event
    /// can produce a reply, and that the terminal event is the *only* thing
    /// that disarms.
    @Test func staysArmedWhileTheAnswerIsStillArriving() {
        var signal = ReplySignal()
        signal.asked()
        #expect(signal.isArmed)
        // Deltas, tool calls, status lines and clock ticks all pass through
        // the Conductor without touching this.
        #expect(signal.isArmed)
        _ = signal.ended("done")
        #expect(!signal.isArmed)
    }

    /// A second terminal event for the same turn adds nothing. In practice
    /// this is `error` followed by `turnFinished`, which is exactly what the
    /// brain sends when a tool call fails inside a turn that still completes.
    @Test func doesNotFireTwiceForOneTurn() {
        var signal = ReplySignal()
        signal.asked()
        #expect(signal.ended("that didn't work", failed: true) != nil)
        #expect(signal.ended("here is the answer anyway") == nil)
    }

    @Test func eachQuestionGetsItsOwnAnswer() {
        var signal = ReplySignal()
        signal.asked()
        #expect(signal.ended("first") == Reply(text: "first", failed: false))
        signal.asked()
        #expect(signal.ended("second") == Reply(text: "second", failed: false))
    }

    // MARK: - Not for turns nobody asked for

    /// The silent background turns that keep the session warm or file a
    /// meeting never call `asked()`, so their `turnFinished` is silent here
    /// too. Nobody is waiting on them and nothing should open over the call.
    @Test func silentBackgroundTurnIsNotAReply() {
        var signal = ReplySignal()
        #expect(signal.ended("filed the meeting notes") == nil)
        #expect(signal.ended("warmed up", failed: true) == nil)
    }

    /// The one that would have been easy to get wrong: a background turn
    /// arriving *between* a question and its answer must not consume the
    /// answer the user is waiting for. It cannot, because the background turn
    /// finishing is itself an `ended` — which is why the Conductor arms on the
    /// question rather than trying to match turns up afterwards. This records
    /// the consequence: the first terminal event after a question is the one
    /// that answers it.
    @Test func theFirstEndingAfterAQuestionIsTheAnswer() {
        var signal = ReplySignal()
        #expect(signal.ended("background") == nil)
        signal.asked()
        #expect(signal.ended("the answer") == Reply(text: "the answer", failed: false))
        #expect(signal.ended("another background turn") == nil)
    }

    // MARK: - Failure is an answer

    @Test func anErrorFires() {
        var signal = ReplySignal()
        signal.asked()
        let reply = signal.ended("Claude keeps exiting (code 1).", failed: true)
        #expect(reply?.failed == true)
        #expect(reply?.text == "Claude keeps exiting (code 1).")
    }

    @Test func aBrainThatWillNotLaunchFires() {
        var signal = ReplySignal()
        signal.asked()
        #expect(signal.ended("Connect an AI to start — your Claude or ChatGPT plan, or an API key.", failed: true) != nil)
    }

    @Test func aBrainThatDiesMidThoughtFires() {
        var signal = ReplySignal()
        signal.asked()
        #expect(signal.ended("Claude stopped before answering (code 9).", failed: true) != nil)
    }

    // MARK: - An abandoned question is not answered

    /// ⌘N, opening another conversation, a stop, a rebuilt brain: the question
    /// went away, so no answer to it will ever arrive and nothing should open.
    @Test func anAbandonedTurnIsSilent() {
        var signal = ReplySignal()
        signal.asked()
        signal.abandoned()
        #expect(!signal.isArmed)
        #expect(signal.ended("Stopped.") == nil)
    }

    /// And abandoning does not poison the next question.
    @Test func abandoningDoesNotBreakTheNextQuestion() {
        var signal = ReplySignal()
        signal.asked()
        signal.abandoned()
        signal.asked()
        #expect(signal.ended("back to normal") != nil)
    }
}
