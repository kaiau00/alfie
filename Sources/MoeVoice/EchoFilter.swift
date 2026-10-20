import Foundation

/// Is this transcript Moe hearing itself? VOICE-PLAN.md §4.4.
///
/// The canceller removes most of Moe's voice from the microphone, but not
/// all of it, and not at all on a mismatched device pair. When a barge-in
/// captures a fragment and the accurate model reads it back as words Moe
/// was just saying, that is not an interruption. Character-level
/// similarity against the recently spoken text, whole and windowed, so a
/// short fragment from the middle of a long reply still matches.
public enum EchoFilter {

    /// True when `transcript` reads like a piece of `spoken`.
    ///
    /// - Parameters:
    ///   - threshold: similarity ratio (0…1) at or above which it is echo.
    ///   - minFragment: shorter transcripts skip the windowed check — a
    ///     two-word interjection matches *something* in any long reply.
    public static func isEcho(_ transcript: String, of spoken: String,
                              threshold: Double = 0.8, minFragment: Int = 12) -> Bool {
        let a = normalise(transcript), b = normalise(spoken)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if similarity(a, b) >= threshold { return true }
        guard a.count >= minFragment, a.count < b.count else { return false }
        let bc = Array(b), ac = Array(a)
        // Slide a window the size of the transcript across the spoken text.
        var start = 0
        let step = max(1, ac.count / 4)
        while start + ac.count <= bc.count {
            if similarity(ac, Array(bc[start..<(start + ac.count)])) >= threshold { return true }
            start += step
        }
        return false
    }

    /// The best similarity of `transcript` to any stretch of `spoken` of
    /// its own length — with no minimum length, because what arrives over
    /// a reply before it is paused is one or two words, exactly the size
    /// the windowed check in `isEcho` skips. For the judge before the pause
    /// (`BargeInJudge`), measured against the words playing now rather
    /// than the whole reply, so a short fragment cannot match *something*
    /// in a long answer.
    public static func windowSimilarity(_ transcript: String, _ spoken: String) -> Double {
        let a = Array(normalise(transcript)), b = Array(normalise(spoken))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        guard a.count < b.count else { return similarity(a, b) }
        var best = 0.0
        var start = 0
        let step = max(1, a.count / 4)
        while start + a.count <= b.count {
            best = max(best, similarity(a, Array(b[start..<(start + a.count)])))
            start += step
        }
        best = max(best, similarity(a, Array(b.suffix(a.count))))
        return best
    }

    static func normalise(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N} ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        similarity(Array(a), Array(b))
    }

    /// 2·matches / (len a + len b), with matches from the longest common
    /// subsequence — the same shape of number difflib's ratio gives.
    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return 2 * Double(prev[b.count]) / Double(a.count + b.count)
    }
}
