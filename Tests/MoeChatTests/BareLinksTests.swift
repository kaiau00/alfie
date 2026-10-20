import Testing
@testable import MoeChat

/// Making the addresses in a reply clickable.
///
/// Every case here is one where getting it wrong corrupts the reply rather
/// than merely failing to help: a link that swallows a full stop goes to a
/// 404, and brackets inserted into a shell command change what the command
/// says.
struct BareLinksTests {

    // MARK: - The ordinary case

    /// The shape a model writes far more often than markdown: a bare address
    /// in a sentence. Before this it rendered as flat grey text you had to
    /// select and copy by hand.
    @Test func aBareAddressBecomesALink() {
        #expect(BareLinks.autolink("See https://example.com/docs for more.")
                == "See [https://example.com/docs](https://example.com/docs) for more.")
    }

    /// The label is the address itself. Inventing a friendlier one would be
    /// inventing, and the address is what a person checks before they click.
    @Test func theLabelIsTheAddress() {
        let out = BareLinks.autolink("https://example.com")
        #expect(out == "[https://example.com](https://example.com)")
    }

    /// `www.` with no scheme is a link to a person and must be one to the
    /// renderer, which will not follow a href it cannot resolve.
    @Test func aSchemelessAddressGetsAScheme() {
        #expect(BareLinks.autolink("Try www.example.com today.")
                == "Try [www.example.com](https://www.example.com) today.")
    }

    // MARK: - What it must not touch

    /// Already a link. Wrapping its href again produces literal brackets on
    /// screen, which is worse than the problem being solved.
    @Test func anExistingMarkdownLinkIsLeftAlone() {
        let text = "Read [the docs](https://example.com/docs) first."
        #expect(BareLinks.autolink(text) == text)
    }

    @Test func anImageIsLeftAlone() {
        let text = "![a chart](https://example.com/chart.png)"
        #expect(BareLinks.autolink(text) == text)
    }

    /// A command is text about a command. Brackets inside it change it.
    @Test func aCodeSpanIsLeftAlone() {
        let text = "Run `curl https://api.example.com/v1` to check."
        #expect(BareLinks.autolink(text) == text)
    }

    @Test func aFencedBlockIsLeftAlone() {
        let text = "```\ncurl https://api.example.com\n```"
        #expect(BareLinks.autolink(text) == text)
    }

    /// A stream cut mid-block is the normal case, not an error, and the rest
    /// of it is still code.
    @Test func anUnclosedFenceIsLeftAloneToTheEnd() {
        let text = "Here:\n```\ncurl https://api.example.com"
        #expect(BareLinks.autolink(text) == text)
    }

    /// Text with nothing address-shaped in it comes back byte-identical —
    /// which is what most replies are, so it is also the fast path.
    @Test func proseWithNoAddressIsUntouched() {
        let text = "Your two-thirty moved to four."
        #expect(BareLinks.autolink(text) == text)
    }

    // MARK: - Where the address ends

    /// The full stop belongs to the sentence. A link that takes it 404s.
    @Test func aSentenceFullStopStaysOutside() {
        #expect(BareLinks.autolink("Go to https://example.com/a.")
                == "Go to [https://example.com/a](https://example.com/a).")
    }

    @Test func otherSentencePunctuationStaysOutsideToo() {
        for mark in [",", ";", ":", "!", "?"] {
            let out = BareLinks.autolink("Go to https://example.com/a\(mark) yes")
            #expect(out.hasPrefix("Go to [https://example.com/a](https://example.com/a)\(mark)"),
                    "\(mark) was swallowed: \(out)")
        }
    }

    /// The bracket closes the aside, not the address.
    @Test func anUnbalancedClosingBracketStaysOutside() {
        #expect(BareLinks.trimTail("https://example.com/a)") == "https://example.com/a")
    }

    /// And a balanced one is part of it — Wikipedia addresses really do end
    /// this way, and trimming it gives a different page.
    @Test func aBalancedBracketIsPartOfTheAddress() {
        #expect(BareLinks.trimTail("https://en.wikipedia.org/wiki/Mercury_(planet)")
                == "https://en.wikipedia.org/wiki/Mercury_(planet)")
    }

    // MARK: - More than one

    @Test func severalAddressesInOneSentenceAllBecomeLinks() {
        let out = BareLinks.autolink("Either https://a.example.com or https://b.example.com works.")
        #expect(out.contains("[https://a.example.com](https://a.example.com)"))
        #expect(out.contains("[https://b.example.com](https://b.example.com)"))
        #expect(out.hasSuffix(" works."))
    }

    /// A bare address in prose beside a labelled one in the same reply: the
    /// first is rewritten, the second is not, and neither disturbs the other.
    @Test func aBareAndALabelledAddressCoexist() {
        let out = BareLinks.autolink("[docs](https://a.example.com) and https://b.example.com")
        #expect(out == "[docs](https://a.example.com) and [https://b.example.com](https://b.example.com)")
    }

    /// Running it on its own output must not wrap the links again. Nothing in
    /// the app does this today, and a renderer that gets called twice on a
    /// redraw is exactly the sort of thing that starts to.
    @Test func runningItTwiceChangesNothingTheSecondTime() {
        let once = BareLinks.autolink("See https://example.com/docs for more.")
        #expect(BareLinks.autolink(once) == once)
    }

    // MARK: - Where the address ends, harder cases

    /// A model writing a bold address is entirely ordinary, and the asterisks
    /// close around it rather than belonging to it. Left in, the href ends in
    /// `**` — a 404 — under a label that shows them.
    @Test func emphasisClosingAroundAnAddressStaysOutside() {
        #expect(BareLinks.trimTail("https://example.com**") == "https://example.com")
        #expect(BareLinks.trimTail("https://example.com*") == "https://example.com")
        #expect(BareLinks.trimTail("https://example.com~~") == "https://example.com")
        let out = BareLinks.autolink("**https://example.com**")
        #expect(out == "**[https://example.com](https://example.com)**")
    }

    /// The possessive belongs to the sentence. Stripping only a trailing
    /// apostrophe left the "s" inside the address, which is a broken link
    /// that looks perfectly fine on screen.
    @Test func aPossessiveStaysOutside() {
        #expect(BareLinks.trimTail("https://example.com's") == "https://example.com")
        #expect(BareLinks.trimTail("https://example.com\u{2019}s") == "https://example.com")
    }

    /// The shortest address worth linking, named in the guard's own comment —
    /// which the guard used to exclude by one character.
    @Test func theShortestAddressTheCommentNamesIsLinked() {
        #expect(BareLinks.autolink("go to www.a.co now")
                == "go to [www.a.co](https://www.a.co) now")
    }

    // MARK: - Streaming

    /// The commonest case of all, and the one that had no test: a markdown
    /// link whose address is still arriving. Every link Moe writes passes
    /// through this state and both views re-render on every delta, so
    /// autolinking the half-written href put a bracketed address inside the
    /// link for as long as it streamed.
    @Test func aHalfWrittenMarkdownLinkIsLeftAlone() {
        let text = "See [the docs](https://exa"
        #expect(BareLinks.autolink(text) == text)
    }

    /// And it becomes a link the moment it closes, with nothing left over.
    @Test func theSameLinkIsLeftAloneOnceItCloses() {
        let text = "See [the docs](https://example.com/docs) now"
        #expect(BareLinks.autolink(text) == text)
    }

    /// A half-written link must not shield a finished bare address earlier in
    /// the same reply — the unclosed run is only the tail.
    @Test func aBareAddressBeforeAHalfWrittenLinkIsStillLinked() {
        let out = BareLinks.autolink("First https://a.example.com then [docs](https://exa")
        #expect(out.hasPrefix("First [https://a.example.com](https://a.example.com) then "))
        #expect(out.hasSuffix("[docs](https://exa"))
    }
}
