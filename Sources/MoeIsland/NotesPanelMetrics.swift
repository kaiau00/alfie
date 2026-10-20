import Foundation

/// How tall the "notes ready" panel has to be, measured from what it holds.
///
/// It lives here, in a library target with no AppKit in it, for the reason
/// `IslandBehaviour` does: an executable target cannot be imported by a test,
/// and this is arithmetic that has already been wrong once in a way no test
/// could see.
///
/// **The bug this replaces.** `NotchIsland.notesHeight` allowed a flat 96 pt
/// for everything that is not the summary. The panel's own chrome — a header
/// row, a title that wraps to two lines in the display serif, the delivery
/// footnote with its rule, and the "Open notes" pill — comes to about 160 pt
/// before a single word of the body is drawn, and the body's section labels
/// and the gaps between its blocks were not counted at all. The body sits in
/// a `ScrollView` with its indicators off, resting at the top, so everything
/// past the short height was simply not on screen: in `10-notes-ready.png`
/// that was the last decision, the ACTION ITEMS heading and both action
/// items — the tickable reminders, which are the most useful thing in a set
/// of meeting notes.
///
/// So this counts every block the view draws, and where the result still does
/// not fit it reports `overflows`, which is what makes the panel say so
/// rather than end in silence.
public enum NotesPanel {

    /// The shape of what the panel is being asked to draw. Strings, not
    /// views: this module knows nothing about SwiftUI and must not.
    public struct Notes: Equatable, Sendable {
        public var title: String
        public var summary: String
        public var decisions: [String]
        /// Each already rendered to the one line the view draws —
        /// "Dan: check the volume break — by Wednesday".
        public var actionItems: [String]
        /// The "the audio was kept" footnote, when there is one.
        public var audioNote: String?
        /// "Sent to your notes folder…".
        public var delivery: String
        /// The "Open notes" pill at the foot.
        public var hasOpenButton: Bool

        public init(title: String = "", summary: String = "",
                    decisions: [String] = [], actionItems: [String] = [],
                    audioNote: String? = nil, delivery: String = "",
                    hasOpenButton: Bool = false) {
            self.title = title
            self.summary = summary
            self.decisions = decisions
            self.actionItems = actionItems
            self.audioNote = audioNote
            self.delivery = delivery
            self.hasOpenButton = hasOpenButton
        }
    }

    /// What the panel should be, and whether it had to give up on fitting.
    public struct Layout: Equatable, Sendable {
        /// The whole drawn panel, ready for `contentSize`.
        public let height: Double
        /// The height the scrolling body is given inside it.
        public let bodyHeight: Double
        /// The height that body's content wants.
        public let contentHeight: Double
        /// True when the body cannot show everything it holds. The view must
        /// then draw a cue — content that is off the bottom of a scroll view
        /// with no indicator, no fade and no words is content that has been
        /// lost, whatever the scroll view thinks.
        public let overflows: Bool
    }

    // MARK: - The view's own numbers

    /// Every constant below is read off `IslandView.meetingDoneBody`. They are
    /// deliberately dumb — a font size times a line factor, a padding, a
    /// `VStack` spacing — because the only way this stays true is if each one
    /// can be checked against a single line of the view.
    public enum Metric {
        // Chrome, outside the scrolling body.
        public static let padTop = 13.0             // .padding(.top, 13)
        public static let padBottom = 11.0          // .padding(.bottom, 11)
        public static let blockGap = 9.0            // VStack(spacing: 9)
        public static let headerRow = 21.0          // IslandButton is 21×21, the tallest thing in it
        public static let headerGap = 3.0           // VStack(spacing: 3)
        public static let titleLine = 22.0          // 17 pt serif + 1 pt lineSpacing
        public static let titleWidth = 330.0        // .frame(maxWidth: 330)
        public static let rule = 0.5                // Rectangle().frame(height: 0.5)
        public static let footLine = 13.0           // 10 pt
        public static let footLineLimit = 3
        public static let pill = 21.0               // 9/10.5 pt glyphs + 4 pt padding either side
        public static let hint = 11.0               // the overflow cue, an 8 pt small-caps row

        // The scrolling body.
        public static let bodyGap = 10.0            // VStack(spacing: 10)
        public static let summaryLine = 16.0        // 13 pt serif
        public static let summaryLeading = 2.5      // .lineSpacing(2.5)
        public static let summaryWidth = 330.0      // .frame(maxWidth: 330)
        public static let label = 11.0              // 8 pt bold rounded section label
        public static let bulletLine = 14.0         // 11 pt
        public static let bulletGap = 3.0           // VStack(spacing: 3)
        public static let bulletWidth = 376.0       // 428 − 28 padding − the bullet gutter
        public static let actionLine = 14.0         // 11 pt
        public static let actionRow = 16.0          // the checkbox is 13 pt and sets the floor
        public static let actionGap = 2.0           // VStack(spacing: 2)
        public static let actionWidth = 357.0       // …less the checkbox and its gap

        /// Points per character, by font size, for the panel's two families.
        /// A measure, not a metric: it is only ever used to count how many
        /// times a string wraps, and one line either way costs 13 pt.
        public static let serifCharacter = 0.55     // × the font size
        public static let sansCharacter = 0.49

        /// A few points of nothing at the foot of the body.
        ///
        /// Every line height above is a font size times a factor, and each is
        /// a fraction of a point out; over a summary, two sections and their
        /// rows that came to 4 pt, which is exactly enough to shave the
        /// descenders off the last action item. The error only ever goes one
        /// way at a time and a point of black costs nothing, so the panel
        /// rounds up rather than down.
        public static let slack = 5.0
    }

