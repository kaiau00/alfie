import Foundation

/// A reply's block structure: the parts `ReplyMarkdown.inline` does not read.
///
/// The model writes a drafted email or message as a markdown quote — every
/// line starting "> " — and headings as "# ". Inline parsing leaves those
/// markers on the page, so a draft reached the chat window and the island as
/// a column of ">" down the left edge (the owner, 2026-09-25: "it doesn't look
/// like a clean email-style situation"). The chat window and the island both
/// draw from this one split, a quote as a card of its own.
public enum ReplyBlock: Hashable, Sendable {
    /// Ordinary text, inline markdown still in it.
    case prose(String)
    /// A fenced ``` block.
    case code(String)
    /// A quoted block, markers removed: usually a draft Moe wrote for you.
    case quote(String)
    /// A "# heading" line, markers removed.
    case heading(String)
}

public enum ReplyBlocks {

    public static func parse(_ text: String) -> [ReplyBlock] {
        var blocks: [ReplyBlock] = []
        var buffer: [String] = []
        var kind: Kind = .prose

        enum Kind { case prose, code, quote }

        func flush() {
            let joined = buffer.joined(separator: "\n")
            buffer = []
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            switch kind {
            case .prose: blocks.append(.prose(trimmed))
            case .code: blocks.append(.code(trimmed))
            case .quote: blocks.append(.quote(trimmed))
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let bare = line.trimmingCharacters(in: .whitespaces)
            if bare.hasPrefix("```") {
                flush()
                kind = kind == .code ? .prose : .code
                continue
            }
            if kind == .code { buffer.append(line); continue }
            if bare.hasPrefix(">") {
                if kind != .quote { flush(); kind = .quote }
                var rest = bare.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                buffer.append(String(rest))
                continue
            }
            if kind == .quote {
                // A blank line inside a quote is the quote's own paragraph
                // break only when the quote carries on after it; otherwise
                // the quote has ended.
                flush(); kind = .prose
            }
            if let heading = headingText(bare) {
                flush()
                blocks.append(.heading(heading))
                continue
            }
            buffer.append(line)
        }
        // An unclosed fence or quote keeps its text either way: a stream cut
        // mid-block is the normal case, not an error.
        flush()
        return blocks
    }

    /// "# Title" / "## Title" / "### Title" → "Title"; nil for anything else
    /// ("#hashtag", "#1" are not headings).
    static func headingText(_ line: String) -> String? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...4).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The text of every block, markers gone, as the words a reader sees —
    /// for measuring, and for anything that shows a reply as one string.
    public static func plain(_ blocks: [ReplyBlock]) -> [(text: String, boxed: Bool)] {
        blocks.map {
            switch $0 {
            case .prose(let s), .heading(let s): return (s, false)
            case .code(let s), .quote(let s): return (s, true)
            }
        }
    }
}
