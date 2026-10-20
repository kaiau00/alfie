import Foundation
import Testing
@testable import MoeChat

/// The links behind an answer: read off what Moe actually opened, shown
/// rather than described, and never read aloud.
struct ReplyLinksTests {

    @Test func findsPagesInAToolPreview() {
        let links = ReplyLinks.found(in: "Reading https://www.anthropic.com/news/claude")
        #expect(links.count == 1)
        #expect(links[0].url == "https://www.anthropic.com/news/claude")
        #expect(links[0].label == "anthropic.com/news")
    }

    @Test func trailingPunctuationIsNotPartOfTheAddress() {
        let links = ReplyLinks.found(in: "Fetched https://example.com/a/b, then stopped.")
        #expect(links[0].url == "https://example.com/a/b")
    }

    @Test func repeatsAreShownOnce() {
        let links = ReplyLinks.found(in: "https://a.com/x https://a.com/x https://b.com/y")
        #expect(links.map(\.url) == ["https://a.com/x", "https://b.com/y"])
    }

    @Test func nothingToFindIsNoLinks() {
        #expect(ReplyLinks.found(in: "searching the web").isEmpty)
        #expect(ReplyLinks.found(in: "grep -rn http Sources").isEmpty)   // no scheme
    }

    @Test func labelFallsBackToTheHost() {
        #expect(ReplyLinks.label(for: "https://example.com") == "example.com")
        #expect(ReplyLinks.label(for: "https://example.com/") == "example.com")
    }

    /// The block is dropped from speech and the answer above it is not.
    @Test func speechDropsATrailingSourcesBlock() {
        let reply = """
        Rates are up a quarter point.

        Sources:
        - [Reuters](https://reuters.com/markets/rates)
        - https://federalreserve.gov/news
        """
        #expect(ReplyLinks.strippingSources(reply) == "Rates are up a quarter point.")
    }

    /// A heading with prose under it is part of the answer, not a block of
    /// links: dropping it would silently swallow what was said.
    @Test func prosePastTheHeadingIsKept() {
        let reply = "Sources:\nI could not find any."
        #expect(ReplyLinks.strippingSources(reply) == reply)
    }

    @Test func aReplyWithNoBlockIsUnchanged() {
        #expect(ReplyLinks.strippingSources("Two-thirty, with Sarah.") == "Two-thirty, with Sarah.")
    }
}
