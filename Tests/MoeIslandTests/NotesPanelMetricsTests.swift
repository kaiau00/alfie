import Testing
@testable import MoeIsland

/// The meeting notes panel dropped its action items and said nothing.
///
/// `10-notes-ready.png` showed a title, a summary, DECISIONS with two of its
/// three bullets, and then a rule and "Sent to your notes folder". The ACTION
/// ITEMS heading and both tickable items were not in the panel at all: the
/// body sits in a `ScrollView` resting at the top with its indicators off, so
/// everything past the measured height was simply off the bottom, with no
/// fade, no indicator and no words.
struct NotesPanelMetricsTests {

    /// Exactly what `--panel-snapshot`'s `10-notes-ready` holds.
    private static let realNotes = NotesPanel.Notes(
        title: "Pricing review — what we are changing before the launch",
        summary: "We agreed the per-seat price holds at nineteen and the volume break moves from fifty seats to twenty-five. Dan will redo the sheet against the new break and circulate it before Friday.",
        decisions: ["Per-seat price stays at $19.",
                    "Volume break moves to 25 seats.",
                    "The launch date does not move."],
        actionItems: ["You: send the revised pricing sheet — by Friday",
                      "Dan: check the volume break against last quarter's invoices — by Wednesday"],
        delivery: "Sent to your notes folder and mailed to you.",
        hasOpenButton: true)

    // MARK: - The bug

    /// An ordinary set of notes fits, whole, with nothing hidden.
    @Test func anOrdinarySetOfNotesFitsInThePanel() {
        let out = NotesPanel.layout(Self.realNotes)
        #expect(!out.overflows)
        #expect(out.bodyHeight >= out.contentHeight)
        #expect(out.height <= NotesPanel.maximumHeight)
    }

    /// And the arithmetic it replaced did not: a flat 96 pt of chrome, the
    /// summary at 18 pt a line, decisions at 20 and action items at 26, all
    /// clamped to 320. Kept here as the number, because "it was too short" is
    /// not a thing a test can check on its own.
    @Test func theOldFlatMeasurementWasShortByMoreThanASection() {
        let n = Self.realNotes
        let summaryLines = max(1, min(8, (n.summary.count / 46) + 1))
        let old = min(max(96.0 + Double(summaryLines) * 18
                          + Double(min(n.decisions.count, 4)) * 20
                          + Double(min(n.actionItems.count, 4)) * 26, 120), 320)
        let now = NotesPanel.layout(n).height
        #expect(old < now)
        // Short by more than the ACTION ITEMS section is tall, which is why
        // the whole section went missing rather than being clipped in half.
        #expect(now - old > 60)
    }

    /// The chrome alone — header, wrapped title, the delivery footnote with
    /// its rule, the pill — is worth more than the 96 pt the old measurement
    /// allowed for all of it.
    @Test func theChromeAloneOutweighsTheOldAllowance() {
        #expect(NotesPanel.chrome(Self.realNotes, withHint: false) > 96)
    }

    // MARK: - Nothing is lost in silence

    /// More notes than the tallest panel can hold is a real case and no
    /// measurement fixes it. What must never happen is that it passes
    /// unannounced: when the body cannot show everything, `overflows` says so
    /// and the view draws the fade and the words.
    @Test func aBodyTooTallToFitSaysSo() {
        var n = Self.realNotes
        n.actionItems += (0..<12).map { "Someone \($0): a task long enough to wrap onto a second line all by itself" }
        let out = NotesPanel.layout(n)
        #expect(out.overflows)
        #expect(out.contentHeight > out.bodyHeight)
        #expect(out.height <= NotesPanel.maximumHeight)
    }

    /// `overflows` is exactly "the body is smaller than its content", never a
    /// guess: a cue on a panel showing everything is the same lie the other
    /// way round.
    @Test func theCueIsDrawnExactlyWhenSomethingIsHidden() {
        var n = NotesPanel.Notes(title: "Standup", delivery: "Sent to your notes folder.",
                                 hasOpenButton: true)
        for i in 0..<40 {
            n.actionItems.append("Person \(i): do the thing that was agreed")
            let out = NotesPanel.layout(n)
            #expect(out.overflows == (out.contentHeight > out.bodyHeight))
        }
    }

