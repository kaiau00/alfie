import Testing
@testable import MoeDictation

/// The rule is "find the shape, then convert inside it". Half of these tests
/// are addresses that must convert; the other half is ordinary prose with
/// "at" and "dot" in it, which must come through untouched. The second half
/// is the one that matters — it is why the conversion was refused for so
/// long, and the only reason it is safe to do now.
struct SpokenAddressTests {

    // MARK: - Addresses that convert

    @Test func plainDomain() {
        #expect(SpokenAddress.rewrite("go to example dot com") == "go to example.com")
    }

    @Test func emailWithAt() {
        #expect(SpokenAddress.rewrite("email john at example dot com") == "email john@example.com")
    }

    @Test func theOwnersOwnAddress() {
        #expect(SpokenAddress.rewrite("send it to jane3 at example dot ai")
                == "send it to jane3@example.ai")
    }

    @Test func spelledOutTld() {
        #expect(SpokenAddress.rewrite("it is example dot a i") == "it is example.ai")
    }

    @Test func spelledOutCom() {
        #expect(SpokenAddress.rewrite("example dot c o m") == "example.com")
    }

    @Test func countryPair() {
        #expect(SpokenAddress.rewrite("the site is example dot co dot uk")
                == "the site is example.co.uk")
    }

    @Test func dashInsideHost() {
        #expect(SpokenAddress.rewrite("try moe dash bot dot app") == "try moe-bot.app")
    }

    @Test func underscoreInLocalPart() {
        #expect(SpokenAddress.rewrite("mail jo underscore blogs at example dot org")
                == "mail jo_blogs@example.org")
    }

    @Test func addressKeepsTheSentenceAroundIt() {
        #expect(SpokenAddress.rewrite("write to sales at acme dot com about the invoice")
                == "write to sales@acme.com about the invoice")
    }

    @Test func trailingPunctuationSurvives() {
        #expect(SpokenAddress.rewrite("it is at acme dot com.") == "it is at acme.com.")
    }

    // MARK: - Prose that must not convert

    @Test func prosePrepositionAt() {
        #expect(SpokenAddress.rewrite("meet me at the coffee shop")
                == "meet me at the coffee shop")
    }

    @Test func proseDotNotFollowedByATld() {
        #expect(SpokenAddress.rewrite("it is a dot matrix printer")
                == "it is a dot matrix printer")
    }

    @Test func proseNumberDot() {
        #expect(SpokenAddress.rewrite("I will be there at four dot five")
                == "I will be there at four dot five")
    }

    @Test func proseWithNoDotAtAll() {
        #expect(SpokenAddress.rewrite("look at the chart and tell me what you see")
                == "look at the chart and tell me what you see")
    }

    @Test func proseAboutDots() {
        #expect(SpokenAddress.rewrite("connect the dot to the line")
                == "connect the dot to the line")
    }

    /// "at" is a country TLD (Austria), which is exactly the kind of word
    /// that would wreck prose if the anchor were "any TLD anywhere". The
    /// anchor is "dot" *followed by* a TLD, so this is untouched.
    @Test func proseEndingInAt() {
        #expect(SpokenAddress.rewrite("that is what I was looking at")
                == "that is what I was looking at")
    }

    @Test func emptyString() {
        #expect(SpokenAddress.rewrite("") == "")
    }

    // MARK: - The cheap guard

    @Test func noAnchorMeansNoWork() {
        #expect(SpokenAddress.hasAnchor("meet me at the coffee shop") == false)
        #expect(SpokenAddress.hasAnchor("go to example dot com") == true)
        #expect(SpokenAddress.hasAnchor("a dot matrix printer") == false)
    }
}
