import Foundation
import Testing
@testable import MoeDictation

struct CorrectionLearnerTests {

    private func corrections(_ pasted: String, _ observed: String) -> [String] {
        CorrectionLearner.corrections(pasted: pasted, observed: observed).map(\.line)
    }

    // MARK: Finding swaps

    @Test func singleNameSwapInTheMiddle() {
        #expect(corrections("I spoke to Shavon about it.", "I spoke to Siobhan about it.")
                == ["shavon => Siobhan"])
    }

    @Test func swapAtTheStartWithTextBeforeThePaste() {
        // The field held a paragraph already; the paste landed after it.
        let observed = "Earlier notes from Monday's call. Nothing new.\n\nSiobhan will send the deck tomorrow."
        #expect(corrections("Shavon will send the deck tomorrow.", observed) == ["shavon => Siobhan"])
    }

    @Test func swapAtTheEndWithTextTypedAfter() {
        #expect(corrections("Please forward this to Shavon", "Please forward this to Siobhan, thanks!")
                == ["shavon => Siobhan"])
    }

    @Test func swapAtTheEndWhenMoreWasTypedAfterwards() {
        #expect(corrections("Please forward this to Shavon", "Please forward this to Siobhan and then close the ticket.")
                == ["shavon => Siobhan"])
    }

    @Test func twoAdjacentSwaps() {
        #expect(corrections("Ask Shavon Makgrath for it.", "Ask Siobhan McGrath for it.")
                == ["shavon => Siobhan", "makgrath => McGrath"])
    }

    @Test func twoSeparateSwaps() {
        #expect(corrections("Shavon and Nyle came by.", "Siobhan and Niall came by.")
                == ["shavon => Siobhan", "nyle => Niall"])
    }

    @Test func lowercaseRespellingOfTheSameSound() {
        #expect(corrections("run the kubectl command now", "run the kubektl command now")
                == ["kubectl => kubektl"])
    }

    @Test func punctuationAroundTheWordIsIgnored() {
        #expect(corrections("Send it to Shavon.", "Send it to Siobhan!") == ["shavon => Siobhan"])
        #expect(corrections("Send it to (Shavon)", "Send it to \"Siobhan\"") == ["shavon => Siobhan"])
    }

    @Test func swapsKeepPositionAcrossExtraWords() {
        // A word was inserted elsewhere; the swap is still isolated.
        #expect(corrections("Tell Shavon the meeting moved.", "Tell Siobhan the meeting has moved.")
                == ["shavon => Siobhan"])
    }

    // MARK: Not learning

    @Test func identicalTextLearnsNothing() {
        #expect(corrections("Nothing changed here at all.", "Nothing changed here at all.") == [])
    }

    @Test func caseOnlyChangeIsNotLearned() {
        #expect(corrections("deploy to kubernetes today", "deploy to Kubernetes today") == [])
    }

    @Test func shortWordsAreNotLearned() {
        #expect(corrections("send it to Al now", "send it to Ed now") == [])
    }

    @Test func nonAlphabeticWordsAreNotLearned() {
        #expect(corrections("the total is 1500 dollars", "the total is 1,500 dollars") == [])
        #expect(corrections("meet Shavon O'Neil today", "meet Shavon O'Neill today") == [])
        #expect(corrections("call Siobhan at 5pm", "call Siobhan at 6pm") == [])
    }

    @Test func commonWordSubstitutionIsAWordingChange() {
        #expect(corrections("I think there going", "I think their going") == [])
        #expect(corrections("put it over their", "put it over there") == [])
    }

    @Test func lowercaseUnrelatedWordIsAWordingChange() {
        // Not a name, not a respelling: the user changed their mind.
        #expect(corrections("we can maybe ship on friday", "we can probably ship on friday") == [])
    }

    @Test func insertionsAndDeletionsAreNotSwaps() {
        #expect(corrections("Ask Shavon for it", "Ask for it") == [])
        #expect(corrections("Ask Shavon for it", "Ask Shavon or Niall for it") == [])
        #expect(corrections("Ask Shavon Oconnor for it", "Ask Siobhan for it") == [])
    }

    @Test func fieldHoldingSomethingElseLearnsNothing() {
        // The user cleared the field and wrote a different sentence.
        #expect(corrections("Ask Shavon for the deck", "Never mind, I found Siobhan's deck") == [])
    }

    @Test func singleWordPasteHasNoAnchorAndLearnsNothing() {
        #expect(corrections("Shavon", "Siobhan") == [])
    }

    @Test func middleGapOfUnequalLengthIsSkipped() {
        #expect(corrections("Tell Shavon and Nyle today", "Tell Siobhan today") == [])
    }

    // MARK: Adversarial

    private let dictionary = CommonWords([
        "carry", "mark", "matt", "paris", "london", "berlin", "basically", "shown", "sean",
        "affect", "effect", "maybe", "probably", "deploy", "hopefully", "tomorrow", "today",
    ])

    private func learned(_ pasted: String, _ observed: String) -> [String] {
        CorrectionLearner.corrections(pasted: pasted, observed: observed, common: dictionary).map(\.line)
    }

    @Test func properNounSwappedForAnUnrelatedOneIsWording() {
        // Days, months, places: both capitalised, but not the same sound.
        #expect(learned("Let's meet on Monday at ten", "Let's meet on Tuesday at ten") == [])
        #expect(learned("Ship it in March please", "Ship it in April please") == [])
        #expect(learned("We fly to London on Friday", "We fly to Berlin on Friday") == [])
        // Even without a dictionary: days and months are built in.
        #expect(corrections("Let's meet on Monday at ten", "Let's meet on Tuesday at ten") == [])
    }

    @Test func realWordHeardIsNeverLearned() {
        // "carry => Carrie" would rewrite every "carry" the user ever says.
        #expect(learned("please carry the deck over", "please Carrie the deck over") == [])
        #expect(learned("it may affect the plan", "it may effect the plan") == [])
        #expect(learned("Paris is lovely in spring", "Parris is lovely in spring") == [])
        // ...while the same shape with a non-word heard form is a spelling.
        #expect(learned("please Shavon the deck over", "please Siobhan the deck over") == ["shavon => Siobhan"])
    }

    @Test func sameInitialProperNounSwapIsStillLearned() {
        // The documented residual: Mark → Matt looks like a respelling.
        #expect(learned("Tell Makr about it", "Tell Matt about it") == ["makr => Matt"])
    }

    @Test func deletingTheFirstPastedWordDoesNotPairWithEarlierText() {
        // Field held "Hi Mark," already; the user deleted "Basicly" from the
        // start of the paste. Without positional evidence the first letters
        // must match, so nothing pairs with "Mark".
        #expect(learned("Basicly I think we ship", "Hi Mark, I think we ship") == [])
        #expect(learned("Shavon I think we ship", "Hi Siobhan, I think we ship") == ["shavon => Siobhan"])
    }

    @Test func deletingTheLastPastedWordDoesNotPairWithLaterText() {
        #expect(learned("I will ask Shavon", "I will ask Bob tomorrow") == [])
        #expect(learned("I will ask Shavon", "I will ask Siobhan tomorrow") == ["shavon => Siobhan"])
    }

    @Test func fieldClearedAndRetypedWithSomeSharedWords() {
        // Fewer than half the pasted words survive in order.
        #expect(learned("Ask Shavon for the deck by Friday", "Deck? Ask Bob.") == [])
    }

    @Test func differentFieldInTheSameApp() {
        // Focus moved to the search box: its contents share nothing.
        #expect(learned("Shavon will send the deck tomorrow", "siobhan deck") == [])
    }

    @Test func autocompleteAppendingAfterTheWordIsNotASwap() {
        #expect(learned("Ping Shavon today", "Ping Shavon today\n\nSent from my phone") == [])
    }

    @Test func pasteLandedBeforeTheWatchWindowIsIgnored() {
        // The cursor was in the middle of a long note: the tail of the
        // field is other text and shares little with the paste.
        let tail = (0..<40).map { "line\($0) of unrelated notes" }.joined(separator: "\n")
        #expect(learned("Ping Shavon about the deck", tail) == [])
    }

    @Test func anEarlierCopyOfTheHeardWordIsNotConfusedWithThePaste() {
        // The name was in the field just before the paste too. The anchors
        // latch onto the earlier copy, so this is a miss — safe, but a
        // known limit of aligning by longest common subsequence.
        #expect(learned("Shavon called back", "Shavon called earlier.\nSiobhan called back") == [])
        // The earlier one fixed, the paste untouched: nothing to learn.
        #expect(learned("Shavon called back", "Siobhan called earlier.\nShavon called back") == [])
    }

    @Test func garbledWordFixedToASimilarRealWordIsARespelling() {
        // The heard form is not a word, the fix sounds the same: learned.
        #expect(learned("Shavon me the file", "shown me the file") == ["shavon => shown"])
        // A dissimilar real word is a change of wording.
        #expect(learned("Shavon me the file", "send me the file") == [])
    }

    @Test func doubleSwapOfNamesWithMixedEvidence() {
        #expect(learned("Shavon and Mark met", "Siobhan and Matt met") == ["shavon => Siobhan"])
    }

    @Test func wordsWithDigitsApostrophesOrHyphensAreLeft() {
        #expect(learned("open the k8s dashboard now", "open the K8S dashboard now") == [])
        #expect(learned("ask Shavon's team today", "ask Siobhan's team today") == [])
        #expect(learned("ask Anna-Marie for it", "ask Anna-Maria for it") == [])
    }

    @Test func unicodeNamesAreWords() {
        #expect(learned("send it to Zoey today", "send it to Zoë today") == ["zoey => Zoë"])
        #expect(learned("send it to Yosef today", "send it to יוסף today") == [])
    }

    @Test func hugePasteIsNotDiffed() {
        let words = (0..<(CorrectionLearner.maximumWords + 1)).map { "w\($0)" }
        let pasted = (["Shavon"] + words).joined(separator: " ")
        let observed = (["Siobhan"] + words).joined(separator: " ")
        #expect(learned(pasted, observed) == [])
        let ok = (["Shavon"] + words.prefix(CorrectionLearner.maximumWords - 1)).joined(separator: " ")
        #expect(learned(ok, ok.replacingOccurrences(of: "Shavon", with: "Siobhan")) == ["shavon => Siobhan"])
    }

    @Test func muchMoreTypedAfterThePasteLearnsNothing() {
        // The window is the paste's length plus a little; once the user
        // has typed past it the paste is out of view. A miss, not a lesson.
        #expect(learned("Ask Shavon for it please", "Ask Siobhan for it please — no wait, ask Niall, he has it and Shavon is out") == [])
        #expect(learned("Ask Shavon for it please", "Never mind. Ask Niall, he has it and Shavon is out this week.") == [])
    }

    // MARK: Confirmation

    @Test func promotedOnlyOnSecondSighting() {
        let c = Correction(heard: "Shavon", correct: "Siobhan")
        var p = CorrectionLearner.Pending()
        #expect(p.record([c]) == [])
        #expect(p.entries.count == 1)
        #expect(p.record([c]) == [c])
        #expect(p.entries.isEmpty)
        #expect(c.line == "shavon => Siobhan")
    }

    @Test func sameSightingTwiceInOneCallCountsOnce() {
        let c = Correction(heard: "shavon", correct: "Siobhan")
        var p = CorrectionLearner.Pending()
        #expect(p.record([c, c]) == [])
    }

    @Test func knownHeardFormsAreSkipped() {
        var p = CorrectionLearner.Pending()
        let c = Correction(heard: "Shavon", correct: "Siobhan")
        p.record([c], known: ["shavon"])
        p.record([c], known: ["shavon"])
        #expect(p.entries.isEmpty)
    }

    @Test func competingCorrectionsStayPendingSeparately() {
        var p = CorrectionLearner.Pending()
        let a = Correction(heard: "nyle", correct: "Niall")
        let b = Correction(heard: "nyle", correct: "Nile")
        #expect(p.record([a]) == [])
        #expect(p.record([b]) == [])
        #expect(p.entries.count == 2)
        #expect(p.record([b]) == [b])
        #expect(p.entries.map(\.correction) == [a])
    }

    @Test func pendingRoundTripsThroughJSON() {
        var p = CorrectionLearner.Pending()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        p.record([Correction(heard: "shavon", correct: "Siobhan")], now: now)
        let back = CorrectionLearner.Pending(data: p.data())
        #expect(back == p)
        #expect(CorrectionLearner.Pending(data: Data("not json".utf8)) == CorrectionLearner.Pending())
    }

    @Test func pendingIsCappedByLeastRecentlySeen() {
        var p = CorrectionLearner.Pending()
        for i in 0..<(CorrectionLearner.pendingCap + 5) {
            p.record([Correction(heard: "word\(i)", correct: "Word\(i)")],
                     now: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(p.entries.count == CorrectionLearner.pendingCap)
        #expect(!p.entries.contains { $0.correction.heard == "word0" })
        #expect(p.entries.contains { $0.correction.heard == "word\(CorrectionLearner.pendingCap + 4)" })
    }

    @Test func learnedLineIsAppliedByVocabulary() {
        let c = Correction(heard: "Shavon", correct: "Siobhan")
        let v = Vocabulary(lines: [c.line])
        #expect(v.apply(to: "ask shavon") == "ask Siobhan")
    }
}
