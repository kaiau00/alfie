import Testing
@testable import MoeVoice

/// Item 6c of the 2026-09-22 premium-voice audit: the premium voice was sent
/// one sentence (or half-sentence) per flushed request, so every sentence was
/// generated on its own.
struct SpeechBatchTests {

    private func p(_ t: String, _ e: Int? = nil) -> SpeechBatch.Piece { .init(text: t, replyEnd: e) }

    @Test func whatIsQueuedGoesAsOnePassage() {
        let q = [p("It is sunny.", 12), p("Highs of twenty.", 29), p("Take a hat.", 41)]
        let b = SpeechBatch.take(q)
        #expect(b?.count == 3)
        #expect(b?.piece == p("It is sunny. Highs of twenty. Take a hat.", 41))
    }

    @Test func aLongPieceSplitForTheSynthesiserKeepsItsOffset() {
        let q = [p("First half of a long sentence,"), p("and the rest of it.", 50)]
        #expect(SpeechBatch.take(q)?.piece.replyEnd == 50)
    }

    @Test func theLimitStopsTheBatchAtAPieceBoundary() {
        let long = String(repeating: "a", count: 400)
        let q = [p(long, 400), p(long, 801), p("end.", 806)]
        let b = SpeechBatch.take(q, limit: 600)
        #expect(b?.count == 1)
        #expect(b?.piece.replyEnd == 400)
    }

    @Test func aPieceOverTheLimitStillGoes() {
        let long = String(repeating: "a", count: 900)
        #expect(SpeechBatch.take([p(long, 900)], limit: 600)?.count == 1)
        #expect(SpeechBatch.take([]) == nil)
    }
}

/// The review of the batching (2026-09-22): H2 and M4.
struct SpeechBatchFixTests {

    private func p(_ t: String, _ e: Int? = nil) -> SpeechBatch.Piece { .init(text: t, replyEnd: e) }

    /// H2: a batch the cloud failed on goes to Kokoro in pieces it accepts.
    @Test func theLocalFallbackGetsSentenceSizedPieces() {
        let sentence = "This is a sentence of a reasonable length for a reply. "
        let long = String(repeating: sentence, count: 10)           // ~550 chars
        let parts = SpeechBatch.forLocalEngine([p(long, 550)])
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.text.count <= 180 })
        #expect(parts.last?.replyEnd == 550)
        #expect(parts.dropLast().allSatisfy { $0.replyEnd == nil })
        // Each original part keeps its own offset.
        let two = SpeechBatch.forLocalEngine([p("One.", 4), p("Two.", 9)])
        #expect(two.map(\.replyEnd) == [4, 9])
    }

    /// M4: what was heard advances sentence by sentence inside a passage.
    @Test func eachSentenceOfABatchEndsWhereItsShareOfTheAudioEnds() {
        let ends = SpeechBatch.partEnds(start: 1_000, total: 3_000, lengths: [10, 20, 30])
        #expect(ends == [1_500, 2_500, 4_000])
        #expect(SpeechBatch.partEnds(start: 0, total: 100, lengths: [0, 0]) == [100, 100])
        #expect(SpeechBatch.partEnds(start: 0, total: 100, lengths: []).isEmpty)
        let parts = SpeechBatch.take(parts: [p("a.", 2), p("b.", 5), p("c.", 8)])
        #expect(parts.count == 3)
    }
}
