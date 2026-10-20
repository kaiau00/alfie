import Testing
@testable import MoeIsland

/// The island while Moe works is one row (decided 2026-09-19).
@Suite struct WorkingRowTests {

    @Test func theRowShowsForTheWholeJob() {
        // Before the first word, and after it while tools run.
        #expect(WorkingRow.shows(thinking: true, acting: false, dictating: false, meetingOn: false))
        #expect(WorkingRow.shows(thinking: false, acting: true, dictating: false, meetingOn: false))
        #expect(WorkingRow.shows(thinking: true, acting: true, dictating: false, meetingOn: false))
    }

    @Test func idleListeningAndSpeakingAreTheConversation() {
        #expect(!WorkingRow.shows(thinking: false, acting: false, dictating: false, meetingOn: false))
    }

    @Test func dictationAndMeetingsKeepTheirOwnPanels() {
        #expect(!WorkingRow.shows(thinking: true, acting: true, dictating: true, meetingOn: false))
        #expect(!WorkingRow.shows(thinking: true, acting: true, dictating: false, meetingOn: true))
    }

    @Test func theLabelIsTheStepWithItsFirstLetterRaised() {
        #expect(WorkingRow.label(step: "searching your files") == "Searching your files")
        #expect(WorkingRow.label(step: "  looking at the screen ") == "Looking at the screen")
        #expect(WorkingRow.label(step: "Reading something on producthunt") == "Reading something on producthunt")
    }

    @Test func noStepFallsBackToThinking() {
        #expect(WorkingRow.label(step: nil) == "Thinking")
        #expect(WorkingRow.label(step: "") == "Thinking")
        #expect(WorkingRow.label(step: "   ") == "Thinking")
    }

    @Test func elapsedReadsAsAClock() {
        #expect(WorkingRow.elapsed(0) == "0:00")
        #expect(WorkingRow.elapsed(42.9) == "0:42")
        #expect(WorkingRow.elapsed(723) == "12:03")
        #expect(WorkingRow.elapsed(-3) == "0:00")
    }

    @Test func theSummaryUnderAnAnswer() {
        #expect(WorkingRow.summary(steps: 0, took: 48) == nil)
        #expect(WorkingRow.summary(steps: 1, took: nil) == "1 step")
        #expect(WorkingRow.summary(steps: 3, took: 48.4) == "3 steps · 48 s")
        // Under a second is not worth a number.
        #expect(WorkingRow.summary(steps: 2, took: 0.4) == "2 steps")
    }
}
