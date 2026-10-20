import Testing
@testable import MoeScreen

@Suite struct PointTagParserTests {

    @Test func plainTextPassesThrough() {
        var p = PointTagParser()
        let r = p.feed("Click the blue button.")
        #expect(r.text == "Click the blue button.")
        #expect(r.tags.isEmpty)
        #expect(p.flush() == "")
    }

    @Test func oneTagIsRemovedAndReturned() {
        var p = PointTagParser()
        let r = p.feed("It's here [POINT:120,340:Save button] on the right.")
        #expect(r.text == "It's here on the right.")
        #expect(r.tags == [PointTag(x: 120, y: 340, label: "Save button")])
    }

    @Test func tagSplitAcrossDeltas() {
        var p = PointTagParser()
        var text = ""
        var tags: [PointTag] = []
        for d in ["Look ", "[", "PO", "INT:1", "2,3", "4:the ", "menu", "]", " there."] {
            let r = p.feed(d)
            text += r.text; tags += r.tags
        }
        text += p.flush()
        #expect(text == "Look there.")
        #expect(tags == [PointTag(x: 12, y: 34, label: "the menu")])
    }

    @Test func heldPrefixIsReleasedWhenItIsNotATag() {
        var p = PointTagParser()
        let a = p.feed("see [PO")
        #expect(a.text == "see ")          // "[PO" held: could still be a tag
        let b = p.feed("LICE] now")
        #expect(b.text == "[POLICE] now")
        #expect(b.tags.isEmpty)
    }

    @Test func nestedBracketsInsideLabel() {
        var p = PointTagParser()
        let r = p.feed("[POINT:5,6:the [Save] button] done")
        #expect(r.text == "done")
        #expect(r.tags == [PointTag(x: 5, y: 6, label: "the [Save] button")])
    }

    @Test func multipleTags() {
        var p = PointTagParser()
        let r = p.feed("First [POINT:1,2:a] then [POINT:3,4:b].")
        #expect(r.text == "First then .")
        #expect(r.tags == [PointTag(x: 1, y: 2, label: "a"), PointTag(x: 3, y: 4, label: "b")])
    }

    @Test func malformedTagsStayAsText() {
        #expect(PointTagParser.strip("[POINT:abc]") == "[POINT:abc]")
        #expect(PointTagParser.strip("[POINT:1]") == "[POINT:1]")
        #expect(PointTagParser.strip("[POINT:1,2:x:nonsense]") == "[POINT:1,2:x:nonsense]")
        #expect(PointTagParser.strip("[point:1,2:x]") == "[point:1,2:x]")
        #expect(PointTagParser.strip("a [ b ] c") == "a [ b ] c")
        #expect(PointTagParser.strip("[POINT:1,2:x") == "[POINT:1,2:x")   // unterminated: flushed
    }

    @Test func labelOptionalAndScreenField() {
        #expect(PointTagParser.tags(in: "[POINT:9,8]") == [PointTag(x: 9, y: 8, label: "")])
        #expect(PointTagParser.tags(in: "[POINT: 9 , 8 : hi :screen2]")
                == [PointTag(x: 9, y: 8, label: "hi", screen: 2)])
        #expect(PointTagParser.tags(in: "[POINT:10.6,2.2:x]") == [PointTag(x: 11, y: 2, label: "x")])
    }

    @Test func unterminatedTagIsReleasedPastTheHoldLimit() {
        var p = PointTagParser()
        let long = "[POINT:1,2:" + String(repeating: "x", count: 400)
        let r = p.feed(long)
        #expect(r.text == long)
        #expect(p.flush() == "")
    }

    @Test func stripMatchesStreaming() {
        let s = "Go [POINT:1,2:a] here [POINT:3,4:b]"
        var p = PointTagParser()
        var text = ""
        for ch in s { text += p.feed(String(ch)).text }
        text += p.flush()
        #expect(text == PointTagParser.strip(s))
        #expect(text == "Go here ")
    }
}

