import Foundation

/// Turns a stream of reply text into things worth saying.
///
/// The brain writes faster than Moe speaks after the first sentence, and
/// slower before it. So the first thing spoken may break at a clause once
/// there is enough of it, and everything after waits for a full stop. A
/// synthesiser given two-word fragments produces two-word prosody; given a
/// whole paragraph it produces a long silence first. This is the middle.
public enum SentenceSplitter {

    /// Split off one complete sentence from the front of `buf`, keeping
    /// its trailing space so offsets stay exact. Nil when nothing complete
    /// is there yet.
    ///
    /// Only breaks on a terminator it can see past: mid-stream a chunk can
    /// end at "It's 3." with the "5" still on its way, and breaking there
    /// gave "It's three." then "five degrees out". The true end of a reply
    /// is spoken by the caller's remainder pass, so nothing is lost by
    /// waiting for one more character.
    ///
    /// - Parameter orClause: also break at a comma, dash, colon or
    ///   semicolon once `minFirst` characters are in — for the first thing
    ///   spoken in a reply, where it is the difference between Moe starting
    ///   to talk and Moe waiting.
    public static func popSentence(_ buf: inout String, orClause: Bool = false,
                                   minFirst: Int = 30) -> String? {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        let clauseBreaks: Set<Character> = [",", ";", ":", "—", "–"]

        var idx = buf.startIndex
        var seen = 0
        while idx < buf.endIndex {
            let c = buf[idx]
            let longEnough = !orClause || seen >= minFirst
            let isTerminator = longEnough && terminators.contains(c)
            let isClause = orClause && seen >= minFirst && clauseBreaks.contains(c)
            if isTerminator || isClause {
                let next = buf.index(after: idx)
                // "3.5" and "1,200" are not the end of anything.
                if next < buf.endIndex, buf[next].isNumber { idx = next; seen += 1; continue }
                if next < buf.endIndex, buf[next].isWhitespace {
                    let cut = buf.index(after: next)
                    let s = String(buf[buf.startIndex..<cut])
                    buf = String(buf[cut...])
                    return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
                }
            }
            idx = buf.index(after: idx)
            seen += 1
        }
        return nil
    }

    /// Split a long piece into chunks a synthesiser will accept.
    ///
    /// Kokoro rejects utterances beyond roughly 510 phonemes, and a rejected
    /// chunk simply produced no audio — which is why Moe used to stop
    /// mid-reply. Sentence boundaries first, then commas, then hard.
    public static func chunk(_ text: String, limit: Int = 180) -> [String] {
        guard text.count > limit else { return [text] }
        var out: [String] = []
        var current = ""
        for sentence in sentences(of: text) {
            if current.count + sentence.count + 1 <= limit {
                current += current.isEmpty ? sentence : " \(sentence)"
            } else {
                if !current.isEmpty { out.append(current) }
                if sentence.count <= limit {
                    current = sentence
                } else {
                    var rest = Substring(sentence)
                    while rest.count > limit {
                        if let comma = rest.prefix(limit).lastIndex(of: ",") {
                            out.append(String(rest[...comma]).trimmingCharacters(in: .whitespaces))
                            rest = rest[rest.index(after: comma)...]
                        } else {
                            // A hard cut keeps every character.
                            let cut = rest.index(rest.startIndex, offsetBy: limit)
                            out.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
                            rest = rest[cut...]
                        }
                    }
                    current = String(rest).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Sentences with their own terminators kept — a question stays a
    /// question — and "3.5" left alone.
    static func sentences(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            let isEnd: Bool
            if c == "\n" {
                isEnd = true
            } else if ".!?".contains(c) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                isEnd = !next.isNumber
            } else {
                isEnd = false
            }
            if isEnd {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                // "Wait..." is one sentence, not "Wait." and two dots.
                if s.contains(where: { $0.isLetter || $0.isNumber }) {
                    out.append(s)
                    current = ""
                } else if let last = out.indices.last {
                    out[last] += s
                    current = ""
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
