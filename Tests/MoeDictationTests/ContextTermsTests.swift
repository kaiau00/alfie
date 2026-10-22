import Foundation
import Testing
@testable import MoeDictation

struct ContextTermsTests {

    // A stand-in for /usr/share/dict/words, so these tests say what they mean
    // and do not depend on which words a machine happens to ship.
    static let common = CommonWords([
        "the", "and", "for", "meeting", "sonnet", "haiku", "transcript",
        "dictation", "sparkle", "review", "please", "kubernetes",
        // Lemmas only, exactly as /usr/share/dict/words has them — the
        // inflection tests below depend on the plurals being absent.
        "tool", "test", "minute", "exist", "connector", "run", "code",
        "build", "server", "action", "type", "send", "message", "can",
        "that", "it", "company", "quick", "laptop", "file",
    ])
    var common: CommonWords { Self.common }

    // MARK: - What it keeps

    @Test func internalCapitalsAreKept() {
        #expect(ContextTerms.keeps("WhisperKit", common: common))
        #expect(ContextTerms.keeps("SwiftPM", common: common))
        #expect(ContextTerms.keeps("McCarthy", common: common))
    }

    @Test func acronymsAreKept() {
        #expect(ContextTerms.keeps("HIPAA", common: common))
        #expect(ContextTerms.keeps("GDPR", common: common))
    }

    @Test func identifiersAreKept() {
        #expect(ContextTerms.keeps("snake_case", common: common))
        #expect(ContextTerms.keeps("kebab-case", common: common))
        #expect(ContextTerms.keeps("Siobhan.Anwen", common: common))
    }

    @Test func lettersWithDigitsAreKept() {
        #expect(ContextTerms.keeps("sha256", common: common))
        #expect(ContextTerms.keeps("gpt5", common: common))
    }

    @Test func properNounsAreKept() {
        #expect(ContextTerms.keeps("Siobhan", common: common))
        #expect(ContextTerms.keeps("Anwen", common: common))
    }

    @Test func unknownLowercaseJargonIsKept() {
        #expect(ContextTerms.keeps("kubectl", common: common))
        #expect(ContextTerms.keeps("webhooks", common: common))
    }

    // MARK: - What it drops

