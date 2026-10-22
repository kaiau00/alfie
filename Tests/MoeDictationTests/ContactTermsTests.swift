import Foundation
import Testing
@testable import MoeDictation

struct ContactTermsTests {

    @Test func namesAreSplitAndKept() {
        #expect(ContactTerms.filter(["Siobhan", "O'Brien", "Anna-Maria Vogel"])
                == ["Siobhan", "O'Brien", "Anna-Maria", "Vogel"])
    }

    @Test func junkIsDropped() {
        #expect(ContactTerms.filter([
            "J",              // initial
            "JD",             // two characters
            "mum",            // all lowercase
            "dad's phone",    // lowercase
            "+44 7700 900123", // phone-shaped
            "4B",             // digits
            "🎉",             // emoji
            "#1",             // reserved characters / digits
            "A => B",
            "",
            "   ",
        ]) == [])
    }

    @Test func organisationsKeepTheirWords() {
        // "Ltd" and "Inc" are everyday words and go.
        #expect(ContactTerms.filter(["Acme Widgets Ltd.", "AT&T", "Alfie, Inc."])
                == ["Acme", "Widgets", "AT&T", "Alfie"])
    }

    @Test func everydayWordsNeverBecomeTerms() {
        // A bare term is a case-insensitive rule: "Will" would capitalise
        // every "will" the user says, "The Bank" every "the".
        let common = CommonWords(["bank", "grace", "apple"])
        #expect(ContactTerms.filter(["Will Bank", "Grace Hopper", "The Home Depot", "Apple Inc.", "Siobhan"],
                                    common: common)
                == ["Hopper", "Depot", "Siobhan"])
        // Built-ins hold even with no dictionary given.
        #expect(ContactTerms.filter(["Will", "The", "Monday", "May", "Siobhan"]) == ["Siobhan"])
    }

    @Test func systemDictionaryKeepsProperNounsOnly() {
        let sys = CommonWords.system
        // Either the file is there and lowercase entries are common...
        if sys.words.count > 1_000 {
            #expect(sys.contains("Mark"))
            #expect(sys.contains("carry"))
            #expect(!sys.contains("Siobhan"))
            #expect(!sys.contains("shavon"))
        }
        // ...or only the built-ins are, and those always are.
        #expect(sys.contains("the"))
    }

    @Test func dedupedCaseInsensitivelyFirstSpellingWins() {
        #expect(ContactTerms.filter(["Dan Smith", "DAN", "Smith", "Daniel"]) == ["Dan", "Smith", "Daniel"])
    }

    @Test func cappedAtTheLimit() {
        let pure = (0..<50).map { i in "Person" + String(repeating: "a", count: i + 1) }
        #expect(ContactTerms.filter(pure, cap: 10).count == 10)
        #expect(ContactTerms.filter(pure).count == 50)
    }

    @Test func feedsVocabularyAsBareTerms() {
        let v = Vocabulary(lines: ContactTerms.filter(["Siobhan McGrath", "Acme Widgets"]))
        #expect(v.apply(to: "tell siobhan mcgrath about acme") == "tell Siobhan McGrath about Acme")
    }
}
