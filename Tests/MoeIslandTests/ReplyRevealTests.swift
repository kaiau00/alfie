import Testing
@testable import MoeIsland

/// docs/PANEL-FINDINGS.md §7: the panel that opens itself when Moe answers,
/// and the clock that folds it again.
struct ReplyRevealTests {

    // MARK: - When it opens at all

    /// During a meeting replies are shown, never spoken, so the panel is the
    /// only place the answer exists.
    @Test func opensDuringAMeeting() {
        #expect(ReplyReveal.opens(meetingOn: true, speaksReply: true))
        #expect(ReplyReveal.opens(meetingOn: true, speaksReply: false))
    }

    /// And anywhere spoken replies are switched off, for the same reason.
    @Test func opensWhenRepliesAreNotSpoken() {
        #expect(ReplyReveal.opens(meetingOn: false, speaksReply: false))
    }

    /// The island's standing rule — it never expands on its own — was written
    /// for a spoken assistant, and for a spoken assistant it is right: the
    /// answer already reached you, and a panel over your screen is an
    /// interruption rather than a delivery.
    @Test func staysClosedWhenMoeSpeaksTheAnswer() {
        #expect(!ReplyReveal.opens(meetingOn: false, speaksReply: true))
    }

    // MARK: - The three answers

    /// `.silent` is the default and is the rule as it was before there was a
    /// choice, so an omitted argument must behave exactly as the three tests
    /// above expect.
    @Test func silentIsTheDefaultAndIsTheOldRule() {
        #expect(ReplyReveal.opens(meetingOn: false, speaksReply: false, policy: .silent))
        #expect(!ReplyReveal.opens(meetingOn: false, speaksReply: true, policy: .silent))
    }

    /// Read along while Moe talks.
    @Test func alwaysOpensEvenWhenMoeSpeaks() {
        #expect(ReplyReveal.opens(meetingOn: false, speaksReply: true, policy: .always))
        #expect(ReplyReveal.opens(meetingOn: false, speaksReply: false, policy: .always))
    }

    /// Never a panel over a shared screen — even for an answer nothing else
    /// will announce. The chat window still has it.
    @Test func neverKeepsThePanelShut() {
        #expect(!ReplyReveal.opens(meetingOn: false, speaksReply: false, policy: .never))
        #expect(!ReplyReveal.opens(meetingOn: false, speaksReply: true, policy: .never))
    }

    /// The one case no preference reaches. Mid-meeting the reply is not
    /// spoken and the panel is the only copy of it, so `.never` there would
    /// mean an answer that exists nowhere at all.
    @Test func aMeetingOverridesEvenNever() {
        #expect(ReplyReveal.opens(meetingOn: true, speaksReply: false, policy: .never))
        #expect(ReplyReveal.opens(meetingOn: true, speaksReply: true, policy: .never))
    }

    /// config.json is a file the menu invites people to edit by hand.
    @Test func anUnknownPolicyIsTheDefault() {
        #expect(PanelReveal(configValue: "whenever") == .silent)
        #expect(PanelReveal(configValue: "") == .silent)
        #expect(PanelReveal(configValue: "always") == .always)
        #expect(PanelReveal(configValue: "never") == .never)
    }

