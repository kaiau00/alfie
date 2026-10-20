import Foundation

/// Tidying for the text read from ahead of the cursor, before it is shown to
/// the polish pass.
///
/// Pure Foundation and split out from `CursorContext` (which does the
/// Accessibility read) for the usual reason: the read needs a focused window
/// and a permission grant and cannot run under `swift test`, while the
/// trimming has the edge cases worth pinning down.
public enum CursorPrefix {

    /// The prefix worth sending, or nil when there is nothing useful in it.
    ///
    /// Three jobs, in order: collapse runs of blank lines (they say nothing
    /// and cost tokens), drop a leading part-word left by the character
    /// limit, and strip leading newlines. The *trailing* whitespace is
    /// deliberately kept — it is the only way the model can tell "the cursor
    /// is mid-word" from "the cursor is at the start of the next word", which
    /// decides whether the dictation needs a leading space and a capital.
    public static func tidy(_ text: String?) -> String? {
        guard var s = text else { return nil }
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }

        // A prefix cut mid-word by the character limit starts at the next
        // boundary instead — but only when enough is left to be worth
        // sending. One long token is better whole than truncated.
        if let first = s.first, !first.isWhitespace,
           let boundary = s.firstIndex(where: { $0.isWhitespace }) {
            let rest = String(s[s.index(after: boundary)...])
            if rest.count >= 24 { s = rest }
        }

        while let f = s.first, f.isNewline { s.removeFirst() }
        return s.isEmpty ? nil : s
    }
}
