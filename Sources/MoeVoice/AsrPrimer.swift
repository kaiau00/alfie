import Foundation

/// Priming the streaming recogniser with the moment before a VAD onset,
/// without racing the live audio (review M1, 2026-09-22).
///
/// The first cut switched the recogniser on and then fed it the pre-roll
/// across several `await`s — and the audio actor is re-entrant, so live
/// frames were fed *between* the primed ones, out of order, in exactly the
/// half-second that holds the "stop". The rule now: the recogniser stays
/// off for live frames while it is primed; the primer feeds from the
/// pre-roll by absolute sample position until it has caught up with
/// everything ingested, and only then is it switched on — with no
/// suspension between the last catch-up check and the switch.
public enum AsrPrimer {

    /// How many samples from the end of the pre-roll to feed next.
    ///
    /// - Parameters:
    ///   - fedThrough: the absolute sample position fed so far.
    ///   - ingested: the absolute position of the newest sample ingested.
    ///   - available: how many samples the pre-roll holds now.
    public static func catchUp(fedThrough: Int, ingested: Int, available: Int) -> Int {
        max(0, min(ingested - fedThrough, available))
    }
}
