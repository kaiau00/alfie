import CoreGraphics
import Testing
@testable import MoeIsland

/// The ask field hung off the bottom of the hover panel.
///
/// The owner's screenshot, 2026-09-14: a reminder that wrapped to two lines,
/// the "Right ⌥ can't start me yet" row under it, and the field half outside
/// the panel. The height allowed one line of reminder, nothing for the row,
/// and capped the hover panel at 210 pt.
struct ConversationPanelMetricsTests {

    static let reminder = "The deck you promised Sam was due today. Want me to check whether it went out, or help you finish and send it?"
    static let talkKey = "Right ⌥ can't start me yet. If Memoe is already switched on in Accessibility, macOS is holding on to an older copy — Fix clears it, then switch Memoe on again."

    /// What was on the screen: two lines of reminder at the hover width, and
    /// the talk-key row at three.
    static let screenshotWraps: ConversationPanel.Wraps = { text, _, _ in
        text == reminder ? 2 : 3
    }

    static let screenshot = ConversationPanel.Contents(
        nudge: reminder,
        offers: [.init(text: talkKey, actions: 1)],
        chromeInBand: true)

    /// Everything the panel draws that cannot scroll, plus the greeting or a
    /// row of conversation — the least that has to be inside the panel.
    static func needed(_ c: ConversationPanel.Contents, width: Double,
                       wraps: @escaping ConversationPanel.Wraps) -> Double {
        let transcript = c.turns == 0 ? (c.statusLine ? 64.0 : 46) : ConversationPanel.Metric.ledgerRow
        return ConversationPanel.unsqueezable(c, width: width, wraps: wraps) + transcript
    }

    // MARK: - The bug

    @Test func theScreenshotsHoverPanelHoldsTheField() {
        let h = ConversationPanel.height(Self.screenshot, width: 420, peek: true,
                                         wraps: Self.screenshotWraps)
        #expect(h >= Self.needed(Self.screenshot, width: 420, wraps: Self.screenshotWraps))
        #expect(h <= ConversationPanel.maximumHeight)
    }

    /// The old arithmetic, kept as its number: a flat 103 for the card, zero
    /// for the row, capped at 210. It is shorter than the rows alone.
    @Test func theOldArithmeticWasShorterThanTheRowsItHadToHold() {
        let old = min(min(max(30.0 + 46 + 40 + 30 + 103, 118), 300), 210)
        #expect(old < Self.needed(Self.screenshot, width: 420, wraps: Self.screenshotWraps))
    }

    /// Opened, with a conversation under the card: the transcript keeps at
    /// least one row instead of a clipped half-line.
    @Test func theConversationUnderTheCardKeepsARow() {
        var c = Self.screenshot
        c.turns = 2
        let h = ConversationPanel.height(c, width: 460, peek: false, wraps: Self.screenshotWraps)
        let floor = ConversationPanel.unsqueezable(c, width: 460, wraps: Self.screenshotWraps)
        #expect(h - floor >= ConversationPanel.Metric.ledgerRow)
    }

    // MARK: - Every banner, counted

    @Test func aReminderThatWrapsIsTallerByALine() {
        let one = ConversationPanel.nudgeCard("short", width: 460, wraps: { _, _, _ in 1 })
        let two = ConversationPanel.nudgeCard("short", width: 460, wraps: { _, _, _ in 2 })
        let four = ConversationPanel.nudgeCard("short", width: 460, wraps: { _, _, _ in 4 })
        let m = ConversationPanel.Metric.self
        #expect(two - one == m.sentenceLine + m.sentenceLeading)
        // `.lineLimit(3)`: a fourth line is not drawn, so it is not counted.
        #expect(four == ConversationPanel.nudgeCard("short", width: 460, wraps: { _, _, _ in 3 }))
    }

    @Test func theTalkKeyRowIsCounted() {
        let without = ConversationPanel.banners(.init(nudge: Self.reminder, chromeInBand: true),
                                                width: 460, wraps: Self.screenshotWraps)
        let with = ConversationPanel.banners(Self.screenshot, width: 460, wraps: Self.screenshotWraps)
        let row = ConversationPanel.offerBar(.init(text: Self.talkKey, actions: 1),
                                             width: 460, wraps: Self.screenshotWraps)
        #expect(with - without == row + ConversationPanel.Metric.stackGap)
    }

    /// One action rides at the end of the sentence; three get their own row.
    @Test func oneActionIsInlineAndThreeAreARow() {
        let wraps: ConversationPanel.Wraps = { _, _, _ in 2 }
        let inline = ConversationPanel.offerBar(.init(text: "x", actions: 1), width: 460, wraps: wraps)
        let row = ConversationPanel.offerBar(.init(text: "x", actions: 3), width: 460, wraps: wraps)
        let m = ConversationPanel.Metric.self
        #expect(inline == m.offerPadding * 2 + 2 * m.offerLine)
        #expect(row == inline + m.offerActionsGap + m.offerAction)
    }

    /// The inline action takes width from the sentence, so the sentence is
    /// measured narrower than the row.
    @Test func theInlineActionNarrowsTheSentence() {
        var widths: [Double] = []
        let wraps: ConversationPanel.Wraps = { _, w, _ in widths.append(w); return 1 }
        _ = ConversationPanel.offerBar(.init(text: "x", actions: 1, inlineActionWidth: 36), width: 420, wraps: wraps)
        _ = ConversationPanel.offerBar(.init(text: "x", actions: 3), width: 420, wraps: wraps)
        #expect(widths[0] == widths[1] - 8 - 36)
    }