    /// Every choice has a label, and no two share one — the pane shows the
    /// label and stores the raw value, so a duplicate would be two menu items
    /// that read identically and do different things.
    @Test func everyPolicyHasItsOwnLabel() {
        let labels = PanelReveal.allCases.map(\.label)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == PanelReveal.allCases.count)
    }

    // MARK: - The chosen clock

    /// Zero is the pane's "until I dismiss it": no clock is started at all.
    @Test func zeroMeansItWaitsToBeDismissed() {
        #expect(ReplyReveal.readingTime(seconds: 0) == nil)
    }

    /// So is anything that is not a usable number of seconds. `Config` rejects
    /// all of these before they reach here, so this is the second of two
    /// gates rather than the only one — but it is the gate next to the
    /// `UInt64(seconds * 1e9)` that `NotchIsland` hands to `Task.sleep`, and
    /// that conversion traps on every value below.
    @Test func nonsenseNeverBecomesAClock() {
        #expect(ReplyReveal.readingTime(seconds: -5) == nil)
        #expect(ReplyReveal.readingTime(seconds: 0.4) == nil)
        #expect(ReplyReveal.readingTime(seconds: .nan) == nil)
        #expect(ReplyReveal.readingTime(seconds: -.infinity) == nil)
        // Infinity is not an hour-long panel; it is not a number of
        // seconds at all, and the honest reading is "no clock".
        #expect(ReplyReveal.readingTime(seconds: .infinity) == nil)
    }

    /// A real choice is kept as it was chosen.
    @Test func aChosenNumberOfSecondsIsHonoured() {
        #expect(ReplyReveal.readingTime(seconds: 6) == 6)
        #expect(ReplyReveal.readingTime(seconds: 12) == 12)
        #expect(ReplyReveal.readingTime(seconds: 30) == 30)
    }

    /// A panel that self-opened over somebody's screen and stayed for a day
    /// is a bug however it was configured.
    @Test func aWeekIsCappedAtAnHour() {
        #expect(ReplyReveal.readingTime(seconds: 604_800) == 3600)
    }

    // MARK: - The clock

    /// Long enough to read what arrived, short enough that a panel sitting
    /// over somebody's video call is not still there a minute later.
    @Test func foldsWhenNobodyIsUsingIt() {
        #expect(ReplyReveal.due(cursorOverIsland: false, draftInProgress: false,
                                holdsTheKeyboard: false) == .fold)
    }

    /// The cursor resting on the panel means it is being read.
    @Test func waitsWhileTheCursorIsOnIt() {
        #expect(ReplyReveal.due(cursorOverIsland: true, draftInProgress: false,
                                holdsTheKeyboard: false) == .wait)
    }

    /// A half-typed question means it is being answered. Taking the panel
    /// away now would take the sentence with it.
    @Test func waitsWhileSomethingIsHalfTyped() {
        #expect(ReplyReveal.due(cursorOverIsland: false, draftInProgress: true,
                                holdsTheKeyboard: false) == .wait)
        #expect(ReplyReveal.due(cursorOverIsland: true, draftInProgress: true,
                                holdsTheKeyboard: false) == .wait)
    }

    /// Clicked into the field and thinking. Nothing is typed and the cursor
    /// may have wandered off, but the panel is plainly still in use.
    @Test func waitsWhileTheFieldHoldsTheKeyboard() {
        #expect(ReplyReveal.due(cursorOverIsland: false, draftInProgress: false,
                                holdsTheKeyboard: true) == .wait)
    }

    /// `wait` restarts the clock rather than cancelling it — which is what
    /// makes a panel left under an abandoned cursor fold the moment the
    /// cursor moves, instead of staying open for the rest of the call.
    @Test func waitingIsARestartNotACancel() {
        #expect(ReplyReveal.due(cursorOverIsland: true, draftInProgress: false,
                                holdsTheKeyboard: false) == .wait)
        // The next time it comes due, with the cursor gone:
        #expect(ReplyReveal.due(cursorOverIsland: false, draftInProgress: false,
                                holdsTheKeyboard: false) == .fold)
    }

    @Test func theReadingTimeIsLongEnoughToReadAndShortEnoughToForgive() {
        #expect(ReplyReveal.readingTime >= 8)
        #expect(ReplyReveal.readingTime <= 20)
    }

    // MARK: - A click somewhere else

    /// No grace period: the panel is over somebody's video call, and a click
    /// in another app is the clearest possible statement of "not now".
    @Test func aClickInAnotherAppGivesUpAtOnce() {
        #expect(ReplyReveal.outsideClickFolds(cursorOverIsland: false))
    }

    /// A click on the island itself is somebody using it, not dismissing it.
    /// The panel is non-activating, so this cannot be left to a global
    /// monitor's definition of "another app".
    @Test func aClickOnTheIslandIsNotAClickSomewhereElse() {
        #expect(!ReplyReveal.outsideClickFolds(cursorOverIsland: true))
    }
}
