import Foundation

/// Applying word-level spelling corrections to a timed token stream.
///
/// The vocabulary boost works in text — it reads a transcript, finds acoustic
/// evidence for a name under a word the recogniser mangled, and hands back
/// word pairs ("LiveMarley" → "Livmarli"). A meeting is not text: it is a
/// stream of subword tokens whose *times* drive speaker attribution, the
/// hallucination filter and the whole timeline. Taking the boost's rewritten
/// string and throwing the tokens away would fix the spelling and break
/// everything built on the clock.
///
/// So the correction is applied to the tokens instead. A word may span
/// several tokens ("▁Live", "Mar", "ley"); the replacement goes on the first
/// of them and the rest are emptied, which keeps one token per original
/// position and leaves every timestamp exactly where it was. An emptied token
/// contributes nothing when `Timeline.segments` concatenates, and still
/// covers its own stretch of audio for the segment-has-speech check.
///
/// Deliberately conservative: only whole words, only where the word matches a
/// correction the boost actually asked for, and the first occurrence of each
/// correction per call. A vocabulary fix that silently reshapes a meeting
/// transcript would be far worse than a name spelled wrong.
public enum TokenRewrite {

    /// What marks the start of a word.
    ///
    /// SentencePiece writes U+2581, but FluidAudio has already turned that
    /// into a plain leading space by the time token timings come back. Learned
    /// the hard way: the first version of this file assumed U+2581, matched
    /// nothing at all, and silently treated a whole meeting window as one
    /// enormous "word" — no crash, no warning, just a correction that never
    /// applied. Both forms are accepted now: the space because that is what
    /// actually arrives, and the raw mark in case an engine ever hands it over
    /// untouched.
    static let wordMarks: Set<Character> = ["\u{2581}", " "]

    /// The word-start mark `piece` carries, or nil when it continues a word.
    static func mark(of piece: String) -> String? {
        guard let first = piece.first, wordMarks.contains(first) else { return nil }
        return String(first)
    }

    /// `replacements` are heard-form → canonical-form, as the rescorer found
    /// them. Returns the stream unchanged when nothing matches.
    public static func apply(_ replacements: [(from: String, to: String)],
                             to tokens: [TimedToken]) -> [TimedToken] {
        guard !replacements.isEmpty, !tokens.isEmpty else { return tokens }

        // Heard form (folded) → canonical. Folded so "LiveMarley," in the
        // stream matches "LiveMarley" from the rescorer.
        var wanted: [String: String] = [:]
        for r in replacements where !r.from.isEmpty && !r.to.isEmpty {
            wanted[fold(r.from), default: r.to] = r.to
        }
        guard !wanted.isEmpty else { return tokens }

        var out = tokens
        for span in words(in: tokens) {
            guard let canonical = wanted[fold(span.text)] else { continue }
            // Each correction fires once: the rescorer reports a replacement
            // per position it found, and applying one everywhere would rewrite
            // occurrences it deliberately left alone.
            wanted.removeValue(forKey: fold(span.text))
            // The leading mark is part of the stream's spacing, not the word,
            // so it has to survive the replacement.
            let lead = mark(of: tokens[span.range.lowerBound].token) ?? ""
            out[span.range.lowerBound].token = lead + canonical + span.trailing
            for i in (span.range.lowerBound + 1)..<span.range.upperBound {
                out[i].token = ""
            }
        }
        return out
    }

    /// One whole word and the tokens it occupies.
    struct WordSpan {
        let text: String
        /// Punctuation that followed the word, kept so replacing "Anwin," does
        /// not eat the comma.
        let trailing: String
        let range: Range<Int>
    }

    /// The words in a token stream, each with the token range it spans.
    static func words(in tokens: [TimedToken]) -> [WordSpan] {
        var out: [WordSpan] = []
        var current = ""
        var start = 0

        func flush(end: Int) {
            guard !current.isEmpty, start < end else { current = ""; return }
            let trailing = String(current.reversed().prefix { $0.isPunctuation }.reversed())
            let bare = String(current.dropLast(trailing.count))
            if !bare.isEmpty { out.append(WordSpan(text: bare, trailing: trailing, range: start..<end)) }
            current = ""
        }

        for (i, tok) in tokens.enumerated() {
            let piece = tok.token
            if piece.isEmpty { continue }
            if mark(of: piece) != nil {
                flush(end: i)
                start = i
                current = String(piece.dropFirst())
            } else if current.isEmpty {
                start = i
                current = piece
            } else {
                current += piece
            }
        }
        flush(end: tokens.count)
        return out
    }

    /// Case-folded and stripped of punctuation, for matching only.
    static func fold(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'"
        })
    }
}
