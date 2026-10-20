import Testing
@testable import MoeBrain

private typealias Line = ContextReplay.Line
private func them(_ t: String) -> Line { .init(who: .them, text: t) }
private func us(_ t: String) -> Line { .init(who: .us, text: t) }

/// The bug this pins is the one that lost the owner's request on
/// 2026-09-04: the window was taken before the filter, so turns with nothing
/// in them spent slots, and the thing he actually asked for fell out of the
/// back of an eight-turn window filled with the wreckage of interruptions.
struct ContextReplayTests {

    /// The incident, rebuilt. Six empties between the request and the restart
    /// — an interruption leaves one behind every time — and the request is
    /// eight turns back. Taking the window first left "Yeah" and "…".
    @Test func theRequestSurvivesAWindowFullOfInterruptions() {
        let request = "Can you find the Apple Developer email, look on my screen, "
                    + "insert the recipient, write a subject, and write the email"
        var lines = [them(request), us("Checking your mail for that thread.")]
        for _ in 0..<6 { lines.append(contentsOf: [them(""), us("…")]) }
        lines.append(them("Yeah"))

        let script = ContextReplay.script(lines)
        #expect(script.contains("Apple Developer"), "the request must reach the restarted brain")
        #expect(script.contains("look on my screen"))
        #expect(!script.contains("…"))
    }

    /// What the old code produced, stated so the regression is legible.
    @Test func theOldOrderWouldHaveLostIt() {
        var lines = [them("find the Apple Developer email and write the reply")]
        for _ in 0..<6 { lines.append(contentsOf: [them(""), us("…")]) }
        lines.append(them("Yeah"))
        let old = lines.suffix(8).filter { !$0.text.isEmpty }
        #expect(!old.contains(where: { $0.text.contains("Apple Developer") }))
        // …and the fix keeps it.
        #expect(ContextReplay.recent(lines).contains(where: { $0.text.contains("Apple Developer") }))
    }

    // MARK: - What counts as saying something

    @Test func theUnheardReplyPlaceholderIsNotContent() {
        #expect(!ContextReplay.worthReplaying(us("…")))
        #expect(!ContextReplay.worthReplaying(us("")))
        #expect(!ContextReplay.worthReplaying(us("   ")))
        #expect(!ContextReplay.worthReplaying(us("— ,")))
    }

    @Test func realWordsCount() {
        #expect(ContextReplay.worthReplaying(them("Yeah")))
        #expect(ContextReplay.worthReplaying(us("The file's at /tmp/x.png")))
        #expect(ContextReplay.worthReplaying(them("3")))
    }

    /// A reply that was cut off mid-sentence still happened and still matters:
    /// only the placeholder for one nothing was heard of is dropped.
    @Test func aPartlyHeardReplyIsKept() {
        #expect(ContextReplay.worthReplaying(us("Checking your mail for that thread …")))
    }

    // MARK: - The window itself

    @Test func eightMeansEightRealOnes() {
        let lines = (1...20).map { them("turn \($0)") }
        let got = ContextReplay.recent(lines)
        #expect(got.count == 8)
        #expect(got.first?.text == "turn 13")
        #expect(got.last?.text == "turn 20")
    }

    @Test func orderIsOldestFirst() {
        let script = ContextReplay.script([them("first"), us("second"), them("third")])
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines == ["They said: first", "You replied: second", "They said: third"])
    }

    @Test func nothingWorthSayingGivesNothing() {
        #expect(ContextReplay.script([them(""), us("…")]).isEmpty)
    }
}