    @Test func theDropUnderTheChromeIsPaidOnceWhenItIsNeeded() {
        var c = Self.screenshot
        c.nudge = Self.reminder
        let inBand = ConversationPanel.banners(c, width: 460, wraps: Self.screenshotWraps)
        c.chromeInBand = false
        let dropped = ConversationPanel.banners(c, width: 460, wraps: Self.screenshotWraps)
        #expect(dropped - inBand == ConversationPanel.Metric.chromeDrop)
        #expect(ConversationPanel.banners(.init(), width: 460, wraps: Self.screenshotWraps) == 0)
    }

    /// Every row at its line limit at once — the call offer, the reminder and
    /// the talk-key row, on a Mac with no band for the chrome — and the
    /// field is still inside the window. Here, and only here, the
    /// conversation is what gives way.
    @Test func theWorstCaseStillKeepsTheFieldInTheWindow() {
        let c = ConversationPanel.Contents(
            turns: 8, partial: true, nudge: "x",
            offers: [.init(text: "call", actions: 3), .init(text: "key", actions: 1)],
            chromeInBand: false)
        let wraps: ConversationPanel.Wraps = { _, _, _ in 99 }
        for peek in [true, false] {
            let width = peek ? 420.0 : 460.0
            let h = ConversationPanel.height(c, width: width, peek: peek, wraps: wraps)
            let floor = ConversationPanel.unsqueezable(c, width: width, wraps: wraps)
            #expect(floor <= ConversationPanel.maximumHeight)
            #expect(h >= floor)
            #expect(h <= ConversationPanel.maximumHeight)
        }
    }

    // MARK: - Nothing else moved

    /// With no banners, the panel is the height it always was.
    @Test func withoutBannersTheHeightIsUnchanged() {
        for turns in 0...8 {
            for partial in [false, true] {
                for status in [false, true] {
                    let shown = min(turns, 6)
                    let body = shown == 0 ? (status ? 64.0 : 46) : Double(shown) * 42 + (partial ? 20 : 0)
                    let old = min(max(30 + body + 40 + 30, 118), 300)
                    let c = ConversationPanel.Contents(turns: turns, partial: partial, statusLine: status)
                    #expect(ConversationPanel.height(c, width: 460, peek: false) == old)
                    #expect(ConversationPanel.height(c, width: 420, peek: true) == min(old, 210))
                }
            }
        }
    }

    // MARK: - The chrome in the band

    @Test func theChromeMovesIntoTheBandOnlyWhereThereIsOne() {
        #expect(ConversationPanel.chromeFitsInBand(panelWidth: 420, notch: CGSize(width: 179, height: 32)))
        #expect(ConversationPanel.chromeFitsInBand(panelWidth: 420, notch: CGSize(width: 220, height: 38)))
        // No notch: no band.
        #expect(!ConversationPanel.chromeFitsInBand(panelWidth: 420, notch: .zero))
        // A band too short for a 21 pt button.
        #expect(!ConversationPanel.chromeFitsInBand(panelWidth: 460, notch: CGSize(width: 100, height: 20)))
        // A cutout so wide there is no room beside it.
        #expect(!ConversationPanel.chromeFitsInBand(panelWidth: 420, notch: CGSize(width: 340, height: 32)))
    }

    /// While Moe works the panel is one row (WorkingRow, 2026-09-19): the
    /// height is the row and its padding, plus any banner, and nothing else
    /// — not the transcript's floor, not the field, not the peek cap.
    @Test func theWorkingRowIsOneLineTall() {
        let plain = ConversationPanel.Contents(turns: 4, statusLine: true, working: true)
        #expect(ConversationPanel.height(plain, width: 420, peek: true) == 52)
        #expect(ConversationPanel.height(plain, width: 420, peek: false) == 52)
        // Turns and a partial change nothing: they are not drawn.
        let more = ConversationPanel.Contents(turns: 12, partial: true, statusLine: true, working: true)
        #expect(ConversationPanel.height(more, width: 420, peek: true) == 52)
        // A reminder held over the job still sits above the row.
        let withCard = ConversationPanel.Contents(nudge: "Eli’s waiting for your help.", working: true)
        let card = ConversationPanel.banners(withCard, width: 420, wraps: ConversationPanel.estimate)
        #expect(card > 0)
        #expect(ConversationPanel.height(withCard, width: 420, peek: true) == 52 + card)
        // And the same contents without `working` is the ordinary panel,
        // which is a great deal taller.
        var conversation = plain; conversation.working = false
        #expect(ConversationPanel.height(conversation, width: 420, peek: true) >= ConversationPanel.minimumHeight)
    }

    /// An answer that ran steps carries a "what it did" line under it, and
    /// the panel is taller by that line so the field is not pushed off.
    @Test func aFoldedAnswerIsOneLineTaller() {
        let plain = ConversationPanel.Contents(turns: 2)
        let folded = ConversationPanel.Contents(turns: 2, folds: 1)
        #expect(ConversationPanel.height(folded, width: 420, peek: false)
                == ConversationPanel.height(plain, width: 420, peek: false) + ConversationPanel.Metric.fold)
        // Never more folds than rows on show.
        let over = ConversationPanel.Contents(turns: 2, folds: 5)
        #expect(ConversationPanel.height(over, width: 420, peek: false)
                == ConversationPanel.height(plain, width: 420, peek: false) + 2 * ConversationPanel.Metric.fold)
    }
}