    // MARK: - A heading never survives without its content

    /// The worse variant a reviewer found: the cut landed straight after the
    /// DECISIONS heading, leaving a section label introducing nothing.
    ///
    /// Grow the notes one row at a time through every size that overruns the
    /// panel, and the bottom edge of the body must never land between a
    /// heading and the first row under it.
    @Test func theCutNeverLandsBetweenAHeadingAndItsFirstRow() {
        var n = NotesPanel.Notes(title: "Pricing review — what we are changing before the launch",
                                 summary: Self.realNotes.summary,
                                 delivery: "Sent to your notes folder and mailed to you.",
                                 hasOpenButton: true)
        for i in 0..<30 {
            if i % 2 == 0 {
                n.decisions.append("A decision, number \(i), of ordinary length.")
            } else {
                n.actionItems.append("Person \(i): a task of ordinary length — by Friday")
            }
            let out = NotesPanel.layout(n)
            for heading in NotesPanel.body(n).headings {
                #expect(!(heading.lowerBound < out.bodyHeight && out.bodyHeight < heading.upperBound),
                        "body ends at \(out.bodyHeight), inside heading \(heading)")
            }
        }
    }

    /// The rule itself, without the panel around it: an edge that lands in a
    /// heading's span is pulled back above the label, so the label goes below
    /// the fold with the rows it introduces rather than standing alone.
    @Test func aCutInsideAHeadingIsPulledBackAboveTheLabel() {
        let headings = [100.0...130.0, 200.0...240.0]
        #expect(NotesPanel.safeCut(90, avoiding: headings) == 90)     // clear
        #expect(NotesPanel.safeCut(110, avoiding: headings) == 100)   // inside the first
        #expect(NotesPanel.safeCut(130, avoiding: headings) == 130)   // exactly at its end
        #expect(NotesPanel.safeCut(210, avoiding: headings) == 200)   // inside the second
    }

    // MARK: - The bounds

    /// A panel is never a sliver and never taller than the window it is drawn
    /// in — `NotchIsland.maxContentHeight` is this number.
    @Test func theHeightStaysInsideThePanelsOwnBounds() {
        var n = NotesPanel.Notes()
        #expect(NotesPanel.layout(n).height == NotesPanel.minimumHeight)
        for i in 0..<60 {
            n.summary += "Another sentence about the pricing review, number \(i). "
            n.decisions.append("Decision \(i).")
            let h = NotesPanel.layout(n).height
            #expect(h >= NotesPanel.minimumHeight)
            #expect(h <= NotesPanel.maximumHeight)
        }
    }

    /// More content is never a shorter panel, up to the point where the panel
    /// gives up on fitting and says so.
    @Test func moreNotesNeverMeansASmallerPanel() {
        var n = NotesPanel.Notes(title: "Standup", summary: "One line.", hasOpenButton: true)
        var last = NotesPanel.layout(n).height
        for i in 0..<25 {
            n.decisions.append("Decision \(i), which is of an ordinary length for a decision.")
            let out = NotesPanel.layout(n)
            guard !out.overflows else { break }
            #expect(out.height >= last)
            last = out.height
        }
    }

    // MARK: - Wrapping

    @Test func wrappingCountsLinesAndNeverReturnsNone() {
        #expect(NotesPanel.wraps("", width: 300, size: 13, serif: true) == 1)
        #expect(NotesPanel.wraps("short", width: 300, size: 13, serif: true) == 1)
        #expect(NotesPanel.wraps(String(repeating: "x", count: 400),
                                 width: 330, size: 13, serif: true) > 1)
        // An explicit break starts a line of its own.
        #expect(NotesPanel.wraps("a\nb\nc", width: 330, size: 13, serif: true) == 3)
    }
}
