import Foundation
import Testing
@testable import MoeDictation

// Swift Testing rather than XCTest: the Command Line Tools ship the former
// but not the latter, and this project builds without Xcode.
struct TranscriptCleanerTests {

    /// Default rules minus the trailing space, so expectations read cleanly.
    private func clean(_ s: String, _ tweak: (inout TranscriptCleaner.Rules) -> Void = { _ in }) -> String {
        var r = TranscriptCleaner.Rules()
        r.trailingSpace = false
        tweak(&r)
        return TranscriptCleaner.clean(s, rules: r)
    }

    // MARK: Whitespace and trivial input

    @Test func emptyStaysEmpty() {
        #expect(TranscriptCleaner.clean("", rules: .default) == "")
        #expect(TranscriptCleaner.clean("   \n ", rules: .default) == "")
    }

    @Test func whitespaceCollapsed() {
        #expect(clean("  hello   there \t friend  ") == "Hello there friend")
    }

    @Test func trailingSpaceByDefault() {
        #expect(TranscriptCleaner.clean("hello", rules: .default) == "Hello ")
    }

    @Test func noTrailingSpaceAfterNewline() {
        #expect(TranscriptCleaner.clean("hello new line", rules: .default) == "Hello\n")
    }

    // MARK: Fillers

    @Test func simpleFillersRemoved() {
        #expect(clean("um so uh I think er we should go") == "So I think we should go.")
    }

    @Test func fillerWithCommaRemoved() {
        #expect(clean("Yes, um, I think so") == "Yes, I think so.")
    }

    @Test func leadingFillerLeavesCapitalisedSentence() {
        #expect(clean("Um, we need to ship this today") == "We need to ship this today.")
    }

    @Test func uhHuhSurvives() {
        #expect(clean("uh-huh") == "Uh-huh")
    }

    @Test func fillerInsideWordsUntouched() {
        // "umbrella", "eraser", "ahead" contain filler substrings.
        #expect(clean("the umbrella and the eraser are ahead") == "The umbrella and the eraser are ahead.")
    }

    @Test func youKnowRemovedOnlyWhenFenced() {
        #expect(clean("So, you know, it just works") == "So, it just works.")
        #expect(clean("Do you know him at all") == "Do you know him at all.")
    }

    @Test func iMeanItSurvives() {
        #expect(clean("I mean it this time") == "I mean it this time.")
        #expect(clean("Well, I mean, it's fine") == "Well, it's fine")
    }

    @Test func likeIsNeverTouched() {
        #expect(clean("I like, really like this") == "I like, really like this.")
    }

    // MARK: Stutters

    @Test func adjacentShortDuplicatesCollapse() {
        #expect(clean("the the cat sat on on the mat") == "The cat sat on the mat.")
    }

    @Test func tripleStutterCollapses() {
        #expect(clean("I I I want to go home now") == "I want to go home now.")
    }

    @Test func fillerExposesStutter() {
        #expect(clean("the um the meeting starts at noon") == "The meeting starts at noon.")
    }

    @Test func longWordsNotCollapsed() {
        #expect(clean("it was very very good indeed") == "It was very very good indeed.")
    }

    @Test func hadHadAndThatThatSurvive() {
        #expect(clean("I had had enough of that") == "I had had enough of that.")
        #expect(clean("I know that that is true") == "I know that that is true.")
    }

    @Test func stutterAfterExceptionStillCollapses() {
        #expect(clean("I had had the the cake") == "I had had the cake.")
    }

    @Test func stutterInsidePrefixNotCollapsed() {
        #expect(clean("the theory holds up well") == "The theory holds up well.")
    }

    // MARK: Spoken punctuation

    @Test func periodAndFullStop() {
        #expect(clean("send it now period thanks") == "Send it now. Thanks.")
        #expect(clean("send it now full stop") == "Send it now.")
    }

    @Test func commaQuestionExclamation() {
        #expect(clean("well comma is it done question mark") == "Well, is it done?")
        #expect(clean("we shipped exclamation mark") == "We shipped!")
        #expect(clean("we shipped exclamation point") == "We shipped!")
    }

    @Test func newLineAndParagraph() {
        #expect(clean("first item new line second item") == "First item\nSecond item.")
        #expect(clean("intro new paragraph body text here") == "Intro\n\nBody text here.")
    }

    @Test func quotes() {
        #expect(clean("he said open quote never close quote and left") == "He said \"never\" and left.")
    }

