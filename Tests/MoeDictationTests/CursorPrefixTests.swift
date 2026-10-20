import Testing
@testable import MoeDictation

@Suite("CursorPrefix")
struct CursorPrefixTests {

    @Test("nothing to send stays nothing")
    func emptyIsNil() {
        #expect(CursorPrefix.tidy(nil) == nil)
        #expect(CursorPrefix.tidy("") == nil)
        #expect(CursorPrefix.tidy("   ") == nil)
        #expect(CursorPrefix.tidy("\n\n\n") == nil)
    }

    /// The whole reason the prefix is worth sending: it is how the model
    /// knows whether the dictation needs a leading space and a capital.
    @Test("trailing whitespace survives, because it carries the answer")
    func trailingSpaceKept() {
        #expect(CursorPrefix.tidy("See you on ") == "See you on ")
        #expect(CursorPrefix.tidy("half a wor") == "half a wor")
    }

    @Test("a part-word left by the character limit is dropped")
    func partialLeadingWordDropped() {
        // "…ietly" is the tail of a word the limit cut through; what follows
        // is enough to be worth sending on its own.
        let cut = "ietly confirmed the release date with the whole team"
        #expect(CursorPrefix.tidy(cut) == "confirmed the release date with the whole team")
    }

    /// Dropping the head of a short prefix would leave nothing useful, so a
    /// single long token is sent whole rather than thrown away.
    @Test("a short prefix keeps its first word")
    func shortPrefixKeepsHead() {
        #expect(CursorPrefix.tidy("ietly confirmed") == "ietly confirmed")
        #expect(CursorPrefix.tidy("Kubernetes") == "Kubernetes")
    }

    @Test("runs of blank lines collapse to one")
    func blankLinesCollapse() {
        #expect(CursorPrefix.tidy("first thought\n\n\n\n\nsecond thought")
                == "first thought\n\nsecond thought")
    }

    @Test("leading newlines go, so the prefix starts at text")
    func leadingNewlinesStripped() {
        #expect(CursorPrefix.tidy("\n\nHi there,") == "Hi there,")
    }

    /// A prefix that begins mid-sentence but on a word boundary is already
    /// right and must not be trimmed further.
    @Test("a prefix starting on a space is left alone")
    func leadingSpaceIsAWordBoundary() {
        #expect(CursorPrefix.tidy(" and then we shipped it on the Friday")
                == " and then we shipped it on the Friday")
    }
}
