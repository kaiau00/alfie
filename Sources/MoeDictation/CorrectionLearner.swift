import Foundation

/// A word the user replaced in dictated text: what was pasted → what they
/// typed over it. `heard` is kept lowercased, `correct` as typed.
public struct Correction: Hashable, Sendable, Codable {
    public let heard: String
    public let correct: String

    public init(heard: String, correct: String) {
        self.heard = heard.lowercased()
        self.correct = correct
    }

    /// The `vocabulary.txt` line that would apply this correction.
    public var line: String { "\(heard) => \(correct)" }
}

/// Learns spellings from what the user does right after a paste.
///
/// The app pastes the polished text, waits a few seconds, then reads the
/// field back through Accessibility. `corrections(pasted:observed:)` diffs
/// the tail of the field against what was pasted and picks out one-for-one
/// word swaps: "Shavon" typed over as "Siobhan". Everything else the user
/// might have done — added a sentence, deleted a clause, fixed a comma — is
/// ignored, and so is anything that is not a plain alphabetic word of three
/// letters or more.
///
/// A swap only becomes a vocabulary line once `Pending` has seen it
/// `confirmations` times, so a one-off typo is never learned. Pure
/// Foundation: the caller does the Accessibility reading and the file I/O,
/// and never logs any of the text.
///
/// Known limits, kept on purpose:
/// - The heard word must not be an everyday word (`CommonWords`): a swap
///   like "affect" → "effect" or "Monday" → "Tuesday" is a wording change,
///   and learning it would rewrite every later "affect". A proper noun
///   swapped for another ("Mark" → "Matt") is still learned when the two
///   start with the same letter; the user can delete the line from
///   `vocabulary-learned.txt`.
/// - Case-only edits ("kubernetes" → "Kubernetes") are not learned: the
///   cleaner's own sentence capitalisation would make them noisy.
/// - Two adjacent corrected words are paired by position, so "shavon oh
///   connor" → "Siobhan O'Connor" learns nothing (word counts differ), and a
///   swap that also splits or joins words is missed.
public enum CorrectionLearner {

    public static let minimumWordLength = 3
    /// Sightings before a correction is written to the vocabulary.
    public static let confirmations = 2
    /// Pending entries kept; the least recently seen go first.
    public static let pendingCap = 200
    /// Longest paste (in words) that is diffed; the diff is quadratic.
    public static let maximumWords = 400

    // MARK: - Diff

    /// One-for-one word swaps between `pasted` and the end of `observed`.
    ///
    /// `observed` is the whole value of the field, which may hold text from
    /// before the paste and whatever the user typed after; only a window
    /// around the pasted text's length is compared. At least half of the
    /// pasted words must still be there, in order, or the field is taken to
    /// hold something else entirely and nothing is learned.
    ///
    /// `common` rejects heard words that are everyday English. A paste
    /// longer than `maximumWords` is not diffed at all.
    public static func corrections(pasted: String, observed: String,
                                   common: CommonWords = .basic) -> [Correction] {
        let a = tokens(pasted)
        guard a.count >= 2, a.count <= maximumWords else { return [] }
        let all = tokens(observed)
        let slack = max(4, a.count / 4)
        let b = Array(all.suffix(a.count + slack))

        let anchors = lcs(a.map { $0.lowercased() }, b.map { $0.lowercased() })
        guard anchors.count * 2 >= a.count, !anchors.isEmpty else { return [] }

        var out: [Correction] = []
        var prev = (i: -1, j: -1)
        // A virtual anchor past the end closes the trailing gap.
        for anchor in anchors + [(i: a.count, j: b.count)] {
            let gapA = Array(a[(prev.i + 1)..<anchor.i])
            let gapB = Array(b[(prev.j + 1)..<anchor.j])
            out += pair(gapA, gapB, leading: prev.i < 0, trailing: anchor.i == a.count, common: common)
            prev = anchor
        }
        return out
    }

    /// Pair up the words in a gap. The leading gap may be preceded by text
    /// that was in the field before the paste, so the pasted words align to
    /// the *end* of the observed gap; the trailing gap may be followed by
    /// text typed after, so they align to its *start*. In between, only an
    /// equal-length gap is a swap — anything else is an edit of a different
    /// kind.
    private static func pair(_ a: [String], _ b: [String], leading: Bool, trailing: Bool,
                             common: CommonWords) -> [Correction] {
        guard !a.isEmpty, !b.isEmpty, a.count <= 3, b.count >= a.count else { return [] }
        let bb: [String]
        let aligned = b.count == a.count
        if aligned {
            bb = b
        } else if leading && !trailing {
            bb = Array(b.suffix(a.count))
        } else if trailing && !leading {
            bb = Array(b.prefix(a.count))
        } else {
            return []
        }
        return zip(a, bb).compactMap { heard, correct in
            plausible(heard: heard, correct: correct, aligned: aligned, common: common)
                ? Correction(heard: heard, correct: correct) : nil
        }
    }

