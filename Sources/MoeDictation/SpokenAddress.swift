import Foundation

/// Spoken email addresses and web addresses, written the way they are typed.
///
/// "email jane three at example dot ai" → "email jane3@example.ai".
///
/// This used to be refused outright, and the refusal was pinned by a test:
/// "at" and "dot" are ordinary English words, and converting every one of
/// them would wreck plain prose ("meet me at the dot on the map"). That is
/// true, and it is why the rule here is not "convert at and dot" but
/// **"find the shape of an address, and only then convert what is inside
/// it"**. The shape is anchored on one thing that is very rarely a
/// coincidence: the word *dot* immediately followed by a known top-level
/// domain. Nothing converts unless that anchor is found, and only the run of
/// words around it converts — the rest of the sentence is untouched.
///
/// What that buys, and what it costs:
///
/// - "example dot com" → "example.com". Anchored: `com` is a TLD.
/// - "izzy at example dot com" → "izzy@example.com". The `at` converts only
///   because the anchor fired to its right and the words between are a
///   plausible host.
/// - "a c m e dot a i" → "acme.ai". Single letters are run together —
///   the recogniser spells out letters people say one at a time, and a
///   sequence of them is never ordinary prose inside an address.
/// - "meet me at the coffee shop" → untouched. No anchor.
/// - "dot matrix printer" → untouched. `matrix` is not a TLD.
/// - "I'll be there at four dot five" → untouched. `five` is not a TLD.
///
/// The known cost is a sentence that genuinely ends "…dot" and then begins
/// with a TLD word — "the fifth dot. Com panies are…". Terminal punctuation
/// blocks that one: the anchor requires the two words be adjacent with
/// nothing but a space between them.
public enum SpokenAddress {

