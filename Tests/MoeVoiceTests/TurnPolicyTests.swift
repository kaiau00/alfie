import Foundation
import Testing
@testable import MoeVoice

struct TurnPolicyTests {

    @Test func shortAgreementsAreBackchannels() {
        #expect(TurnPolicy.isBackchannel("Mm-hmm.", seconds: 0.4))
        #expect(TurnPolicy.isBackchannel("yeah", seconds: 0.3))
        #expect(TurnPolicy.isBackchannel("Okay, right", seconds: 0.9))
        // Nothing said is not a backchannel: it is nothing, and the caller
        // handles an empty turn on its own. Calling it a backchannel meant
        // that any transcript this reduced to nothing — every sentence in
        // a language written in another script, before `normalise` learned
        // them — was discarded as "mm-hmm".
        #expect(!TurnPolicy.isBackchannel("", seconds: 0.2))
    }

    @Test func realWordsAreNot() {
        #expect(!TurnPolicy.isBackchannel("yeah do that", seconds: 0.8))
        #expect(!TurnPolicy.isBackchannel("stop", seconds: 0.3))
        #expect(!TurnPolicy.isBackchannel("no", seconds: 0.3))
    }

    @Test func aLongYeahIsATurn() {
        #expect(!TurnPolicy.isBackchannel("yeah", seconds: 2.0))
    }

    @Test func punctuationMeansComplete() {
        #expect(TurnPolicy.completeness(of: "What time is it?") == .complete)
        #expect(TurnPolicy.completeness(of: "Send it.") == .complete)
    }

    @Test func danglingWordsMeanIncomplete() {
        #expect(TurnPolicy.completeness(of: "send it to") == .incomplete)
        #expect(TurnPolicy.completeness(of: "I think that, um") == .incomplete)
        #expect(TurnPolicy.completeness(of: "the meeting is at three and") == .incomplete)
        #expect(TurnPolicy.completeness(of: "well you know") == .incomplete)
    }

    @Test func plainWordsAreUnknown() {
        #expect(TurnPolicy.completeness(of: "what time is it") == .unknown)
        #expect(TurnPolicy.completeness(of: "") == .unknown)
    }

    @Test func budgetFollowsShape() {
        #expect(TurnPolicy.silenceBudget(for: "Done.", base: 1.0) == 0.5)
        #expect(TurnPolicy.silenceBudget(for: "and then", base: 1.0) == 2.0)
        #expect(TurnPolicy.silenceBudget(for: "what time is it", base: 1.0) == 1.0)
        #expect(TurnPolicy.silenceBudget(for: "and", base: 2.0, cap: 3.0) == 3.0)
    }

    @Test func aTurnInAnotherScriptIsNotABackchannel() {
        // `normalise` used to strip Hebrew and Russian to nothing, and an
        // empty normalisation counted as "mm-hmm" — so every short turn in
        // those languages was discarded.
        #expect(!TurnPolicy.isBackchannel("מה השעה", seconds: 0.9))
        #expect(!TurnPolicy.isBackchannel("что там", seconds: 0.9))
        #expect(!TurnPolicy.isBackchannel("...", seconds: 0.9))
        #expect(TurnPolicy.isBackchannel("mm-hmm", seconds: 0.9))
    }
}