    /// Both must be plain words of `minimumWordLength`+ letters that differ
    /// by more than case; the heard word must not be an everyday one (a
    /// real word swapped for another is a change of wording, and a rule
    /// for it would rewrite every later use); and the correction must look
    /// like the same sound — a capitalised name or term with the same first
    /// letter or mostly the same letters, or a lowercase respelling with
    /// both. Where the two words were not paired by position (`aligned`
    /// false: the gap at either end of the paste was longer than what was
    /// pasted, so text from before or after may have been picked up), the
    /// first letter must match whatever the case.
    static func plausible(heard: String, correct: String, aligned: Bool = true,
                          common: CommonWords = .basic) -> Bool {
        guard isWord(heard), isWord(correct) else { return false }
        let h = heard.lowercased(), c = correct.lowercased()
        guard h != c, !common.contains(h), !CommonWords.builtIn.contains(c) else { return false }
        let sameStart = h.first == c.first
        let similar = levenshtein(h, c) <= max(2, h.count / 2)
        if !aligned && !sameStart { return false }
        if correct.first?.isUppercase == true { return sameStart || similar }
        return sameStart && similar
    }

    static func isWord(_ s: String) -> Bool {
        s.count >= minimumWordLength && s.allSatisfy(\.isLetter)
    }

    /// Words split on whitespace, with punctuation stripped from the ends
    /// only ("Siobhan," → "Siobhan"; "O'Connor" stays, and then fails
    /// `isWord`). Empty tokens are dropped.
    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).compactMap { piece in
            let w = piece.trimmingCharacters(in: edgePunctuation)
            return w.isEmpty ? nil : String(w)
        }
    }

    private static let edgePunctuation = CharacterSet.punctuationCharacters.union(.symbols)

    /// Indices of a longest common subsequence, as (i in a, j in b) pairs.
    static func lcs(_ a: [String], _ b: [String]) -> [(i: Int, j: Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var t = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out: [(i: Int, j: Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append((i, j)); i += 1; j += 1
            } else if t[i + 1][j] >= t[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return out
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    // MARK: - Confirmation

    /// Corrections seen once, waiting for a second sighting. Persisted by
    /// the caller (`~/.moe/vocabulary-pending.json`) between dictations.
    public struct Pending: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var correction: Correction
            public var count: Int
            public var lastSeen: Date
        }

        public var entries: [Entry] = []

        public init() {}

        /// Decode; anything unreadable starts over — pending guesses are
        /// not worth failing for.
        public init(data: Data) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            self = (try? d.decode(Pending.self, from: data)) ?? Pending()
        }

        public func data() -> Data {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.sortedKeys]
            return (try? e.encode(self)) ?? Data("{}".utf8)
        }

        /// Count each sighting. A correction whose heard form is already in
        /// `known` (the vocabulary's heard forms, lowercased) is skipped —
        /// the user, or an earlier lesson, already covers it. Returns the
        /// corrections that reached `confirmations`, which leave the
        /// pending list; the same heard word seen twice with different
        /// corrections stays pending under each until one wins.
        @discardableResult
        public mutating func record(_ corrections: [Correction], known: Set<String> = [],
                                    now: Date = Date()) -> [Correction] {
            var promoted: [Correction] = []
            for c in Set(corrections) where !known.contains(c.heard) {
                if let i = entries.firstIndex(where: { $0.correction == c }) {
                    entries[i].count += 1
                    entries[i].lastSeen = now
                    if entries[i].count >= confirmations {
                        promoted.append(c)
                        entries.remove(at: i)
                    }
                } else if confirmations <= 1 {
                    promoted.append(c)
                } else {
                    entries.append(Entry(correction: c, count: 1, lastSeen: now))
                }
            }
            if entries.count > pendingCap {
                entries.sort { $0.lastSeen < $1.lastSeen }
                entries.removeFirst(entries.count - pendingCap)
            }
            return promoted.sorted { $0.heard < $1.heard }
        }
    }
}
