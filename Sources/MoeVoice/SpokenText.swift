import Foundation

/// What the synthesiser is handed, as distinct from what the panel shows.
///
/// Until now those were the same string, and that is why the system prompt
/// had to forbid markdown and URLs outright: an asterisk or an "https://" in
/// a reply was read out loud, character by character, "h-t-t-p-s colon slash
/// slash". The ban worked for speech and cost the *shown* reply everything —
/// asked for a page, Moe spelled the address out in prose, and nothing in the
/// panel was clickable, in either direction.
///
/// Splitting the two is the fix, and it is a split rather than a setting. The
/// reply keeps its real markdown and its real URLs, the panel renders them
/// (`BareLinks`), and this strips them on the way to the speaker. A link is
/// spoken as its label and never as its address.
///
/// Two properties this must have, because of where it is called from:
///
///  - **It runs on fragments.** `Conductor.speakReadySentences` hands over one
///    sentence at a time out of a stream, so every rule here has to be right
///    on a piece of a document as well as on a whole one.
///  - **It changes only what is spoken.** The offsets that track what the
///    person has heard (`replyEnd`, and the resume after a barge-in) are
///    measured on the *raw* reply. Nothing here may be used to compute one.
public enum SpokenText {

    /// Strip the markup out of `text`, leaving what a person would say.
    public static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var s = dropFencedCode(text)
        s = stripLines(s)
        s = stripInline(s)
        s = speakIdentifiers(s)
        s = dropSymbols(s)
        return tidy(s)
    }

    // MARK: - Blocks

    /// Everything between a pair of ``` fences, gone.
    ///
    /// A code block read aloud is unusable — that is why the voice prompt asks
    /// for none — but a model that produces one anyway should cost silence,
    /// not two minutes of punctuation. An *unclosed* fence drops the rest of
    /// the chunk for the same reason: mid-stream that is a block still being
    /// written, and it is about to be exactly as unspeakable.
    private static func dropFencedCode(_ text: String) -> String {
        guard text.contains("```") else { return text }
        var kept: [String] = []
        var inCode = false
        var droppedAny = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                // Three words in place of the block, which is what this said
                // before the rules moved. Saying nothing at all is not the
                // same as saying nothing important: a spoken question whose
                // whole answer is a code block would leave Moe silent with no
                // explanation, and — because `VoiceEngine.speak` drops an
                // empty string before it records `replyEnd` — would leave the
                // heard-offset behind the reply, so a barge-in afterwards
                // resumed by repeating what had already been said.
                if inCode, !droppedAny { kept.append(codeWord); droppedAny = true }
                continue
            }
            if inCode { droppedAny = true } else { kept.append(String(line)) }
        }
        return kept.joined(separator: "\n")
    }

    /// What a fenced block is called out loud.
    private static let codeWord = "Code block."

    /// Line-level markers: headings, quotes, bullets, rules, table pipes.
    private static func stripLines(_ text: String) -> String {
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)

            // A horizontal rule is punctuation for the eye and nothing for
            // the ear.
            if replace(line, #"^\s*([-*_])\1{2,}\s*$"#, "").isEmpty { continue }
            // "|---|:--:|" — the shape of a table, never its contents.
            if line.contains("|"), replace(line, #"^[\s:|+-]+$"#, "").isEmpty { continue }

            line = replace(line, #"^\s{0,3}#{1,6}\s+"#, "")     // # Heading
            line = replace(line, #"^\s{0,3}>\s?"#, "")          // > quote

            // A list item is a sentence of its own to the ear. Remember that
            // it was one so the pause can be put back below.
            let before = line
            line = replace(line, #"^\s*[-*+•]\s+"#, "")         // - bullet
            line = replace(line, #"^\s*\d+[.)]\s+"#, "")        // 1. numbered
            let wasItem = line != before

            // Only a row that is *fenced* by pipes. Any line containing one
            // was too broad: "Revenue | Marketing split the budget" became
            // "Revenue, Marketing split the budget", which says a different
            // thing, and "grep foo | wc -l" stopped being a command. A table
            // row starts with a pipe; a sentence with a pipe in it does not.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                line = replace(line, #"^\s*\|"#, "")
                line = replace(line, #"\|\s*$"#, "")
                line = line.replacingOccurrences(of: "|", with: ", ")
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if wasItem, trimmed.count > 1,
               let last = trimmed.last, !".!?,;:".contains(last) {
                line = trimmed + "."
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Inline

    /// Links, emphasis, code spans and bare addresses.
    ///
    /// Order matters. Images go before links (an image is a link with a `!`),
    /// links go before bare URLs (or the address inside a perfectly good
    /// `[label](…)` would be found and announced on its own), and both go
    /// before emphasis (a URL can contain an underscore).
    private static func stripInline(_ text: String) -> String {
        var s = text
        s = replace(s, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")            // ![alt](src)
        s = replace(s, #"\[([^\]]*)\]\([^)]*\)"#, "$1")             // [label](href)
        s = replace(s, #"<(?:https?://|mailto:)[^>\s]+>"#, linkWord) // <https://…>
        // The last character may not be sentence punctuation. `\S+` took the
        // full stop off the end of "find it at https://example.com/x." with
        // the address, and the sentence was then spoken without an ending —
        // which the synthesiser hears as a clause running into the next one.
        s = replace(s, #"(?i)\b(?:https?://|www\.)[^\s<>]*[^\s<>.,;:!?'"\)\]]"#, linkWord)

        s = replace(s, "`([^`]*)`", "$1")                            // `code`
        s = replace(s, #"~~(.+?)~~"#, "$1")                          // ~~struck~~
        s = replace(s, #"(\*\*|__)(.+?)\1"#, "$2")                   // **bold**
        s = replace(s, #"\*(?=\S)(.+?)(?<=\S)\*"#, "$1")             // *italic*
        // Underscores only where they are punctuation. `_this_` is emphasis;
        // `some_identifier_name` is a name, and mangling it is worse than
        // reading it.
        s = replace(s, #"(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])"#, "$1")
        return s
    }

    /// What a web address is called out loud. Not the address: the whole
    /// point of the split is that the address is on screen and clickable, and
    /// saying it is the behaviour this replaces. A noun keeps the sentence
    /// grammatical — "you can find it at the link" — where deleting it
    /// outright leaves "you can find it at".
    private static let linkWord = "the link"

    // MARK: - Identifiers

    /// Machine names read as the words they are made of.
    ///
    /// A reply that lists the person's own jobs or files says
    /// "weekly-digest-job" or "weekly_digest_job", and Kokoro garbles the
    /// joins into something that is no word at all (Alfie, 2026-10-22). Read
    /// as "weekly digest job" it is clear. Two rules, each narrow:
    ///
    ///  - **Any underscore between letters or digits** is a name's joint:
    ///    prose never writes one.
    ///  - **Hyphens only in a run of three or more parts.** "follow-up",
    ///    "well-known" and "e-mail" are words and stay as written; a date
    ///    ("2026-10-21") has no letters and is left alone too.
    static func speakIdentifiers(_ text: String) -> String {
        var s = text
        s = replace(s, #"(?<=[A-Za-z0-9])_+(?=[A-Za-z0-9])"#, " ")
        guard let re = cache.expression(#"\b[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+){2,}\b"#) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += ns.substring(with: m.range).replacingOccurrences(of: "-", with: " ")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: - Symbols

    /// Emoji and the other pictures a reply can carry, gone; arrows and
    /// mid-line bullets turned into the pause they stand for.
    ///
    /// Inworld's text-preparation guide: no emoji. Only the voice prompt
    /// forbade them, and typed replies, tool narration and pasted text reach
    /// the speaker without that prompt — where 🎉 is read as "party popper"
    /// or skipped with an odd pause, depending on the voice.
    ///
    /// Judged per character as a person sees it (a grapheme), not per scalar:
    /// 👍🏽 is two scalars, a family is five joined by U+200D, a flag is two
    /// regional indicators, and each is one picture to drop. A keycap (1️⃣)
    /// is spoken as its digit. Digits, `#` and `*` are "emoji" to Unicode
    /// (they can start a keycap) and are kept, as is everything a language
    /// writes words with.
    private static func dropSymbols(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x2000 }) else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            let scalars = ch.unicodeScalars
            guard let first = scalars.first else { continue }
            if scalars.contains(where: { $0.value == 0x20E3 }) {        // keycap: 1️⃣ → 1
                out.unicodeScalars.append(first)
                continue
            }
            if arrows.contains(first) || midBullets.contains(first) {
                out += ", "
                continue
            }
            if isPicture(ch) { out += " "; continue }
            out.append(ch)
        }
        return out
    }

    private static let arrows: Set<Unicode.Scalar> = ["→", "⇒", "⟶", "➔", "➜", "➡", "↦"]
    private static let midBullets: Set<Unicode.Scalar> = ["•", "▪", "◦", "‣"]

    private static func isPicture(_ ch: Character) -> Bool {
        for s in ch.unicodeScalars {
            let v = s.value
            if s.properties.isEmojiPresentation { return true }
            if v == 0xFE0F || v == 0x200D { return true }           // emoji style, joiner
            if (0x1F1E6...0x1F1FF).contains(v) { return true }      // flags
            if (0x1F3FB...0x1F3FF).contains(v) { return true }      // skin tones
            if (0xE0020...0xE007F).contains(v) { return true }      // tag sequences
            if (0x2190...0x21FF).contains(v) { return true }        // arrows
            if (0x2500...0x27BF).contains(v) { return true }        // box, shapes, misc symbols, dingbats
            if (0x2B00...0x2BFF).contains(v) { return true }        // misc symbols and arrows (⭐)
            if (0x1F000...0x1FAFF).contains(v) { return true }      // pictographs of every kind
        }
        return false
    }

    // MARK: - Tidying

    /// What the strips leave behind: doubled spaces, a space in front of a
    /// comma, an empty pair of brackets, a line that now ends on a colon
    /// introducing something that is no longer there.
    private static func tidy(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = replace(s, #"\(\s*\)"#, "")
        s = replace(s, #"\[\s*\]"#, "")
        s = replace(s, #"[ \t]{2,}"#, " ")
        s = replace(s, #"\s+([,.;:!?])"#, "$1")
        s = replace(s, #"([,;:])\1+"#, "$1")
        s = s.trimmingCharacters(in: .whitespaces)
        // "Here it is:" with the address taken out of it. A colon that
        // introduces nothing is a full stop.
        if let last = s.last, ":;,—–-".contains(last) {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
            if let end = s.last, !".!?".contains(end) { s += "." }
        }
        return s
    }

    // MARK: - Regex

    /// Compiled once each. `clean` runs on every sentence of every spoken
    /// reply, and `NSRegularExpression(pattern:)` parses its pattern on every
    /// construction.
    private static let cache = RegexCache()

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = cache.expression(pattern) else { return s }
        return re.stringByReplacingMatches(in: s,
                                           range: NSRange(s.startIndex..., in: s),
                                           withTemplate: template)
    }

    /// A tiny lock-free-enough cache. `clean` is called from the main actor in
    /// the app and from tests; the lock costs nothing next to the regex.
    private final class RegexCache: @unchecked Sendable {
        private var store: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func expression(_ pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = store[pattern] { return cached }
            guard let made = try? NSRegularExpression(
                pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
            store[pattern] = made
            return made
        }
    }
}
