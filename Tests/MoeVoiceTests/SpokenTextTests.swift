import Testing
@testable import MoeVoice

/// What the synthesiser is handed.
///
/// These rules used to live in `Speaker.strippedForSpeech`, inside the
/// executable target, where no test could reach them — while being the single
/// funnel every spoken word in the app passes through (`VoiceEngine.speak`).
/// Half of the cases below are gaps that were sitting in it.
struct SpokenTextTests {

    // MARK: - Links

    /// The point of the whole split. The reply keeps a real, clickable link;
    /// the speaker hears the label and never the address.
    @Test func aMarkdownLinkIsSpokenAsItsLabel() {
        #expect(SpokenText.clean("Try [the pricing page](https://example.com/pricing).")
                == "Try the pricing page.")
    }

    /// A bare address has no label to say, so it becomes a noun. Deleting it
    /// outright would leave "you can find it at", which is worse than either.
    @Test func aBareAddressBecomesAWord() {
        #expect(SpokenText.clean("You can find it at https://example.com/x.")
                == "You can find it at the link.")
    }

    /// `www.` with no scheme is the other half of how people write addresses,
    /// and the old stripper matched only `https?://` — so this was read out
    /// as "w w w dot example dot com".
    @Test func aSchemelessAddressIsCaughtToo() {
        #expect(SpokenText.clean("It's at www.example.com now.")
                == "It's at the link now.")
    }

    /// So was this one.
    @Test func anAngleAutolinkIsCaughtToo() {
        #expect(SpokenText.clean("See <https://example.com> for more.")
                == "See the link for more.")
    }

    /// The address becomes a word, so the colon it introduced still has
    /// something to introduce and stays as it was.
    @Test func aColonBeforeAnAddressStillIntroducesSomething() {
        #expect(SpokenText.clean("Here it is: https://example.com") == "Here it is: the link")
    }

    /// A colon left at the very end introduces nothing — mid-stream that is a
    /// line about to be followed by a list — and "here is what I found colon"
    /// is not a sentence anybody says.
    @Test func aDanglingColonBecomesAFullStop() {
        #expect(SpokenText.clean("Here is what I found:") == "Here is what I found.")
    }

    /// Ordering: the address inside a perfectly good markdown link must not
    /// be found by the bare-address rule and announced on its own.
    @Test func aLabelledLinkNeverAlsoSaysTheWord() {
        let said = SpokenText.clean("Read [the docs](https://example.com/docs) first.")
        #expect(said == "Read the docs first.")
        #expect(!said.contains("the link"))
    }

    // MARK: - Lists and structure

    /// The `(?m)` bug this replaces: without multiline anchoring only the
    /// first bullet of a list was stripped and the rest came out as "dash
    /// two, dash three".
    @Test func everyBulletIsStrippedNotJustTheFirst() {
        let said = SpokenText.clean("- one\n- two\n- three")
        #expect(!said.contains("-"))
        #expect(said.contains("one"))
        #expect(said.contains("two"))
        #expect(said.contains("three"))
    }

    /// A numbered list was never handled at all: "1." reads as a sentence
    /// that has already ended, so the synthesiser paused in the wrong places.
    @Test func numberedListsAreStrippedToo() {
        let said = SpokenText.clean("1. First thing\n2. Second thing")
        #expect(!said.contains("1."))
        #expect(!said.contains("2."))
        #expect(said.contains("First thing"))
        #expect(said.contains("Second thing"))
    }

    /// A list item is a sentence to the ear, so it gets the full stop that
    /// makes the synthesiser pause between items instead of running them on.
    @Test func aListItemGetsItsPause() {
        #expect(SpokenText.clean("- milk\n- eggs") == "milk. eggs.")
    }

    /// And one that already ends in punctuation is left alone.
    @Test func aListItemThatIsAlreadyASentenceIsNotDoubled() {
        #expect(SpokenText.clean("- Buy milk.") == "Buy milk.")
    }

    @Test func headingsAndQuotesLoseTheirMarkers() {
        #expect(SpokenText.clean("## What I found") == "What I found")
        #expect(SpokenText.clean("> they said no") == "they said no")
    }

    /// A rule is punctuation for the eye and nothing at all for the ear.
    @Test func aHorizontalRuleIsSilent() {
        #expect(SpokenText.clean("Done.\n---\nNext.") == "Done. Next.")
    }

    /// A table read aloud cell by cell with its pipes is unusable; read as a
    /// list of values it is merely long. Asserted as the exact string: a
    /// check that only says "no pipes survived" passes just as happily on
    /// output where every row has run into the next one.
    @Test func aTableLosesItsPipesAndItsRuler() {
        #expect(SpokenText.clean("| Name | Age |\n|---|---|\n| Ada | 36 |")
                == "Name, Age Ada, 36")
    }

    /// A pipe in ordinary prose is not a table and must be left where it is.
    /// Rewriting every line that merely *contains* one turned "Revenue |
    /// Marketing split the budget" into a sentence that says a different
    /// thing, and stopped a shell command being the command.
    @Test func aPipeInProseIsNotATable() {
        #expect(SpokenText.clean("Revenue | Marketing split the budget.")
                == "Revenue | Marketing split the budget.")
        #expect(SpokenText.clean("I ran grep foo | wc -l for you.")
                == "I ran grep foo | wc -l for you.")
    }

    // MARK: - Code

    /// Two minutes of punctuation read aloud, avoided — but named, not
    /// vanished. See below for why the three words matter.
    @Test func aFencedBlockIsNamedNotRead() {
        #expect(SpokenText.clean("Here:\n```\nlet x = 1\n```\nThat's it.")
                == "Here: Code block. That's it.")
    }

    /// Mid-stream an unclosed fence is a block still being written, and it is
    /// about to be exactly as unspeakable as a closed one.
    @Test func anUnclosedFenceIsDroppedToTheEnd() {
        #expect(SpokenText.clean("Try this:\n```\nlet x = 1") == "Try this: Code block.")
    }

    /// A chunk that is nothing *but* a code block must still say something.
    ///
    /// Two failures ride on an empty return here, and neither is obvious.
    /// `VoiceEngine.speak` drops an empty string in a guard that sits *before*
    /// it records `replyEnd` — so a spoken question whose whole answer is a
    /// code block left Moe silent with no explanation, and left the
    /// heard-offset behind the reply, which made a barge-in afterwards resume
    /// by repeating prose the person had already heard.
    @Test func aCodeOnlyChunkStillSaysSomething() {
        #expect(!SpokenText.clean("```\nlet x = 1\n```").isEmpty)
        #expect(SpokenText.clean("```\nlet x = 1\n```") == "Code block.")
    }

    /// Said once for the block, not once for each fence.
    @Test func aFencedBlockIsNamedOnlyOnce() {
        let said = SpokenText.clean("```\nlet x = 1\n```")
        #expect(said.components(separatedBy: "Code block").count - 1 == 1)
    }

    @Test func aCodeSpanKeepsItsWords() {
        #expect(SpokenText.clean("Run `git status` first.") == "Run git status first.")
    }

    // MARK: - Emphasis

    @Test func emphasisMarkersAreNotSpoken() {
        #expect(SpokenText.clean("It is **very** late.") == "It is very late.")
        #expect(SpokenText.clean("It is *very* late.") == "It is very late.")
        #expect(SpokenText.clean("It is __very__ late.") == "It is very late.")
        #expect(SpokenText.clean("It is _very_ late.") == "It is very late.")
        #expect(SpokenText.clean("It is ~~not~~ late.") == "It is not late.")
    }

    /// An underscore inside a name is part of the name. Stripping it turns
    /// `speak_replies` into `speakreplies`, which is a different word — and
    /// worse than reading the underscore, which is what this used to do.
    @Test func anIdentifierKeepsItsUnderscores() {
        #expect(SpokenText.clean("The flag is speak_typed_replies today.")
                == "The flag is speak_typed_replies today.")
    }

    // MARK: - Fragments

    /// Every rule here has to be right on a piece of a document, because that
    /// is what it is always given: `speakReadySentences` hands over one
    /// sentence at a time out of a stream.
    @Test func aSentenceFragmentSurvivesIntact() {
        #expect(SpokenText.clean("Two-thirty, with Sarah, ") == "Two-thirty, with Sarah.")
        #expect(SpokenText.clean("It's 3.5 degrees") == "It's 3.5 degrees")
    }

    @Test func emptyInputIsEmptyOutput() {
        #expect(SpokenText.clean("") == "")
        #expect(SpokenText.clean("   ") == "")
    }

    /// A chunk that was nothing but an address has nothing to say. The caller
    /// (`VoiceEngine.speak`) drops an empty string, so this must not become
    /// a lone "the link" with no sentence around it… it may, and that is the
    /// honest outcome — but it must never become the address itself.
    @Test func anAddressAloneNeverBecomesTheAddress() {
        let said = SpokenText.clean("https://example.com/a/b/c")
        #expect(!said.contains("http"))
        #expect(!said.contains("example.com"))
    }

    /// Plain prose passes through untouched. Worth pinning: this runs on
    /// every sentence Moe speaks, and the ordinary case is the one that must
    /// not be quietly mangled by a rule written for the unusual one.
    @Test func ordinaryProseIsUnchanged() {
        let plain = "Your two-thirty with Sarah moved to four, and she asked for the deck."
        #expect(SpokenText.clean(plain) == plain)
    }

    // MARK: - Real replies

    /// Verbatim from the live model on 2026-09-04, asked "what are the
    /// official Swift and SwiftUI documentation pages? Give me the links."
    ///
    /// This is the shape the prompt change produces and the shape the whole
    /// feature turns on: before it, the same question was answered by
    /// spelling addresses into prose, because the prompt forbade URLs
    /// outright. Kept as a fixture rather than a hand-written string so the
    /// case being defended is one that actually happened.
    @Test func aRealSpokenReplySaysTheLabelsAndNoAddresses() {
        let reply = """
        Apple's main ones are [the Swift language docs on swift.org]\
        (https://www.swift.org/documentation/) and [The Swift Programming \
        Language book](https://docs.swift.org/swift-book/), with the API side \
        at [Apple's Swift developer page]\
        (https://developer.apple.com/documentation/swift).
        """
        let said = SpokenText.clean(reply)
        // Not one character of an address survives to the synthesiser.
        #expect(!said.contains("http"))
        #expect(!said.contains("swift.org/documentation"))
        #expect(!said.contains("developer.apple.com"))
        #expect(!said.contains("]"))
        #expect(!said.contains("("))
        // And every label does, because that is what a person would say.
        #expect(said.contains("the Swift language docs on swift.org"))
        #expect(said.contains("The Swift Programming Language book"))
        #expect(said.contains("Apple's Swift developer page"))
    }

    /// The other half, also verbatim: the typed answer to the same question,
    /// which is a document. It is never spoken — but nothing stops somebody
    /// turning "speak my typed replies" on, and then it is, so it still has
    /// to come out as sentences rather than as punctuation.
    @Test func aRealTypedReplyIsStillSpeakable() {
        let reply = """
        **Swift (the language) — swift.org**
        - [Swift documentation hub](https://www.swift.org/documentation/) — the index
        - [The Swift Programming Language](https://docs.swift.org/swift-book/) — the official book

        Rough division of labour: swift.org owns the language.
        """
        let said = SpokenText.clean(reply)
        #expect(!said.contains("http"))
        #expect(!said.contains("*"))
        #expect(!said.contains("["))
        #expect(said.contains("Swift documentation hub"))
        #expect(said.contains("Rough division of labour"))
        // Each list item ends as a sentence, so the synthesiser pauses
        // between them instead of running the whole list into one breath.
        #expect(said.contains("the index."))
    }

    // MARK: - Emoji and symbols

    /// Inworld's text-preparation guide says no emoji, and only the voice
    /// prompt forbade them: a typed reply or a narration carried them to the
    /// speaker, which says "party popper" or pauses oddly.
    @Test func emojiAreNotSpoken() {
        #expect(SpokenText.clean("Done! 🎉") == "Done!")
        #expect(SpokenText.clean("✅ Deployed to production.") == "Deployed to production.")
        #expect(SpokenText.clean("Nice work 👍🏽, it shipped.") == "Nice work, it shipped.")
        #expect(SpokenText.clean("Dinner with 👨‍👩‍👧 at 7.") == "Dinner with at 7.")
        #expect(SpokenText.clean("Flights to 🇯🇵 are cheaper in May.") == "Flights to are cheaper in May.")
        #expect(SpokenText.clean("That's a ⭐ idea ❤️") == "That's a idea")
        #expect(SpokenText.clean("👍") == "")
    }

    /// A list item that ends on an emoji still ends as a sentence.
    @Test func aListItemEndingOnAnEmojiStillEndsAsASentence() {
        #expect(SpokenText.clean("- Ship it 🚀\n- Then rest") == "Ship it. Then rest.")
    }

    /// A keycap is its digit; an arrow or a mid-line bullet is the pause it
    /// stands for, not a word and not nothing.
    @Test func keycapsArrowsAndBulletsBecomeWhatTheyMean() {
        #expect(SpokenText.clean("Press 1️⃣ to confirm.") == "Press 1 to confirm.")
        #expect(SpokenText.clean("Open Settings → Voice.") == "Open Settings, Voice.")
        #expect(SpokenText.clean("Milk • eggs • bread.") == "Milk, eggs, bread.")
        #expect(SpokenText.clean("• First thing") == "First thing.")
    }

    /// What Unicode also calls emoji, or sits near them, and is speech:
    /// digits, `#` and `*` (keycap bases), currency, degrees, marks, and any
    /// script's letters.
    @Test func textThatLooksLikeEmojiToUnicodeIsKept() {
        let kept = ["We're #1 in 3 of 4 markets.", "It's 72° and €40.", "Acme™ and © 2026.",
                    "Café, naïve, 東京, Привет.", "Profit ≥ 5%."]
        for text in kept { #expect(SpokenText.clean(text) == text) }
    }
}
