import Foundation

/// What a streaming cloud voice is handed at once.
///
/// Moe used to send the premium voice one sentence at a time — the first
/// often half a sentence, cut at a comma — each with its own flush, so each
/// was generated on its own with no look-ahead: prosody reset every
/// sentence, the fragment got end-of-utterance intonation, and at
/// temperature 1.0 the voice drifted between them (the owner: "sounds
/// weird"). A local engine needs sentence-sized pieces (Kokoro rejects past
/// ~510 phonemes); a streaming server does better with the paragraph.
///
/// So when a render starts, everything already queued behind it goes in
/// the same request, up to `limit` characters. After the first sentence
/// the brain writes faster than Moe speaks, so the queue is usually a few
/// sentences deep by then and they are spoken as one passage.
public enum SpeechBatch {

    public struct Piece: Equatable, Sendable {
        public let text: String
        public let replyEnd: Int?
        public init(text: String, replyEnd: Int?) { self.text = text; self.replyEnd = replyEnd }
    }

    /// Inworld accepts 2,000 characters a request; well under it, so one
    /// render is never so long that a stop or an error loses much.
    public static let cloudLimit = 600

    /// The batch's pieces, in order, so what was *heard* can still be
    /// tracked sentence by sentence inside one render (review M4).
    public static func take(parts queue: [Piece], limit: Int = cloudLimit) -> [Piece] {
        guard let batch = take(queue, limit: limit) else { return [] }
        return Array(queue.prefix(batch.count))
    }

    /// Where each part of a rendered batch ends in the player's sample
    /// count: proportional to its characters, the last exactly at the end.
    /// Speech runs at a near-even rate per character, so this is close to
    /// where each sentence's audio really ends — far closer than calling
    /// the whole passage unheard until its last sample.
    public static func partEnds(start: Int, total: Int, lengths: [Int]) -> [Int] {
        let chars = lengths.reduce(0, +)
        guard !lengths.isEmpty else { return [] }
        guard chars > 0 else { return lengths.map { _ in start + total } }
        var cum = 0
        return lengths.enumerated().map { i, n in
            cum += n
            if i == lengths.count - 1 { return start + total }
            return start + Int((Double(total) * Double(cum) / Double(chars)).rounded())
        }
    }

    /// A batch the cloud failed on, re-rendered on the local engine: back in
    /// pieces it can take. Kokoro produces *no audio at all* past ~510
    /// phonemes, and a 600-character passage is past that (review H2), so a
    /// socket dropping mid-reply silently lost a paragraph.
    public static func forLocalEngine(_ parts: [Piece], limit: Int = 180) -> [Piece] {
        parts.flatMap { part -> [Piece] in
            let chunks = SentenceSplitter.chunk(part.text, limit: limit)
            guard !chunks.isEmpty else { return [] }
            return chunks.enumerated().map { i, c in
                Piece(text: c, replyEnd: i == chunks.count - 1 ? part.replyEnd : nil)
            }
        }
    }

    /// How many pieces from the front of `queue` to send as one render, and
    /// what that render is. Always at least one piece, whatever its size.
    /// The batch ends where its last piece that has one ends (a long piece
    /// is split for the synthesiser and only its last part carries the
    /// offset); an aside is only ever spoken when nothing else is queued.
    public static func take(_ queue: [Piece], limit: Int = cloudLimit) -> (count: Int, piece: Piece)? {
        guard let first = queue.first else { return nil }
        var text = first.text
        var end = first.replyEnd
        var n = 1
        while n < queue.count {
            let next = queue[n]
            guard text.count + 1 + next.text.count <= limit else { break }
            text += " " + next.text
            if let e = next.replyEnd { end = e }
            n += 1
        }
        return (n, Piece(text: text, replyEnd: end))
    }
}