/// The parser must give the same text and tags however the stream is cut.
@Suite struct PointTagParserFuzzTests {

    static let replies = [
        "Click [POINT:120,340:Save button] then [POINT:5,6:the [Save] button] done.",
        "See [1] and [POINTS] and [POLICE] and [POINT:9,8] and [POINT: 3 , 4 : hi :screen2].",
        "[POINT:1,2:a]Leading tag, then [POINT:abc] not a tag, [POINT:1] neither, [ b ] c",
        "Trailing space [POINT:1,2:x] ",
        "Two adjacent [POINT:1,2:a][POINT:3,4:b] tags and a newline\n[POINT:5,6:c]\nafter.",
        "Unfinished at the end [POINT:1,2:the save butt",
        "Bracket soup [[[POINT:1,2:x]]] and ]] stray [ opens",
        "Unicode café [POINT:10.6,2.2:naïve → label] ok",
    ]

    static func oneShot(_ s: String) -> (String, [PointTag]) {
        var p = PointTagParser()
        let r = p.feed(s)
        return (r.text + p.flush(), r.tags)
    }

    static func streamed(_ s: String, cuts: [Int]) -> (String, [PointTag]) {
        var p = PointTagParser()
        var text = ""
        var tags: [PointTag] = []
        let chars = Array(s)
        var start = 0
        for c in cuts + [chars.count] {
            let r = p.feed(String(chars[start..<c]))
            text += r.text; tags += r.tags
            start = c
        }
        text += p.flush()
        return (text, tags)
    }

    @Test func everySingleSplitMatchesOneShot() {
        for s in Self.replies {
            let (text, tags) = Self.oneShot(s)
            let n = s.count
            for i in 0...n {
                let (t, g) = Self.streamed(s, cuts: [i])
                #expect(t == text, "split at \(i) of \(s.debugDescription)")
                #expect(g == tags, "split at \(i) of \(s.debugDescription)")
            }
        }
    }

    @Test func everyDoubleSplitMatchesOneShot() {
        for s in Self.replies {
            let (text, tags) = Self.oneShot(s)
            let n = s.count
            for i in 0...n {
                for j in i...n {
                    let (t, g) = Self.streamed(s, cuts: [i, j])
                    #expect(t == text, "split at \(i),\(j) of \(s.debugDescription)")
                    #expect(g == tags, "split at \(i),\(j) of \(s.debugDescription)")
                }
            }
        }
    }

    @Test func characterByCharacterMatchesOneShot() {
        for s in Self.replies {
            let (text, tags) = Self.oneShot(s)
            let (t, g) = Self.streamed(s, cuts: Array(0...s.count))
            #expect(t == text, Comment(rawValue: s.debugDescription))
            #expect(g == tags, Comment(rawValue: s.debugDescription))
        }
    }

    /// Nothing that came out of the parser as text contains a tag, and
    /// every tag the reply contained came out as a tag.
    @Test func noTagFragmentReachesTheText() {
        let s = Self.replies[0] + " " + Self.replies[4]
        let (text, tags) = Self.oneShot(s)
        #expect(!text.contains("POINT:"))
        #expect(tags.count == 5)
        #expect(text == "Click then done. Two adjacent tags and a newline\nafter.")
    }

    @Test func legitimateBracketsSurvive() {
        #expect(PointTagParser.strip("[1] [POINTS] [POLICE] [POINT:1] [POINT]") == "[1] [POINTS] [POLICE] [POINT:1] [POINT]")
        #expect(PointTagParser.strip("[POINT:1,2]") == "")
        #expect(PointTagParser.tags(in: "[POINT:1,2:a[b]c]") == [PointTag(x: 1, y: 2, label: "a[b]c")])
        #expect(PointTagParser.strip("[POINT:1,2:a[b]c]") == "")
    }
}