    /// Top-level domains worth anchoring on. Deliberately not the full IANA
    /// list — that contains `zip`, `mov`, `new`, `art`, `bar`, `box`, `day`,
    /// `one` and hundreds of other ordinary English words, and anchoring on
    /// those would convert prose. These are the ones people actually say,
    /// minus any that double as a common word.
    static let tlds: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int",
        "io", "ai", "co", "dev", "app", "me", "tv", "fm", "ly", "sh", "gg",
        "xyz", "info", "biz", "online", "site", "tech", "cloud", "store",
        "uk", "us", "ca", "de", "fr", "es", "it", "nl", "se", "no", "fi",
        "dk", "pl", "ru", "jp", "cn", "kr", "in", "au", "nz", "br", "mx",
        "ch", "at", "be", "ie", "pt", "gr", "cz", "il", "za", "ae", "sg",
    ]

    /// Second-level pieces that legitimately precede a country TLD:
    /// "example dot co dot uk".
    static let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]

    /// Symbols dictated inside an address. Only ever applied within a run
    /// that the anchor has already claimed.
    static let symbols: [String: String] = [
        "dash": "-", "hyphen": "-", "underscore": "_", "under score": "_",
        "slash": "/", "forward slash": "/", "plus": "+", "tilde": "~",
    ]

    /// Words that may sit inside a host or local part without ending the
    /// address: the recogniser writes "at" and "dot" as words, and a
    /// spelled-out letter arrives as a bare letter.
    private static let separators: Set<String> = ["dot", "point", "at"]

    /// Words that are never somebody's local part. "email john at acme dot
    /// com" is an address; "it is at acme dot com" is a sentence with an
    /// address in it, and the only difference is the word in front of "at".
    /// A local part is a name, a handle or a department — never a pronoun,
    /// an article or a form of "to be". When the word to the left of "at"
    /// is one of these, "at" stays the preposition it plainly is and only
    /// the host converts.
    static let neverALocalPart: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "am",
        "it", "that", "this", "these", "those", "they", "them",
        "here", "there", "now", "up", "live", "hosted", "available",
        "me", "you", "him", "her", "us", "we", "i", "he", "she",
        "the", "a", "an", "and", "or", "but", "so",
        "look", "looking", "arrived", "arriving", "found", "posted",
    ]

    // MARK: - Entry point

    /// Rewrite every spoken address in `text`. Returns `text` unchanged when
    /// there is no anchor, which is the overwhelmingly common case — this is
    /// cheap to call on every transcript.
    public static func rewrite(_ text: String) -> String {
        let tokens = tokenise(text)
        let words = tokens.map(\.word)
        guard words.contains(where: { $0 == "dot" || $0 == "point" }) else { return text }

        // Each match is (first token it replaces, one past the last, the
        // written address). Found left to right; a later anchor can never
        // reach back into a run an earlier one already claimed.
        var matches: [(Int, Int, String)] = []
        var i = 0
        while i < words.count {
            guard words[i] == "dot" || words[i] == "point",
                  let (tail, afterTld) = readTail(tokens, dotAt: i),
                  let (head, from) = readHead(tokens, before: i, notBefore: matches.last?.1 ?? 0),
                  !head.isEmpty
            else { i += 1; continue }
            matches.append((from, afterTld, head + tail))
            i = afterTld
        }
        guard !matches.isEmpty else { return text }

        var out: [String] = []
        var n = 0
        var m = 0
        while n < tokens.count {
            if m < matches.count, matches[m].0 == n {
                let (_, end, written) = matches[m]
                // Whatever punctuation followed the last word of the run
                // belongs to the sentence, not to the address.
                out.append(written + tokens[end - 1].trailing)
                n = end
                m += 1
            } else {
                out.append(tokens[n].raw)
                n += 1
            }
        }
        return out.joined(separator: " ")
    }

    /// Is the anchor — "dot" adjacent to a known TLD — anywhere in the text?
    static func hasAnchor(_ text: String) -> Bool {
        let tokens = tokenise(text)
        for (n, t) in tokens.enumerated() where t.word == "dot" || t.word == "point" {
            if readTail(tokens, dotAt: n) != nil { return true }
        }
        return false
    }

    // MARK: - Tokens

    struct Token {
        /// The word as it appeared, punctuation and all — what is put back
        /// when nothing converts.
        let raw: String
        /// Lowercased letters and digits only, for matching.
        let word: String
        /// Punctuation that followed it (", " or "." or "?").
        let trailing: String
    }

    static func tokenise(_ text: String) -> [Token] {
        text.split(separator: " ", omittingEmptySubsequences: true).map { piece in
            let raw = String(piece)
            var body = raw
            var trailing = ""
            while let last = body.last, ",.?!;:".contains(last) {
                trailing = String(last) + trailing
                body.removeLast()
            }
            return Token(raw: raw, word: body.lowercased(), trailing: trailing)
        }
    }

    /// Read a TLD starting at `i`: either one word ("com") or a run of single
    /// letters that spell one ("a i" → "ai", "c o m" → "com"). The longest
    /// reading wins, or "c o m" would stop at "co".
    /// Returns the TLD and the index just past it.
    static func tld(at i: Int, in tokens: [Token]) -> (String, Int)? {
        guard i < tokens.count else { return nil }
        let w = tokens[i].word
        // No TLD is one letter, so a bare single letter always falls
        // through to the spelled-out reading below.
        if tlds.contains(w) { return (w, i + 1) }
        var letters = ""
        var n = i
        while n < tokens.count, tokens[n].word.count == 1,
              tokens[n].word.first?.isLetter == true, letters.count < 4 {
            letters += tokens[n].word
            n += 1
            if !tokens[n - 1].trailing.isEmpty { break }
        }
        while letters.count > 1 {
            if tlds.contains(letters) { return (letters, i + letters.count) }
            letters.removeLast()
        }
        return nil
    }

    /// The part of the address at and after the dot: ".com", ".co.uk".
    /// Returns the written tail and the index just past it.
    static func readTail(_ tokens: [Token], dotAt i: Int) -> (String, Int)? {
        // "dot" spoken with punctuation after it ended a sentence.
        guard tokens[i].trailing.isEmpty, let (first, after) = tld(at: i + 1, in: tokens) else { return nil }
        var tail = "." + first
        var end = after
        // "example dot co dot uk": a second-level piece takes another dot.
        if secondLevel.contains(first), end < tokens.count, tokens[end].word == "dot",
           tokens[end].trailing.isEmpty, let (second, after2) = tld(at: end + 1, in: tokens) {
            tail += "." + second
            end = after2
        }
        return (tail, end)
    }

    /// The part before the dot, walked backwards. Exactly one label, then
    /// further left only across a join — a symbol ("dash"), an "@" ("at"),
    /// or the spelled-out letters the recogniser writes one at a time.
    ///
    /// One label is the whole trick. "go to example dot com" has no marker
    /// saying "example" is the host and "to" is not, so the rule is that a
    /// bare word before the dot is the host and the word before *that* is
    /// the sentence — unless something joins them.
    /// Returns the written head and the index it starts at.
    static func readHead(_ tokens: [Token], before dot: Int, notBefore floor: Int) -> (String, Int)? {
        var i = dot - 1
        guard i >= floor, isLabel(tokens[i]), tokens[i].trailing.isEmpty else { return nil }
        var parts: [String] = []
        var sawAt = false

        func takeLabel() -> Bool {
            guard i >= floor, isLabel(tokens[i]), tokens[i].trailing.isEmpty else { return false }
            var label = tokens[i].word
            i -= 1
            // Spelled out: "a c m e" is one label, not three.
            while i >= floor, tokens[i].word.count == 1, tokens[i].word.first?.isLetter == true,
                  tokens[i].trailing.isEmpty {
                label = tokens[i].word + label
                i -= 1
            }
            parts.insert(label, at: 0)
            return true
        }

        guard takeLabel() else { return nil }
        while i >= floor, tokens[i].trailing.isEmpty {
            let w = tokens[i].word
            if let sym = symbols[w] {
                parts.insert(sym, at: 0)
                i -= 1
                guard takeLabel() else { return nil }
                continue
            }
            if w == "at", !sawAt {
                // Only an "@" when what sits to its left could be a local
                // part. Otherwise this is the preposition, and the address
                // is just the host.
                guard i - 1 >= floor, isLabel(tokens[i - 1]),
                      !neverALocalPart.contains(tokens[i - 1].word) else { break }
                parts.insert("@", at: 0)
                sawAt = true
                i -= 1
                guard takeLabel() else { return nil }
                continue
            }
            break
        }
        return (parts.joined(), i + 1)
    }

    /// A word that can be a host label or a local part: letters and digits,
    /// and never one of the words that joins them.
    static func isLabel(_ t: Token) -> Bool {
        !t.word.isEmpty
            && t.word.allSatisfy { $0.isLetter || $0.isNumber }
            && !separators.contains(t.word)
            && symbols[t.word] == nil
    }

    /// Glue the pieces: words run together, symbols bind on both sides.
    static func join(_ parts: [String]) -> String {
        parts.joined()
    }
}
