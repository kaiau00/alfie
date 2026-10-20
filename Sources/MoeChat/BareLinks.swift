import Foundation

/// Make the *bare* addresses in a reply clickable.
///
/// Sibling to `ReplyLinks`, which is about a different half of the same
/// complaint: that one collects the pages a turn actually opened off Hermes's
/// tool previews and shows them as Sources, and takes a trailing sources
/// block out of what is spoken. This one is about the addresses inside the
/// prose itself.
///
/// `AttributedString(markdown:)` turns `[label](href)` into a real link, and
/// SwiftUI's `Text` renders that as one you can click. It does **not** do
/// anything at all with a bare `https://example.com` — that stays flat grey
/// prose you have to select and copy by hand. Models write bare addresses far
/// more often than they write markdown ones, so on its own the markdown
/// renderer leaves most links dead.
///
/// This closes that gap the cheap way: find the bare addresses and give them
/// the markdown syntax the renderer already understands. It is a string-to-
/// string function on purpose — no AppKit, no SwiftUI, no view — so the rules
/// below are testable, which matters because every one of them is a case
/// where wrapping the wrong span would corrupt the reply rather than fail.
///
/// What it must not touch, and why:
///
///  - **Inside a fenced or inline code span.** `curl https://api.example.com`
///    in a code block is text about a command, not a link to follow, and
///    inserting brackets into it changes what the command says.
///  - **Inside an existing markdown link or image.** `[docs](https://x.com)`
///    is already a link; wrapping its href again produces `[docs]([https…]…)`,
///    which renders as literal brackets.
///  - **Trailing sentence punctuation.** "See https://example.com." ends in a
///    full stop that belongs to the sentence, not to the address, and a link
///    that swallows it goes to a 404.
///  - **A closing bracket that opened before the address.** "(see
///    https://example.com)" — the ")" closes the parenthesis, not the URL.
public enum BareLinks {

    /// `text` with every bare web address rewritten as a markdown link.
    ///
    /// The label is the address itself: it is what the person can check
    /// before they click, and inventing a friendlier one would be inventing.
    public static func autolink(_ text: String) -> String {
        guard text.contains("://") || text.lowercased().contains("www.") else { return text }
        var out = ""
        out.reserveCapacity(text.count + 16)

        for segment in Segments.split(text) {
            guard segment.linkable else {
                out += segment.text
                continue
            }
            out += rewrite(segment.text)
        }
        return out
    }

    /// Bare addresses inside one stretch of ordinary prose.
    private static func rewrite(_ s: String) -> String {
        guard let re = urlPattern else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0

        for match in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let found = ns.substring(with: match.range)
            let url = trimTail(found)
            guard url.count >= 8 else { continue }  // "www.a.co" is the shortest worth a link
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let href = url.lowercased().hasPrefix("www.") ? "https://" + url : url
            out += "[\(url)](\(href))"
            // Whatever the trim gave back — the sentence's full stop, a
            // closing bracket — stays outside the link, as prose.
            out += String(found.dropFirst(url.count))
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Punctuation that ends a sentence rather than an address.
    ///
    /// Brackets are counted rather than simply stripped: a Wikipedia address
    /// really can end in ")", and `…/Foo_(bar)` must keep it, while
    /// "(see https://x.com)" must not.
    static func trimTail(_ url: String) -> String {
        var s = Substring(url)
        // "https://example.com's page" — the possessive belongs to the
        // sentence. Taken before the single characters below, which would
        // drop the apostrophe and leave the "s" inside the address.
        for possessive in ["'s", "\u{2019}s"] where s.hasSuffix(possessive) {
            s = s.dropLast(possessive.count)
        }
        while let last = s.last {
            // Emphasis closes around an address, never inside it:
            // `**https://example.com**` was giving an href that ended in two
            // asterisks — a 404 — under a label that showed them.
            if ".,;:!?'\"*_~".contains(last) {
                s = s.dropLast()
            } else if last == ")" {
                let opens = s.filter { $0 == "(" }.count
                let closes = s.filter { $0 == ")" }.count
                if closes > opens { s = s.dropLast() } else { break }
            } else if last == "]" {
                let opens = s.filter { $0 == "[" }.count
                let closes = s.filter { $0 == "]" }.count
                if closes > opens { s = s.dropLast() } else { break }
            } else {
                break
            }
        }
        return String(s)
    }

    private static let urlPattern = try? NSRegularExpression(
        pattern: #"(?i)\b(?:https?://|www\.)[^\s<>]+"#)

    // MARK: - Segmenting

    /// The text cut into stretches that may hold a bare address and stretches
    /// that may not.
    enum Segments {
        struct Piece {
            let text: String
            /// False for code and for markdown that is already a link.
            let linkable: Bool
        }

        /// One pass, longest-match-first, so a fence wins over the backtick
        /// that starts it and a markdown link wins over the address inside it.
        static func split(_ text: String) -> [Piece] {
            guard let re = pattern else { return [Piece(text: text, linkable: true)] }
            let ns = text as NSString
            var pieces: [Piece] = []
            var cursor = 0
            for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > cursor {
                    pieces.append(Piece(
                        text: ns.substring(with: NSRange(location: cursor,
                                                         length: match.range.location - cursor)),
                        linkable: true))
                }
                pieces.append(Piece(text: ns.substring(with: match.range), linkable: false))
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                pieces.append(Piece(text: ns.substring(from: cursor), linkable: true))
            }
            return pieces
        }

        /// A fence (closed, or running to the end of a stream still being
        /// written), a code span, a markdown image, a markdown link.
        private static let pattern = try? NSRegularExpression(
            pattern: [
                #"```[\s\S]*?```"#,
                #"```[\s\S]*"#,
                #"`[^`\n]*`"#,
                #"!?\[[^\]]*\]\([^)]*\)"#,
                // A markdown link whose address has not finished arriving.
                // Every link Moe writes passes through this state, and both
                // the panel and the chat window re-render on every delta, so
                // without this the *ordinary* case flickers with a bracketed
                // href inside itself for as long as the address is streaming.
                // The unclosed-fence case above has a test and this did not,
                // which is the wrong way round: this one is far commoner.
                #"!?\[[^\]]*\]\([^)\n]*$"#,
            ].joined(separator: "|"))
    }
}