    /// The smallest the panel is ever drawn, so a one-line summary does not
    /// arrive as a sliver.
    public static let minimumHeight = 120.0
    /// The largest. The notes panel appears when the call is over, so it is
    /// allowed to be a slab — but not an unbounded one, and it has to stay
    /// inside `NotchIsland.maxContentHeight`, which is the window it is drawn
    /// in. Past this the body scrolls and says that it does.
    public static let maximumHeight = 420.0

    // MARK: - The measurement

    public static func layout(_ n: Notes) -> Layout {
        let content = body(n)
        let plain = chrome(n, withHint: false)

        // First pass: does it fit with no cue at all?
        let roomWithoutHint = maximumHeight - plain
        if content.height <= roomWithoutHint {
            let h = min(max(plain + content.height, minimumHeight), maximumHeight)
            return Layout(height: h, bodyHeight: max(h - plain, 0),
                          contentHeight: content.height, overflows: false)
        }

        // Second pass: it does not, so the cue is drawn and takes its own
        // room. Then the bottom edge is moved off any heading it landed on.
        let withHint = chrome(n, withHint: true)
        let room = max(maximumHeight - withHint, 0)
        let body = safeCut(room, avoiding: content.headings)
        let h = min(max(withHint + body, minimumHeight), maximumHeight)
        return Layout(height: h, bodyHeight: max(h - withHint, 0),
                      contentHeight: content.height, overflows: true)
    }

    /// Everything the panel draws that is not the scrolling body.
    static func chrome(_ n: Notes, withHint: Bool) -> Double {
        var h = Metric.padTop + Metric.padBottom
        // Header: the NOTES READY row, then the title, which wraps.
        let titleLines = wraps(n.title.isEmpty ? "Notes ready" : n.title,
                               width: Metric.titleWidth, size: 17, serif: true)
        h += Metric.headerRow + Metric.headerGap + Double(titleLines) * Metric.titleLine
        h += Metric.blockGap                                    // header → body
        if withHint { h += Metric.blockGap + Metric.hint }      // body → cue
        for foot in [n.audioNote, n.delivery.isEmpty ? nil : n.delivery] {
            guard let foot else { continue }
            let lines = min(wraps(foot, width: 400, size: 10, serif: false),
                            Metric.footLineLimit)
            // A rule and a paragraph, each its own child of the VStack.
            h += Metric.blockGap + Metric.rule + Metric.blockGap
                 + Double(lines) * Metric.footLine
        }
        if n.hasOpenButton { h += Metric.blockGap + Metric.pill }
        return h
    }

    /// The scrolling body, block by block — and, alongside it, the stretches
    /// where the bottom edge must not land.
    ///
    /// A section label introduces the rows under it. Cut between the two and
    /// the panel ends on the word ACTION ITEMS with no action items, which
    /// says the opposite of the truth. So each label contributes a forbidden
    /// span running from the top of the label to the bottom of its first row.
    static func body(_ n: Notes) -> (height: Double, headings: [ClosedRange<Double>]) {
        var h = 0.0
        var headings: [ClosedRange<Double>] = []
        var first = true
        func gap() { if !first { h += Metric.bodyGap }; first = false }

        if !n.summary.isEmpty {
            gap()
            let lines = wraps(n.summary, width: Metric.summaryWidth, size: 13, serif: true)
            // Prose is the one block a cut may land inside: a paragraph that
            // stops mid-line under a fade reads as a paragraph that continues.
            h += Double(lines) * Metric.summaryLine
                 + Double(max(lines - 1, 0)) * Metric.summaryLeading
        }

        func section(_ rows: [String], width: Double, line: Double,
                     floor rowFloor: Double, spacing: Double) {
            guard !rows.isEmpty else { return }
            gap()
            let labelTop = h
            h += Metric.label
            h += Metric.bodyGap                                 // label → its rows
            for (i, row) in rows.enumerated() {
                if i > 0 { h += spacing }
                let lines = wraps(row, width: width, size: 11, serif: false)
                h += max(Double(lines) * line, rowFloor)
                if i == 0 { headings.append(labelTop...h) }
            }
        }

        section(n.decisions, width: Metric.bulletWidth, line: Metric.bulletLine,
                floor: Metric.bulletLine, spacing: Metric.bulletGap)
        section(n.actionItems, width: Metric.actionWidth, line: Metric.actionLine,
                floor: Metric.actionRow, spacing: Metric.actionGap)

        return (h > 0 ? h + Metric.slack : 0, headings)
    }

    /// The tallest body no greater than `room` whose bottom edge is not
    /// inside a heading's span.
    ///
    /// `room` is already the most the panel has, so the edge can only be
    /// moved *up*: the label goes below the fold along with the rows it
    /// introduces. That is the honest half of the choice — a reviewer found
    /// the panel ending on the word DECISIONS with nothing under it, and a
    /// heading that introduces nothing is a worse lie than a heading you have
    /// to scroll to.
    static func safeCut(_ room: Double, avoiding headings: [ClosedRange<Double>]) -> Double {
        guard let hit = headings.first(where: { $0.lowerBound < room && room < $0.upperBound })
        else { return room }
        return hit.lowerBound
    }

    /// How many lines a string takes at a width. Whole words are not
    /// measured — this is a wrap count, and the panel's own clamp absorbs
    /// the error.
    static func wraps(_ text: String, width: Double, size: Double, serif: Bool) -> Int {
        let perCharacter = size * (serif ? Metric.serifCharacter : Metric.sansCharacter)
        let perLine = max(width / perCharacter, 1)
        // An explicit break starts a line of its own, whatever is on it.
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = paragraphs.reduce(0) { $0 + Int(ceil(Double($1.count) / perLine)) }
        return max(lines, 1)
    }
}