    @Test func colonSemicolonDash() {
        #expect(clean("two things colon speed semicolon cost") == "Two things: speed; cost.")
        #expect(clean("wait dash no dash go") == "Wait \u{2014} no \u{2014} go.")
    }

    @Test func spokenWordSwallowsAsrPunctuation() {
        // Parakeet sometimes punctuates the spoken word itself.
        #expect(clean("that's all period.") == "That's all.")
    }

    @Test func capitalisedSpokenTokenStillConverts() {
        #expect(clean("Done. Period. Next thing") == "Done. Next thing")
    }

    @Test func literalPunctuationAfterDeterminerKept() {
        #expect(clean("over the period of a year") == "Over the period of a year.")
        #expect(clean("put a comma after the name") == "Put a comma after the name.")
        #expect(clean("add a dash of salt") == "Add a dash of salt.")
        #expect(clean("her period is late") == "Her period is late.")
    }

    @Test func followedByDigitNotConverted() {
        #expect(clean("the trial period 30 days") == "The trial period 30 days.")
        #expect(clean("period 30 days") == "Period 30 days")
    }

    /// Documented failure: no determiner before "colon" and a word after
    /// it, so the literal reading loses. Pinned so a change here is deliberate.
    @Test func knownFailureNounWithoutArticleConverts() {
        #expect(clean("she has colon cancer") == "She has: cancer")
    }

    // MARK: Capitalisation

    @Test func sentenceStartsCapitalised() {
        #expect(clean("hello. how are you? fine! ok") == "Hello. How are you? Fine! Ok.")
    }

