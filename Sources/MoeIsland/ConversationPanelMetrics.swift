import CoreGraphics
import Foundation

/// How tall the conversation panel has to be, counted from what it holds.
///
/// **The bug this replaces** (the owner's screenshot, 2026-09-14). A reminder
/// that wrapped to two lines, with the "Right ⌥ can't start me yet" row under
/// it, on the hover panel — and the ask field hanging off the bottom edge of
/// the panel, half of it drawn over the page below. `NotchIsland` summed a
/// flat 103 pt for the reminder card (one line of sentence), nothing at all
/// for the Accessibility row or the call offer, and then capped the hover
/// panel at 210. Everything above the transcript is a fixed height, so the
/// transcript was squeezed to nothing first — a clipped half-line under the
/// card, which is the "it overlaps the text" — and then the field was pushed
/// out.
///
/// So every row that cannot scroll is counted here, from its real wrapped
/// text, and the cap is never allowed below what those rows and one line of
/// conversation need. This module knows nothing about fonts: the caller hands
/// in `wraps`, which the app answers with AppKit's own text measurement.
public enum ConversationPanel {

    /// "How many lines does this string take at this width, at this size?"
    public typealias Wraps = (_ text: String, _ width: Double, _ size: Double) -> Int

    public struct Offer: Equatable, Sendable {
        public var text: String
        /// One action sits at the end of the sentence; more go on a row of
        /// their own.
        public var actions: Int
        /// The inline action's width, when there is exactly one.
        public var inlineActionWidth: Double

        public init(text: String, actions: Int, inlineActionWidth: Double = 36) {
            self.text = text
            self.actions = actions
            self.inlineActionWidth = inlineActionWidth
        }
    }

    public struct Contents: Equatable, Sendable {
        public var turns: Int
        public var partial: Bool
        public var statusLine: Bool
        /// The reminder card's sentence.
        public var nudge: String?
        /// The call offer and the talk-key row, top to bottom.
        public var offers: [Offer]
        /// The ✕ and ⌃ sit in the band beside the notch rather than over
        /// the content, so nothing needs to be dropped below them.
        public var chromeInBand: Bool
        /// Moe is working: the panel is `WorkingRow`, one line under the
        /// banners, with no transcript and no field.
        public var working: Bool
        /// Answers among the shown turns that carry a "what it did" line
        /// under them (`WorkingRow.summary`); each is one more line.
        public var folds: Int

        public init(turns: Int = 0, partial: Bool = false, statusLine: Bool = false,
                    nudge: String? = nil, offers: [Offer] = [], chromeInBand: Bool = false,
                    working: Bool = false, folds: Int = 0) {
            self.turns = turns
            self.partial = partial
            self.statusLine = statusLine
            self.nudge = nudge
            self.offers = offers
            self.chromeInBand = chromeInBand
            self.working = working
            self.folds = folds
        }
    }

    /// Every number here is read off `IslandView.expandedBody`, `nudgeBar`
    /// and `offerBar`, one line of the view each.
    public enum Metric {
        // The panel.
        public static let sidePadding = 16.0        // .padding(.horizontal, 16)
        public static let stackGap = 8.0            // VStack(spacing: 8)
        /// Clears the ✕ and ⌃ when they float over the content.
        public static let chromeDrop = 18.0
        /// The band beside the notch has to be this tall to hold the 21 pt
        /// chrome with a little air.
        public static let chromeBandMinimum = 25.0
        /// ✕ and ⌃ side by side: two 21 pt buttons and the 6 pt between.
        public static let chromeWidth = 48.0
        /// Their inset from the panel's edge, and the least clearance they
        /// keep from the cutout.
        public static let chromeInset = 8.0

        // The reminder card.
        public static let cardPadding = 10.0        // .padding(.vertical, 10)
        public static let cardSide = 12.0           // .padding(.horizontal, 12)
        public static let cardGap = 8.0             // VStack(spacing: 8)
        public static let caption = 13.0            // 10 pt semibold, one line
        public static let sentenceSize = 12.5
        public static let sentenceLine = 15.0       // 12.5 pt
        public static let sentenceLeading = 2.0     // .lineSpacing(2)
        public static let sentenceLimit = 3         // .lineLimit(3)
        public static let cardActions = 21.0        // IslandPill: 10.5 pt + 4 either side

        // The offer rows: the talk key, the call offer.
        public static let offerPadding = 7.0        // .padding(.vertical, 7)
        public static let offerSide = 10.0          // .padding(.horizontal, 10)
        public static let offerSize = 11.0
        public static let offerLine = 14.0          // 11 pt
        public static let offerLimit = 4            // .lineLimit(4)
        public static let offerIcon = 13.0          // a 10 pt symbol
        public static let offerGap = 8.0            // HStack(spacing: 8)
        public static let offerActionsGap = 6.0     // VStack(spacing: 6)
        public static let offerAction = 20.0        // 10 pt + 4 either side

        /// The least conversation the panel keeps in view under the banners:
        /// the greeting's two lines, or a row and a half of ledger.
        /// Squeezing it to zero is what drew half a line clipped under the
        /// card.
        public static let minimumTranscript = 64.0
        /// One ledger row, the least a conversation is ever shown at.
        public static let ledgerRow = 42.0
        /// The "what it did" line under an answer: 11 pt plus its gap.
        public static let fold = 18.0

