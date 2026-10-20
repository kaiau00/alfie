import Foundation
import MoeIsland
import MoeMeeting

/// The one place the notes panel's state is turned into the strings
/// `NotesPanel` measures.
///
/// `NotchIsland` needs the height and `IslandView` needs to know whether the
/// body overflowed, and the two must never disagree — a panel sized for
/// content it then decides to hide, or a "there is more" cue on a panel that
/// is showing everything, is the same class of bug as the one this fixes. So
/// they call this, and it reads the same fields the view draws from.
extension NotesPanel {

    @MainActor static func input(for conductor: Conductor) -> Notes {
        let outcome = conductor.meetingOutcome
        let notes = outcome?.record.notes
        var open = false
        if case .done = conductor.meeting { open = true }
        return Notes(
            title: notes?.title ?? "Notes ready",
            summary: notes?.summary ?? "",
            decisions: notes?.decisions ?? [],
            actionItems: (notes?.actionItems ?? []).map(line),
            audioNote: audioNote(for: outcome?.record)?.text,
            delivery: conductor.meetingDelivery,
            hasOpenButton: open)
    }

    @MainActor static func layout(for conductor: Conductor) -> Layout {
        layout(input(for: conductor))
    }

    /// Exactly the string `IslandView` puts beside the checkbox.
    static func line(_ item: MeetingNotes.ActionItem) -> String {
        (item.who.isEmpty ? "" : "\(item.who): ") + item.what
            + (item.when.isEmpty ? "" : " — by \(item.when)")
    }

    /// What became of this meeting's audio, when that is worth a line.
    static func audioNote(for record: MeetingRecord?) -> (text: String, kept: Bool)? {
        guard let record else { return nil }
        // Which of the two rules kept it decides which sentence is true:
        // "almost nothing was transcribed" is a lie about a meeting where
        // the far end produced forty lines and the microphone none.
        if let why = record.recordingsKeptReason { return (CaptureCheck.shortNote(keptReason: why), true) }
        if let why = record.recordingsDeletedNote { return (CaptureCheck.shortNote(deletedNote: why), false) }
        return nil
    }
}