    /// The whole reason this type exists. Every one of these was in the
    /// vocabulary file that started rewriting ordinary speech; none may ever
    /// be treated as a term again, however it is capitalised.
    @Test(arguments: ["Sonnet", "sonnet", "SONNET", "Haiku", "haiku",
                      "dictation", "Transcript", "Sparkle", "Meeting", "Review"])
    func everydayWordsAreDroppedWhateverTheCasing(word: String) {
        #expect(!ContextTerms.keeps(word, common: Self.common),
                "\(word) is an everyday word and must never be a term")
    }

    @Test func shortTokensAreDropped() {
        #expect(!ContextTerms.keeps("Alfie", common: common))
        #expect(!ContextTerms.keeps("a", common: common))
        #expect(!ContextTerms.keeps("C++", common: common))
    }

    @Test func addressesUrlsAndPathsAreDropped() {
        #expect(!ContextTerms.keeps("jane@example.ai", common: common))
        #expect(!ContextTerms.keeps("https://example.com", common: common))
        #expect(!ContextTerms.keeps("Users/izzy/moe", common: common))
    }

    @Test func numbersAndOverlongTokensAreDropped() {
        #expect(!ContextTerms.keeps("2026", common: common))
        #expect(!ContextTerms.keeps(String(repeating: "x", count: 60), common: common))
    }

    /// Every developer screen is covered in these, and they are shaped just
    /// like identifiers, so the identifier rule waves them through.
    @Test func hashesAndUuidsAreDropped() {
        #expect(!ContextTerms.keeps("8eb0764a-1c3f-4d0c-be7f-877ed32a6d3a", common: common))
        #expect(!ContextTerms.keeps("a1b2c3d4e5f6", common: common))
        #expect(!ContextTerms.keeps("deadbeefcafe", common: common))
        // A git range: each half is a character short of the threshold, so
        // the joiners have to come out before the length is judged.
        #expect(!ContextTerms.keeps("05dc526..915e9e1", common: common))
    }

    /// The hex rule must not eat short words that happen to be hex, nor real
    /// terms with digits in them.
    @Test func shortHexLikeWordsAndVersionedTermsSurvive() {
        #expect(!ContextTerms.isHexBlob("beef"))
        #expect(!ContextTerms.isHexBlob("face"))
        #expect(ContextTerms.keeps("sha256", common: common))
        #expect(ContextTerms.keeps("gpt5", common: common))
    }

    /// Four letters, lowercase, not in the dictionary: far more likely a typo
    /// or a fragment than a term worth boosting.
    @Test func shortUnknownLowercaseWordsAreDropped() {
        #expect(!ContextTerms.keeps("wibb", common: common))
    }

    // MARK: - Inflections and contractions

    /// `/usr/share/dict/words` lists lemmas, so a plural or a past tense
    /// reaches the guard looking like rare jargon. Every one of these was in
    /// the first live run of the harvest, offered as a name worth boosting.
    @Test(arguments: ["tools", "tests", "minutes", "existed", "connectors",
                      "running", "coding", "companies", "quickly"])
    func inflectedEverydayWordsAreDropped(word: String) {
        #expect(!ContextTerms.keeps(word, common: Self.common),
                "\(word) is an everyday word in disguise")
    }

    /// No dictionary lists contractions, so without the stem every apostrophe
    /// on screen arrives as its own proper noun.
    @Test(arguments: ["That's", "can't", "It's"])
    func contractionsAreDropped(word: String) {
        #expect(!ContextTerms.keeps(word, common: Self.common))
    }

    @Test func aPossessiveIsTheSameTermAsThePlainWord() {
        #expect(ContextTerms.stem("Cloudflare's") == "Cloudflare")
        #expect(ContextTerms.extract(["Cloudflare's Cloudflare"], common: common)
                == ["Cloudflare"])
    }

    /// A window full of code is a window full of ordinary words with
    /// punctuation between them. An identifier earns its place only when some
    /// part of it is distinctive on its own.
    @Test func identifiersOfEverydayPartsAreDropped() {
        #expect(!ContextTerms.keeps("build_server", common: common))
        #expect(!ContextTerms.keeps("action.type", common: common))
        #expect(!ContextTerms.keeps("send_message", common: common))
    }

    /// A joined token must be judged as an identifier even when it also has
    /// an internal capital — otherwise the capital alone carries it through.
    @Test func aJoinedTokenIsNotRescuedByItsCapital() {
        #expect(!ContextTerms.keeps("action.Type", common: common))
        #expect(!ContextTerms.keeps("send_Message", common: common))
    }

    @Test func identifiersWithADistinctivePartAreKept() {
        #expect(ContextTerms.keeps("kubectl_apply", common: common))
        #expect(ContextTerms.keeps("Siobhan.send", common: common))
    }

    // MARK: - Tokenising

    @Test func surroundingPunctuationIsStripped() {
        #expect(ContextTerms.tokens(in: "(WhisperKit), Siobhan's file.")
                == ["WhisperKit", "Siobhan's", "file"])
    }

    @Test func extractionReportsTheStemNotThePossessive() {
        #expect(ContextTerms.extract(["Siobhan's laptop"], common: common) == ["Siobhan"])
    }

    @Test func identifiersStayWhole() {
        #expect(ContextTerms.tokens(in: "call Module.Type and snake_case")
                == ["call", "Module.Type", "and", "snake_case"])
    }

    // MARK: - Extraction

    @Test func prosePassesThroughAndTermsComeOut() {
        let screen = "Please review the meeting transcript for WhisperKit and Siobhan."
        #expect(ContextTerms.extract([screen], common: common) == ["WhisperKit", "Siobhan"])
    }

    /// Anwen appears once, next to the cursor; Nithya twice, further away.
    /// The weighting is what makes a name in the sentence being written beat
    /// one in a sidebar.
    @Test func theNearestSourceOutranksTheRest() {
        let terms = ContextTerms.extract(["Anwen", "Nithya and Nithya"], common: common)
        #expect(terms.first == "Anwen")
        #expect(Set(terms) == ["Anwen", "Nithya"])
    }

    @Test func frequencyBreaksTiesWithinASource() {
        #expect(ContextTerms.extract(["", "Anwen Nithya Nithya"], common: common)
                == ["Nithya", "Anwen"])
    }

    @Test func duplicatesFoldTogetherKeepingTheFirstCasing() {
        #expect(ContextTerms.extract(["WhisperKit whisperkit WHISPERKIT"], common: common)
                == ["WhisperKit"])
    }

    @Test func theCapIsHonoured() {
        let many = (0..<200).map { "Name\($0)" }.joined(separator: " ")
        #expect(ContextTerms.extract([many], cap: 10, common: common).count == 10)
    }

    @Test func emptyInputGivesEmptyOutput() {
        #expect(ContextTerms.extract([], common: common).isEmpty)
        #expect(ContextTerms.extract(["", "   "], common: common).isEmpty)
    }

    /// Ordinary prose with no names in it must produce nothing at all. A
    /// harvest that always finds "terms" is a harvest that is always feeding
    /// the model noise.
    @Test func plainProseYieldsNothing() {
        let prose = "the meeting and the review for the transcript please"
        #expect(ContextTerms.extract([prose], common: common).isEmpty)
    }
}

struct LiveVocabularyTests {

    @Test func mergePutsTheUsersOwnTermsFirst() {
        #expect(LiveVocabulary.merge(["Siobhan"], ["Anwen"]) == ["Siobhan", "Anwen"])
    }

    @Test func mergeDropsScreenTermsTheUserAlreadyHas() {
        #expect(LiveVocabulary.merge(["Siobhan"], ["siobhan", "Anwen"])
                == ["Siobhan", "Anwen"])
    }

    @Test func mergeWithNothingLiveIsUnchanged() {
        #expect(LiveVocabulary.merge(["Siobhan"], []) == ["Siobhan"])
    }

    @Test func setThenClear() {
        let live = LiveVocabulary()
        live.set(["Anwen"])
        #expect(live.current() == ["Anwen"])
        live.clear()
        #expect(live.current().isEmpty)
    }

    /// The guarantee the whole design rests on: there is no way to persist one
    /// of these. If a `url` or a `sources` ever appears on this type, this is
    /// the test that should make someone justify it.
    @Test func thereIsNoPathToDisk() {
        let mirror = Mirror(reflecting: LiveVocabulary())
        #expect(!mirror.children.contains { $0.label == "url" || $0.label == "sources" })
    }
}