        /// What the panel really draws around the rows, as opposed to the
        /// allowance below: 14 pt of padding top and bottom, the 8 pt gaps
        /// either side of the transcript, and the ask field (a 12 pt line,
        /// 6 pt of padding either side and its border).
        public static let drawnChrome = 14.0 + 14 + 8 + 8 + 30

        // The old arithmetic for the conversation itself, unchanged: a 30 pt
        // allowance where the header was, the field, and the padding.
        public static let header = 30.0
        public static let field = 40.0
        public static let padding = 30.0
    }

    public static let expandedCap = 300.0
    public static let peekCap = 210.0
    /// `NotchIsland.maxContentHeight` — the window everything is drawn in.
    public static let maximumHeight = 420.0
    public static let minimumHeight = 118.0

    /// Characters-per-point wrap count, for tests and anywhere without AppKit.
    public static let estimate: Wraps = { text, width, size in
        let perLine = max(width / (size * 0.49), 1)
        return max(Int(ceil(Double(text.count) / perLine)), 1)
    }

    /// Whether the ✕ and ⌃ can sit in the black band beside the notch.
    ///
    /// The open panel fills that band anyway — it is what swallows the
    /// cutout — so on a notched Mac it is 32 to 38 pt of nothing above the
    /// first row. Putting the chrome there gives the rows the whole top of
    /// the panel: nothing is drawn under a button, and nothing is dropped
    /// eighteen points to avoid one. A Mac without a notch has no band, and
    /// keeps the drop.
    public static func chromeFitsInBand(panelWidth: Double, notch: CGSize) -> Bool {
        Double(notch.height) >= Metric.chromeBandMinimum
            && (panelWidth - Double(notch.width)) / 2 >= Metric.chromeWidth + Metric.chromeInset * 2
    }

    public static func nudgeCard(_ sentence: String, width: Double, wraps: Wraps) -> Double {
        let textWidth = width - Metric.sidePadding * 2 - Metric.cardSide * 2
        let lines = max(min(wraps(sentence, textWidth, Metric.sentenceSize), Metric.sentenceLimit), 1)
        return Metric.cardPadding * 2 + Metric.caption + Metric.cardGap
            + Double(lines) * Metric.sentenceLine + Double(lines - 1) * Metric.sentenceLeading
            + Metric.cardGap + Metric.cardActions
    }

    public static func offerBar(_ offer: Offer, width: Double, wraps: Wraps) -> Double {
        let inline = offer.actions == 1
        var textWidth = width - Metric.sidePadding * 2 - Metric.offerSide * 2
            - Metric.offerIcon - Metric.offerGap
        if inline { textWidth -= Metric.offerGap + offer.inlineActionWidth }
        let lines = max(min(wraps(offer.text, textWidth, Metric.offerSize), Metric.offerLimit), 1)
        let text = Double(lines) * Metric.offerLine
        let body = inline ? max(text, Metric.offerAction)
                          : text + (offer.actions > 0 ? Metric.offerActionsGap + Metric.offerAction : 0)
        return Metric.offerPadding * 2 + body
    }

    /// Everything above the transcript: the drop under the chrome, when it
    /// is needed, then each banner and the gap after it.
    public static func banners(_ c: Contents, width: Double, wraps: Wraps) -> Double {
        var rows: [Double] = []
        if let nudge = c.nudge { rows.append(nudgeCard(nudge, width: width, wraps: wraps)) }
        rows += c.offers.map { offerBar($0, width: width, wraps: wraps) }
        guard !rows.isEmpty else { return 0 }
        return (c.chromeInBand ? 0 : Metric.chromeDrop)
            + rows.reduce(0, +) + Double(rows.count) * Metric.stackGap
    }

    public static func height(_ c: Contents, width: Double, peek: Bool,
                              wraps: Wraps = estimate) -> Double {
        // The working row: its own height and padding, plus whatever cannot
        // scroll above it. No floor and no cap — there is nothing in it to
        // squeeze, and a job with a reminder held over it is still short.
        if c.working {
            return WorkingRow.padding + WorkingRow.height + banners(c, width: width, wraps: wraps)
        }
        let shown = min(c.turns, 6)
        let transcript = shown == 0
            ? (c.statusLine ? 64 : 46)
            : Double(shown) * 42 + Double(min(c.folds, shown)) * Metric.fold + (c.partial ? 20 : 0)
        let above = banners(c, width: width, wraps: wraps)
        let chrome = Metric.header + Metric.field + Metric.padding
        let natural = chrome + above + transcript
        // The floor under the cap: what the panel draws that cannot scroll,
        // and enough of the conversation to read. Measured against what is
        // drawn rather than the allowance, so the floor stays inside the
        // window even with every banner up at once — then only the
        // conversation is squeezed, never the field.
        let needed = unsqueezable(c, width: width, wraps: wraps)
            + min(transcript, Metric.minimumTranscript)
        let cap = min(max(peek ? peekCap : expandedCap, needed), maximumHeight)
        return min(max(natural, minimumHeight), cap)
    }

    /// Everything that is drawn at full height whatever the panel is given:
    /// the padding, the field, and the banners.
    public static func unsqueezable(_ c: Contents, width: Double, wraps: Wraps = estimate) -> Double {
        Metric.drawnChrome + banners(c, width: width, wraps: wraps)
    }
}
