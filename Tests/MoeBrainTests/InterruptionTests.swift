import Testing
@testable import MoeBrain

/// The failure this pins happened on 2026-09-04: a five-part request, one
/// clause corrected sixteen seconds in, and the other four silently dropped.
/// The literature calls it objective displacement. The rule here is that an
/// interruption amends unless it plainly withdraws, because amending is
/// reversible and replacing is not.
struct InterruptionTests {

    // MARK: - Corrections, which must keep the rest of the request

    @Test func theCorrectionThatLostFourFifthsOfARequest() {
        let n = Interruption.note(heard: "Checking your mail for that thread",
                                  saying: "You're not gonna be able to find it there. Check it on the web")
        #expect(n.contains("still stands"))
        #expect(!n.contains("let the rest go"))
    }

    @Test func ordinaryCorrectionsAmend() {
        for line in ["actually make it Friday", "no, the other one",
                     "wait — send it to Miriam instead", "use my work address",
                     "instead of Gmail use the web", "hang on, not that folder"] {
            #expect(!Interruption.abandons(line), "\(line)")
        }
    }

    /// "instead" alone is the commonest correction word in English and must
    /// not read as an abandonment — only "instead of all that" does.
    @Test func insteadIsACorrectionNotAnAbandonment() {
        #expect(!Interruption.abandons("send it to Mark instead"))
        #expect(Interruption.abandons("instead of all that, just tell me the address"))
    }

    // MARK: - Withdrawals, which must drop it

    @Test func plainWithdrawalsAbandon() {
        for line in ["never mind", "forget it", "scratch that", "cancel that",
                     "forget all that, what's the weather", "actually never mind"] {
            #expect(Interruption.abandons(line), "\(line)")
        }
    }

    @Test func aWithdrawalSaysToLetItGo() {
        let n = Interruption.note(heard: "Checking your mail", saying: "never mind, forget it")
        #expect(n.contains("let the rest go"))
        #expect(!n.contains("still stands"))
    }

    // MARK: - What was heard

    /// The model must not repeat a sentence the person has already been told,
    /// nor believe it finished one it did not.
    @Test func theNoteCarriesWhatWasActuallyHeard() {
        let n = Interruption.note(heard: "The file's at /tmp/x.png", saying: "check the web")
        #expect(n.contains("only up to"))
        #expect(n.contains("/tmp/x.png"))
    }

    @Test func nothingHeardSaysSo() {
        let n = Interruption.note(heard: "", saying: "check the web")
        #expect(n.contains("heard none of it"))
        #expect(n.contains("still stands"))
    }

    /// A thousand-character reply must not go into the next prompt whole.
    /// The cap is the last 160 characters of it — enough for the model to
    /// know where the person stopped hearing, and bounded regardless of how
    /// long Moe was talking for.
    @Test func aVeryLongReplyIsTrimmedNotDropped() {
        let long = String(repeating: "word ", count: 200)   // 1,000 chars
        let n = Interruption.note(heard: long, saying: "hang on")
        #expect(n.contains("only up to"))
        #expect(n.count < long.count / 2, "the reply must be trimmed, not carried whole")
        // The standing-plan sentence is the rest of it, and is fixed-length.
        let fixed = Interruption.note(heard: "x", saying: "hang on").count
        #expect(n.count <= fixed + 160)
    }

    /// It is one parenthetical, and it ends before the person's own words.
    @Test func theNoteIsWellFormed() {
        let n = Interruption.note(heard: "abc", saying: "do the other thing")
        #expect(n.hasPrefix("("))
        #expect(n.hasSuffix(") "))
        #expect(!n.dropLast(2).contains(")"))
    }
}
