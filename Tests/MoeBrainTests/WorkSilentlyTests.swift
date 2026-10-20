import Foundation
import Testing
@testable import MoeBrain

/// "Work silently" — the island's button that stops progress speech for one
/// turn and says only the answer at the end.
///
/// Two things are guarded: what is silenced (and, as importantly, what never
/// is — the confirmation sheet), and where "the answer" starts in a reply that
/// is one stream of narration and answer together.
struct WorkSilentlyTests {

    // MARK: What is said

    @Test func talkedThroughByDefault() {
        let w = WorkSilently()
        #expect(!w.isOn)
        for line in WorkSilently.Line.allCases { #expect(w.speaks(line), "\(line)") }
    }

    @Test func pressedItSilencesEveryKindOfProgress() {
        var w = WorkSilently()
        let on = w.toggle()
        #expect(on)
        #expect(!w.speaks(.step))
        #expect(!w.speaks(.stillWorking))
        #expect(!w.speaks(.interim))
    }

    /// The sheet is not narration: the job stops until the person acts.
    @Test func theConfirmationSheetIsStillSaid() {
        var w = WorkSilently()
        w.toggle()
        #expect(w.speaks(.confirmSheet))
        #expect(w.speaks(.confirmReminder))
    }

    @Test func theAnswerIsStillSaid() {
        var w = WorkSilently()
        w.toggle()
        #expect(w.speaks(.finalReply))
    }

    @Test func pressedAgainTalksItThroughAgain() {
        var w = WorkSilently()
        w.toggle()
        #expect(w.buttonLabel == "Talk me through it")
        let on = w.toggle()
        #expect(!on)
        #expect(w.speaks(.step) && w.speaks(.stillWorking) && w.speaks(.interim))
        #expect(w.buttonLabel == "Work silently")
    }

    @Test func theNextTurnStartsTalkedThrough() {
        var w = WorkSilently()
        w.toggle()
        w.stepStarted(at: 12)
        w.reset()
        #expect(!w.isOn)
        #expect(w.stepOffsets.isEmpty)
        #expect(w.speaks(.interim))
    }

    // MARK: When it is offered

    @Test func offeredOnlyWhileASpokenTurnWorks() {
        #expect(WorkSilently.offered(awaitingReply: true, replySpeaks: true, abandoned: false))
        // Typed turns are already silent.
        #expect(!WorkSilently.offered(awaitingReply: true, replySpeaks: false, abandoned: false))
        // Nothing working.
        #expect(!WorkSilently.offered(awaitingReply: false, replySpeaks: true, abandoned: false))
        #expect(!WorkSilently.offered(awaitingReply: true, replySpeaks: true, abandoned: true))
    }

    @Test func switchingOnCutsQueuedNarrationButNeverTheSheet() {
        #expect(WorkSilently.cutsQueuedSpeech(confirmWaiting: false))
        #expect(!WorkSilently.cutsQueuedSpeech(confirmWaiting: true))
    }

    // MARK: Final versus interim

    /// The shape of a browser job: a line, a step, a line, a step, the answer.
    @Test func theAnswerIsTheTextAfterTheLastStep() {
        var w = WorkSilently()
        w.toggle()
        var text = "Let me look at what's open. "
        w.stepStarted(at: text.count)
        text += "Found three places, checking Friday. "
        w.stepStarted(at: text.count)
        let answer = "Booked Lupa for two at seven on Friday."
        text += answer
        let start = w.finalReplyStart(in: text)
        #expect(String(text.dropFirst(start)) == answer)
    }

    /// No step ran: the whole reply is the answer.
    @Test func noStepsMeansTheWholeReply() {
        let w = WorkSilently()
        #expect(w.finalReplyStart(in: "It's 72 and sunny.") == 0)
    }

    /// The model answered, then ran one more (bookkeeping) call and wrote
    /// nothing after it. Silence would lose the answer; the last words said
    /// are spoken instead.
    @Test func nothingAfterTheLastStepFallsBackToTheLastWords() {
        var w = WorkSilently()
        w.toggle()
        var text = "Checking your calendar. "
        w.stepStarted(at: text.count)
        let answer = "You're free at three — I've put it in."
        text += answer
        w.stepStarted(at: text.count)
        text += "\n  "
        let start = w.finalReplyStart(in: text)
        #expect(String(text.dropFirst(start)).trimmingCharacters(in: .whitespacesAndNewlines) == answer)
    }

    @Test func aReplyOfNothingSaysNothing() {
        var w = WorkSilently()
        w.stepStarted(at: 0)
        #expect(w.finalReplyStart(in: "") == 0)
        #expect(w.finalReplyStart(in: "   ") == 3)
    }

    /// Steps recorded mid-turn can outrun the finished text by a stripped
    /// marker; the offset is clamped rather than trusted.
    @Test func anOffsetPastTheEndIsClamped() {
        var w = WorkSilently()
        w.stepStarted(at: 5)
        w.stepStarted(at: 400)
        let text = "Done. The answer."
        let start = w.finalReplyStart(in: text)
        #expect(String(text.dropFirst(start)) == " The answer.")
    }

    /// Consecutive steps with nothing written between them are one boundary.
    @Test func repeatedBoundariesAreOne() {
        var w = WorkSilently()
        w.stepStarted(at: 10)
        w.stepStarted(at: 10)
        w.stepStarted(at: 4)
        #expect(w.stepOffsets == [10])
    }
}
