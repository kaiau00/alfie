import Testing
@testable import MoeBrain

struct ReplyLengthTests {

    @Test func balancedAddsNothingSoNobodysMoeChangesUntilTheyChooseTo() {
        #expect(ReplyLength.balanced.turnLine(readable: false) == nil)
        #expect(ReplyLength.balanced.turnLine(readable: true) == nil)
    }

    @Test func shortAndDetailedSayWhichTheyAreAndThatTheyWin() throws {
        for length in [ReplyLength.short, .detailed] {
            for readable in [false, true] {
                let line = try #require(length.turnLine(readable: readable))
                #expect(line.contains(length.rawValue))
                // AGENTS.md on existing Macs still says "Two spoken sentences
                // is the default"; the setting has to say it overrides that.
                #expect(line.contains("replaces any other length rule"))
                #expect(line.hasPrefix("(") && line.hasSuffix(")"))
            }
        }
    }

    @Test func spokenIsTighterThanWrittenAtEverySetting() throws {
        for length in [ReplyLength.short, .detailed] {
            let spoken = try #require(length.turnLine(readable: false))
            let written = try #require(length.turnLine(readable: true))
            #expect(spoken != written)
        }
        #expect(ReplyLength.short.turnLine(readable: false)!.contains("one sentence"))
        #expect(ReplyLength.detailed.turnLine(readable: false)!.contains("short paragraph"))
        #expect(ReplyLength.detailed.turnLine(readable: true)!.contains("headings"))
    }

    @Test func anUnknownValueIsBalanced() {
        #expect(ReplyLength(configValue: "") == .balanced)
        #expect(ReplyLength(configValue: "verbose") == .balanced)
        #expect(ReplyLength(configValue: " Detailed ") == .detailed)
        #expect(ReplyLength(configValue: "SHORT") == .short)
    }
}