    @Test func pronounI() {
        #expect(clean("i think i'm right and i've said so and i'll go")
                == "I think I'm right and I've said so and I'll go.")
    }

    @Test func lowercaseIInsideWordsUntouched() {
        #expect(clean("it is in italics") == "It is in italics.")
    }

    @Test func existingCasingPreserved() {
        #expect(clean("email the NASA team about iPhone builds") == "Email the NASA team about iPhone builds.")
    }

    @Test func capitaliseAfterNewLine() {
        #expect(clean("one new line two new line three") == "One\nTwo\nThree")
    }

    @Test func knownFailureAbbreviationCapitalisesNextWord() {
        #expect(clean("use e.g. something like this") == "Use e.g. Something like this.")
    }

    // MARK: Terminal punctuation

    @Test func shortPhraseGetsNoPeriod() {
        #expect(clean("quarterly revenue report") == "Quarterly revenue report")
        #expect(clean("kubernetes") == "Kubernetes")
    }

    @Test func longUtteranceGetsPeriod() {
        #expect(clean("please send me the quarterly report") == "Please send me the quarterly report.")
    }

    @Test func existingTerminalPunctuationKept() {
        #expect(clean("is the report ready yet?") == "Is the report ready yet?")
    }

    @Test func terminalPunctuationFlagOff() {
        #expect(clean("please send me the quarterly report") { $0.terminalPunctuation = false }
                == "Please send me the quarterly report")
    }

    @Test func numbersLeftAlone() {
        #expect(clean("it costs $1,250.50 or 3.5 percent") == "It costs $1,250.50 or 3.5 percent.")
    }

    // MARK: Rule flags and vocabulary

    @Test func allRulesOffIsJustWhitespaceNormalisation() {
        var r = TranscriptCleaner.Rules()
        r.removeFillers = false; r.spokenPunctuation = false; r.collapseStutters = false
        r.capitalise = false; r.terminalPunctuation = false; r.trailingSpace = false
        #expect(TranscriptCleaner.clean("um the the cat period", rules: r) == "um the the cat period")
    }

    @Test func vocabularyAppliedBeforeRules() {
        let v = Vocabulary(lines: ["cooper netties => Kubernetes"])
        var r = TranscriptCleaner.Rules(); r.trailingSpace = false
        #expect(TranscriptCleaner.clean("um deploy it to cooper netties period", rules: r, vocabulary: v)
                == "Deploy it to Kubernetes.")
    }

    // MARK: Adversarial input (review pass)

    @Test func curlyApostropheContractions() {
        #expect(clean("i’m sure i’ll go and i’ve seen it") == "I’m sure I’ll go and I’ve seen it.")
        #expect(clean("uh don’t worry") == "Don’t worry")
    }

    @Test func abbreviationIEIsNotThePronoun() {
        // Mid-sentence "i.e." stays lowercase; at a sentence start it is
        // capitalised like any other word, which is correct.
        #expect(clean("see e.g. this and i.e. that") == "See e.g. This and i.e. That.")
        #expect(clean("so i. done") == "So I. Done")
    }

    @Test func compoundNounBeforeSpokenTokenKept() {
        #expect(clean("my trial period ends tomorrow") == "My trial period ends tomorrow.")
        #expect(clean("during the grace period we wait") == "During the grace period we wait.")
        #expect(clean("always use an oxford comma here") == "Always use an oxford comma here.")
    }

    @Test func leadingNewLineKept() {
        // "new line" as the first thing dictated means "break here, then
        // type", the same reasoning that keeps a trailing one.
        #expect(clean("new line hello there") == "\nHello there")
        #expect(clean("new paragraph start") == "\n\nStart")
        #expect(TranscriptCleaner.clean("new line", rules: .default) == "\n")
    }

    @Test func longStutterRunCollapsesInOnePass() {
        #expect(clean("no no no no not that") == "No not that")
        #expect(clean("the the the the the cat") == "The cat")
        #expect(clean("US US soldiers") == "US soldiers")
    }

    @Test func unicodeLettersAreWordCharacters() {
        #expect(clean("café naïve résumé are fine words") == "Café naïve résumé are fine words.")
        #expect(clean("erm Zoë um went") == "Zoë went")
    }

    @Test func timesUrlsAndDecimalsUntouched() {
        #expect(clean("meet at 3:30 pm tomorrow ok") == "Meet at 3:30 pm tomorrow ok.")
        #expect(clean("visit example.com/foo then reply") == "Visit example.com/foo then reply.")
        #expect(clean("10 10 items") == "10 10 items")
    }

    @Test func spokenTokenInsideQuotes() {
        #expect(clean("he said open quote hi period close quote and left") == "He said \"hi.\" and left.")
    }

    @Test func longInputIsLinear() {
        // Was quadratic (8.8 s for this input) before the stutter and
        // spoken-punctuation stages stopped rescanning the whole prefix.
        let big = Array(repeating: "the the cat period", count: 3000).joined(separator: " ")
        let t0 = Date()
        let out = clean(big)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(out.hasPrefix("The cat. The cat. "))
        #expect(elapsed < 2.0, "took \(elapsed)s")
    }

    // MARK: Judgement calls, pinned as they behave today

    /// A lone spoken comma/colon produces nothing (the tidy stage strips a
    /// leading one), while a lone "period" produces ".". Arguably both
    /// should emit the mark; left as is because a bare "comma" utterance is
    /// almost always a mis-trigger.
    @Test func judgementLoneSpokenTokens() {
        #expect(clean("period") == ".")
        #expect(clean("comma") == "")
        #expect(clean("colon") == "")
    }

    /// Capitalisation fires after an ellipsis. "wait... what" is a real
    /// dictation shape; whether the next word is a new sentence is a coin toss.
    @Test func judgementEllipsisCapitalisesNextWord() {
        #expect(clean("wait... what") == "Wait... What")
    }

    /// "er" is a filler even when the speaker is talking about the word.
    @Test func judgementFillerAsNoun() {
        #expect(clean("the word er is a filler") == "The word is a filler.")
    }

    /// Spoken addresses *are* converted, but only on the anchor "dot" +
    /// a real top-level domain. This used to assert the opposite — the
    /// refusal was pinned as a judgement call, and it was the thing people
    /// actually hit: a dictated email address came out as prose.
    /// `SpokenAddressTests` holds the prose that must still survive.
    /// No full stop: writing the address collapses five words into one, and
    /// the terminal-punctuation rule only fires above three words. A short
    /// utterance staying a bare phrase is the existing judgement, not a new
    /// one — an address just reaches it sooner.
    @Test func judgementSpokenEmailConverted() {
        #expect(clean("email john at example dot com please") == "Email john@example.com please")
    }

    /// The other half of the same judgement: "at" and "dot" with no domain
    /// behind them are ordinary words, and stay ordinary words.
    @Test func judgementProseAtAndDotUntouched() {
        #expect(clean("meet me at the dot on the map") == "Meet me at the dot on the map.")
    }

    @Test func publicEntryPointSignature() {
        // Compile-time check that the app-facing overload exists; not called,
        // because `.shared` would read the developer's own vocabulary file.
        let f: (String) -> String = TranscriptCleaner.clean
        _ = f
    }
}
