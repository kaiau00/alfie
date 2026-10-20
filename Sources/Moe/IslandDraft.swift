import MoeChat
import SwiftUI

/// What is half-typed into the island's ask field.
///
/// It was `@State` on `IslandView`, which is the right place for it right up
/// until something outside the view has to know about it. The clock that
/// folds a self-opened panel does: a panel that took itself away while
/// somebody was part-way through typing a question into it would be worse
/// than one that never opened. docs/PANEL-FINDINGS.md §7.
///
/// A side effect worth having: the draft now survives the panel being rebuilt
/// — which it is, on every state change the island observes.
@MainActor
final class IslandDraft: ObservableObject {
    @Published var text = ""
    /// Photos and files waiting to go with it — added with the field's +, or
    /// dropped on the notch.
    @Published var attachments: [ChatAttachment] = []

    /// Something is waiting in the field, words or files. Holds a panel open.
    var inProgress: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
}
