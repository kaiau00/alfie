import Foundation

/// Turns the raw name fields of an address book into vocabulary terms. Pure,
/// so the app's Contacts feed (`ContactsVocabulary`) only has to fetch.
///
/// A contact card is noisy: initials, "mum", lowercase nicknames, emoji,
/// phone-shaped "names", a whole company slogan in the organisation field.
/// What is worth teaching the recogniser is a word that looks like a proper
/// noun — capitalised, three letters or more — because that is exactly what
/// it will otherwise lowercase or mishear.
public enum ContactTerms {

    /// The most terms `filter` keeps. Enough for a large address book; small
    /// enough that the matcher and the polish prompt stay quick.
    public static let cap = 2_000

    /// Each name field is split on whitespace so "Anna-Maria Vogel" yields
    /// "Anna-Maria" and "Vogel" (and matches when either is said alone).
    /// Kept: words of 3+ characters with at least one letter, at least one
    /// uppercase letter, no digits. Dropped: 1–2 character tokens, all-
    /// lowercase junk, anything with digits or with characters the file
    /// syntax reserves (`#`, `=>`). Duplicates collapse case-insensitively,
    /// the first spelling winning. Order is first-seen, so callers can put
    /// the fields they trust most first; the result is capped at `cap`.
    ///
    /// Anything that is also an everyday word (`common`) is dropped: a
    /// contact called "Will" or an organisation called "The Bank" would
    /// otherwise turn every "will", "the" and "bank" the user says into a
    /// capitalised one, since a bare term is a case-insensitive rule.
    public static func filter(_ fields: [String], cap: Int = ContactTerms.cap,
                              common: CommonWords = .basic) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for field in fields {
            for piece in field.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "/" }) {
                let word = String(piece).trimmingCharacters(in: trimmed)
                guard keeps(word), !common.contains(word), seen.insert(word.lowercased()).inserted else { continue }
                out.append(word)
                if out.count >= cap { return out }
            }
        }
        return out
    }

    /// Punctuation a name is unlikely to start or end with. Hyphens and
    /// apostrophes inside ("O'Brien", "Anna-Maria") are kept.
    private static let trimmed = CharacterSet.punctuationCharacters
        .union(.symbols)
        .subtracting(CharacterSet(charactersIn: "'’-"))

    static func keeps(_ word: String) -> Bool {
        guard word.count >= 3 else { return false }
        guard word.contains(where: \.isUppercase) else { return false }
        guard !word.contains("#"), !word.contains("=>") else { return false }
        var letters = 0
        for ch in word {
            if ch.isNumber { return false }
            if ch.isLetter { letters += 1 } else if !"'’-.&".contains(ch) { return false }
        }
        return letters >= 2
    }
}
