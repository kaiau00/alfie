import Testing
@testable import MoeVoice

/// M1: priming the recogniser without racing live audio.
struct AsrPrimerTests {

    @Test func itFeedsExactlyWhatHasNotBeenFed() {
        // Primed from 8000; 12000 ingested so far: 4000 to feed.
        #expect(AsrPrimer.catchUp(fedThrough: 8_000, ingested: 12_000, available: 40_000) == 4_000)
        // Frames arrived while it was feeding: the next pass takes only them.
        #expect(AsrPrimer.catchUp(fedThrough: 12_000, ingested: 12_512, available: 40_000) == 512)
        // Caught up: nothing, and the recogniser can be switched on.
        #expect(AsrPrimer.catchUp(fedThrough: 12_512, ingested: 12_512, available: 40_000) == 0)
        // Never more than the pre-roll holds.
        #expect(AsrPrimer.catchUp(fedThrough: 0, ingested: 90_000, available: 40_000) == 40_000)
    }
}
