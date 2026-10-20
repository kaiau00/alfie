import Foundation

/// Everyday English words, used to keep the vocabulary from ever rewriting
/// one. A Contacts card called "Will Bank" or a slip that turned "mark"
/// into "Matt" must not make every later "will", "bank" or "mark" come out
/// capitalised or replaced: a whole-word, case-insensitive rule for a word
/// people say all day is a corruption, not a spelling.
///
/// `system` reads the lowercase-initial entries of `/usr/share/dict/words`
/// (capitalised entries are proper nouns and are left alone — "Siobhan" or
/// "Nile" may well be exactly what the user wants taught). A handful of
/// words are built in so the guard holds even where the file is missing.
public struct CommonWords: Sendable {

    public let words: Set<String>

    public init(_ words: Set<String>) {
        self.words = words.union(CommonWords.builtIn)
    }

    /// Whether `word` (any casing) is an everyday word.
    public func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    public static let basic = CommonWords([])

    /// The system dictionary, read once. About 200k words; ~40 ms.
    public static let system = CommonWords(load(path: "/usr/share/dict/words"))

    static func load(path: String) -> Set<String> {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out = Set<String>()
        for line in text.split(separator: "\n") where line.first?.isLowercase == true {
            out.insert(String(line))
        }
        return out
    }

    /// Always common, whatever the dictionary says; also covers days and
    /// months, which the dictionary lists capitalised.
    static let builtIn: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "has",
        "her", "was", "one", "our", "out", "day", "get", "him", "his", "how", "man", "new",
        "now", "old", "see", "two", "way", "who", "did", "its", "let", "put", "say", "she",
        "too", "use", "that", "with", "have", "this", "will", "your", "from", "they", "been",
        "call", "were", "when", "what", "some", "them", "than", "then", "there", "their",
        "these", "those", "which", "would", "could", "should", "about", "into", "just",
        "like", "more", "most", "much", "only", "over", "such", "take", "very", "well",
        "also", "back", "even", "here", "know", "make", "many", "need", "next", "same",
        "want", "where", "while", "think", "thing", "things", "time", "year", "years",
        "people", "because", "before", "after", "other", "does", "done", "each", "good",
        "great", "still", "sure", "yes", "yeah", "okay", "thanks", "thank", "please",
        "affect", "effect", "hear", "right", "write", "week", "weak",
        "whether", "weather", "principal", "principle", "bank", "group", "inc", "ltd",
        "company", "home", "best", "buy", "mum", "dad", "mom", "work", "office", "team",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]
}
