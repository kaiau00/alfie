import Testing
import MoeChat
@testable import MoeIsland

/// The owner, 2026-09-25: a drafted email showed as a column of ">" in Chat
/// and on the island. A quote is its own block now, markers removed, drawn
/// as a card on both surfaces.
struct ReplyBlocksTests {

    @Test func aQuotedDraftIsOneBlockWithoutItsMarkers() {
        let blocks = ReplyBlocks.parse("Here it is:\n\n> Hi,\n>\n> I built Memoe.\n\nSend it?")
        #expect(blocks == [.prose("Here it is:"), .quote("Hi,\n\nI built Memoe."), .prose("Send it?")])
    }

    @Test func headingsLoseTheirHashesButHashtagsStay() {
        #expect(ReplyBlocks.parse("## Plan\nstep one") == [.heading("Plan"), .prose("step one")])
        #expect(ReplyBlocks.parse("#launch day") == [.prose("#launch day")])
    }

    @Test func codeFencesStillWork() {
        #expect(ReplyBlocks.parse("run:\n```\nls -la\n```\ndone")
                == [.prose("run:"), .code("ls -la"), .prose("done")])
    }

    @Test func anUnclosedQuoteOrFenceKeepsItsText() {
        #expect(ReplyBlocks.parse("> half a draft") == [.quote("half a draft")])
        #expect(ReplyBlocks.parse("```\nls") == [.code("ls")])
    }

    @Test func plainTextIsOneBlock() {
        #expect(ReplyBlocks.parse("Nopa, 7:00.") == [.prose("Nopa, 7:00.")])
    }

    /// The island measures a quote as the card it draws: taller than the
    /// same words as plain text.
    @Test func theIslandMeasuresAQuoteAsACard() {
        let plain = IslandChat.height(.moe(id: "1", text: "Hi, I built Memoe."))
        let quoted = IslandChat.height(.moe(id: "1", text: "> Hi, I built Memoe."))
        #expect(quoted == plain + IslandChat.boxPad * 2)
    }
}
