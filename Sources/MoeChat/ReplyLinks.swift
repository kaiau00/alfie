import Foundation

/// The pages a reply actually came from, kept as links rather than described.
///
/// Moe is spoken, so the prompt has always said "no URLs" — and the rule
/// leaked past the speaker into everything. Asked for the links behind a
/// piece of web research, Moe read the sources out as names ("the Anthropic
/// docs page") and there was nothing to click anywhere in the app, because
/// nothing on the screen ever held a URL.
///
/// Two things fix that, and they are separate on purpose:
///
/// - `found(in:)` reads URLs out of Hermes's own preview of each tool call —
///   the page it opened, the feed it fetched. That is the artefact, not the
///   model's recollection of it, so a link shown from here is a page Moe
///   really went to.
/// - `strippingSources(_:)` takes a trailing "Sources:" block out of what is
///   *spoken*. The links stay in the transcript, where they can be clicked;
///   the speaker does not read a list of addresses aloud.
public enum ReplyLinks {

    /// One page Moe opened, as it will be shown.
    public struct Link: Hashable, Sendable, Codable {
        /// The address, exactly as it will be opened.
        public var url: String
        /// What to put on screen: the host and the first path component,
        /// which is as much as a chip has room for and enough to recognise.
        public var label: String

        public init(url: String, label: String) {
            self.url = url
            self.label = label
        }
    }

    /// Every http(s) URL in a tool's preview line, in the order they appear
    /// and without repeats. Anything else in the line — a query, a filename,
    /// a shell command — is ignored, so this finds pages and nothing else.
    public static func found(in detail: String) -> [Link] {
        guard detail.contains("http") else { return [] }
        let pattern = "https?://[^\\s\"'<>()\\[\\]]+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = detail as NSString
        var out: [Link] = []
        var seen = Set<String>()
        for m in re.matches(in: detail, range: NSRange(location: 0, length: ns.length)) {
            var url = ns.substring(with: m.range)
            // A URL that ends a sentence takes the punctuation with it.
            while let last = url.last, ",.;:!?".contains(last) { url.removeLast() }
            guard url.count > "https://".count, !seen.contains(url) else { continue }
            seen.insert(url)
            out.append(Link(url: url, label: label(for: url)))
        }
        return out
    }

    /// "https://www.anthropic.com/news/claude" → "anthropic.com/news".
    /// Long enough to tell two sources apart, short enough for a chip.
    public static func label(for url: String) -> String {
        guard let parsed = URL(string: url), var host = parsed.host else { return url }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let first = parsed.pathComponents.first(where: { $0 != "/" && !$0.isEmpty })
        guard let first, first.count <= 24 else { return host }
        return "\(host)/\(first)"
    }

    /// The line that opens a sources block, in the wording the prompt asks
    /// the model for. Matched case-insensitively and with nothing else on
    /// the line, so a sentence that merely mentions sources is untouched.
    private static let sourcesHeadings = ["sources:", "sources", "links:", "links"]

    /// What to speak: the reply without its trailing sources block.
    ///
    /// Only a trailing block, and only when it is the last thing in the
    /// reply — a "Sources:" heading in the middle of an answer is part of
    /// the answer. Text before it is returned unchanged, so the offsets the
    /// speech pump keeps into the raw reply still line up with it.
    public static func strippingSources(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let heading = lines.lastIndex(where: { line in
            let key = line.trimmingCharacters(in: .whitespaces).lowercased()
            return sourcesHeadings.contains(key)
        }) else { return text }
        // Everything after the heading has to look like a list of links,
        // or this is not a sources block and nothing is dropped. A heading
        // with nothing after it yet is the streaming case — the links are
        // still arriving — and the word "Sources" on its own is not an
        // answer, so it goes too.
        let rest = lines[(heading + 1)...].filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard rest.isEmpty || rest.allSatisfy({ $0.contains("http") || $0.contains("](") }) else {
            return text
        }
        return lines[..<heading].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
