import Foundation

/// A failed turn, as one sentence Moe can say out loud.
///
/// On 2026-09-25 at 16:49 the person asked Moe something by voice, the
/// account had hit its weekly limit, and Moe said nothing at all: the error
/// went into the chat, the listening window opened as if it had answered,
/// and the person was left talking to silence — three times in two minutes
/// (`~/moe-voice-notes/audit-2026-09-29/audit-other.md` §7). The written
/// line stays as it was; this is the spoken half.
enum SpokenError {

    /// The error in a sentence short enough to hear: the engine's own prefix
    /// ("claude turn failed:") dropped, a time zone in brackets dropped, the
    /// "·" the provider uses between clauses read as a full stop, and cut at
    /// the first sentence past `limit`.
    static func line(for message: String, limit: Int = 160) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = text.range(of: "turn failed:") {
            text = String(text[colon.upperBound...])
        }
        text = text.replacingOccurrences(of: #"\s*\([A-Za-z_]+/[A-Za-z_/]+\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: " · ", with: ". ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Something went wrong and I couldn't answer that." }
        if text.count > limit {
            let head = String(text.prefix(limit))
            if let end = head.lastIndex(where: { ".!?".contains($0) }) {
                text = String(head[...end])
            } else {
                text = head + "…"
            }
        }
        // Every sentence starts with a capital, including the ones "·" made.
        text = text.components(separatedBy: ". ").map { part in
            guard let first = part.first, first.isLowercase else { return part }
            return first.uppercased() + part.dropFirst()
        }.joined(separator: ". ")
        if let last = text.last, !".!?…".contains(last) { text += "." }
        return "I couldn't answer that. " + text
    }
}
