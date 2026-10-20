import Foundation
import Testing
@testable import MoeVoice

struct SentenceSplitterTests {

    @Test func popsOneCompleteSentenceAndKeepsTheRest() {
        var buf = "It is three. And it is raining"
        #expect(SentenceSplitter.popSentence(&buf) == "It is three. ")
        #expect(buf == "And it is raining")
        #expect(SentenceSplitter.popSentence(&buf) == nil)
    }

    @Test func waitsToSeePastTheTerminator() {
        var buf = "It's 3."
        #expect(SentenceSplitter.popSentence(&buf) == nil)
        buf = "It's 3.5 degrees out. Cold"
        #expect(SentenceSplitter.popSentence(&buf) == "It's 3.5 degrees out. ")
    }

    @Test func firstThingMayBreakAtAClauseOnceLongEnough() {
        var buf = "Read it, it's the rollout call with the platform team, and it's at ten"
        let first = SentenceSplitter.popSentence(&buf, orClause: true)
        #expect(first == "Read it, it's the rollout call with the platform team, ")
    }

    @Test func shortOpenerWaitsForMore() {
        var buf = "Read it. It's the"
        #expect(SentenceSplitter.popSentence(&buf, orClause: true) == nil)
    }

    @Test func thousandsSeparatorIsNotAClause() {
        var buf = "The total for the year comes to 1,200 dollars, give or take"
        let s = SentenceSplitter.popSentence(&buf, orClause: true)
        #expect(s == "The total for the year comes to 1,200 dollars, ")
    }

    @Test func chunkSplitsLongTextAtSentences() {
        let text = String(repeating: "This is a sentence of some length. ", count: 10)
        let parts = SentenceSplitter.chunk(text, limit: 100)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.count <= 101 })
        #expect(parts.joined(separator: " ").count >= text.count - parts.count * 2)
    }

    @Test func chunkFallsBackToCommasThenHardCuts() {
        let text = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let parts = SentenceSplitter.chunk(text, limit: 50)
        #expect(parts.allSatisfy { $0.count <= 50 })
        #expect(!parts.isEmpty)
    }

    @Test func hardCutsKeepEveryCharacter() {
        let text = String(repeating: "abcdefghij", count: 30)   // 300 chars, no spaces
        let parts = SentenceSplitter.chunk(text, limit: 100)
        #expect(parts.joined() == text)
    }

    @Test func questionsStayQuestionsAndEllipsesStayWhole() {
        #expect(SentenceSplitter.sentences(of: "Is it ready? Wait... more") == ["Is it ready?", "Wait...", "more"])
        let text = "Is it ready? Wait... " + String(repeating: "more words here ", count: 15)
        let parts = SentenceSplitter.chunk(text, limit: 60)
        #expect(parts.first == "Is it ready? Wait...")
        #expect(!parts.contains("."))
    }

    @Test func decimalsDoNotSplit() {
        #expect(SentenceSplitter.sentences(of: "It is 3.5 degrees. Cold.") == ["It is 3.5 degrees.", "Cold."])
    }

    @Test func shortTextIsOneChunk() {
        #expect(SentenceSplitter.chunk("Hi there.") == ["Hi there."])
    }
}
