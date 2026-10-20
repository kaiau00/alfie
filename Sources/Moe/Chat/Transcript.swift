import AppKit
import Foundation
import MoeDesign
import SwiftUI

/// The conversation as text, for copying and for selecting across messages.
///
/// The owner, 2026-09-29: "it doesn't let me drag and copy a whole bunch of
/// messages at the same time. There's no copy button." Each message was its
/// own selectable text, and a selection cannot cross from one to the next;
/// only Moe's answers had Copy, in a menu. Now every message copies on its
/// own (right-click), the whole conversation copies in one go, and the
/// chat window's Select shows the conversation as one page a drag can run
/// across.
enum Transcript {

    /// "You: …" and "Moe: …", a blank line between, in order. Moe's own
    /// status lines ("Connection dropped…") are left out: they are not
    /// something either of you said.
    static func plain(_ turns: [Turn]) -> String {
        turns.compactMap { t -> String? in
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch t.role {
            case .you: return "You: \(text)"
            case .moe: return "Moe: \(text)"
            case .system: return nil
            }
        }.joined(separator: "\n\n")
    }

    /// The same, styled for reading: the names in bold, Moe's markdown read.
    static func styled(_ turns: [Turn]) -> AttributedString {
        var out = AttributedString()
        var first = true
        for t in turns where t.role != .system {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !first { out += AttributedString("\n\n") }
            first = false
            var name = AttributedString(t.role == .you ? "You\n" : "Moe\n")
            name.font = .system(size: 12, weight: .semibold)
            name.foregroundColor = t.role == .you ? Theme.you : Theme.accent
            out += name
            out += MarkdownText.styled(text)
        }
        return out
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
