import Testing
@testable import MoeVoice

/// The recogniser's language setting is a *script* filter, so an English
/// setting still returns French, Romanian and Polish. These are the two
/// cases seen on the owner's own Mac, plus the English that must not be
/// caught by the rule that catches them.
struct AddresseeForeignTests {

    private func foreign(_ text: String) -> Bool {
        let words = TurnPolicy.normalise(text).split(separator: " ").map(String.init)
        return Addressee.looksForeign(text, words: words)
    }

    // MARK: - What it must catch

    /// Answered as a request on 2026-09-04 at 18:01.
    @Test func theFrenchOneThatWasAnswered() {
        #expect(foreign("ça ne veut rien"))
    }

    /// Answered as a request on 2026-09-04 at 14:14. All ASCII, so the
    /// letter test cannot see it — the function-word test is what catches it.
    @Test func theRomanianOneThatWasAnswered() {
        #expect(foreign("Acum z iszym"))
    }

    @Test func polishLetters() { #expect(foreign("gdzie jest książka")) }
    @Test func germanEszett() { #expect(foreign("die Straße")) }
    @Test func spanishTilde() { #expect(foreign("mañana por la")) }

    // MARK: - What it must not catch

    /// Every one of these is a real turn from the owner's log.
    @Test func ordinaryEnglishRequests() {
        for line in ["what is it", "where's the technology", "that was good",
                     "they're having your opponent", "even though that does not make sense",
                     "takes a little long time not gonna lie", "let's tell that",
                     "what is on my calendar", "remind me to call the bank",
                     "open my notes", "read out the last email"] {
            #expect(!foreign(line), "\(line)")
        }
    }

    /// Short commands have no room for a function word, so the rule does not
    /// apply below three words — otherwise "play music" would read as French.
    @Test func shortCommandsAreExempt() {
        for line in ["play music", "stop", "louder", "next track"] {
            #expect(!foreign(line), "\(line)")
        }
    }

    /// The accents English actually borrows are not evidence of anything.
    @Test func borrowedAccentsAreEnglish() {
        for line in ["book me a café table", "that is a naïve reading",
                     "send them my résumé"] {
            #expect(!foreign(line), "\(line)")
        }
    }

    // MARK: - It is a penalty, not a veto

    /// A bilingual household must still be able to use their assistant: the
    /// name is a sound, not an English word, and saying it is deliberate.
    @Test func namingMoeIsNeverPenalised() {
        let named = Addressee.Signals(text: "Moe, ça ne veut rien dire",
                                      namedMoe: true, secondsSinceReply: 2, moeAskedQuestion: false, speechSeconds: 2)
        let unnamed = Addressee.Signals(text: "ça ne veut rien dire",
                                        namedMoe: false, secondsSinceReply: 2, moeAskedQuestion: false, speechSeconds: 2)
        #expect(Addressee.score(named) > Addressee.score(unnamed))
        #expect(Addressee.score(named) >= 1)     // still reaches "for Moe"
    }

    /// And it does move the verdict on an unnamed one, or it would be a
    /// penalty that changes nothing.
    @Test func itActuallyMovesTheVerdict() {
        let english = Addressee.Signals(text: "what is the weather like",
                                        namedMoe: false, secondsSinceReply: 2, moeAskedQuestion: false, speechSeconds: 2)
        let french = Addressee.Signals(text: "ça ne veut rien dire",
                                       namedMoe: false, secondsSinceReply: 2, moeAskedQuestion: false, speechSeconds: 2)
        #expect(Addressee.score(english) - Addressee.score(french) >= 1.5)
    }
}
