import Foundation
import Testing
@testable import MoeVoice

/// The per-Mac threshold picker, over score traces — the pure half of
/// Settings › Voice › "Teach Moe its name". The traces here are the shape
/// the pipeline's probe reports: one score every 80 ms while the VAD
/// hears speech.
struct WakeCalibrationTests {

    typealias S = WakeCalibration.Sample

    /// The shipped sidecar: threshold 0.95, strong 0.95, two hits.
    let shipped = WakePolicy(threshold: 0.95, strongThreshold: 0.95, requiredHits: 2)

    /// A clip whose scores climb to `peak` over five windows and fall away.
    func clip(peak: Float) -> [S] {
        let shape: [Float] = [0.2, 0.5, 0.8, 1.0, 0.9, 0.6, 0.2]
        return shape.enumerated().map { S(time: 2.0 + Double($0.offset) * 0.08, score: $0.element * peak) }
    }

    @Test func aTraceFiresTheWayThePipelineWould() {
        // Two consecutive windows at or over the threshold, or one strong one.
        #expect(WakeCalibration.fires(clip(peak: 0.96), policy: shipped))
        #expect(!WakeCalibration.fires(clip(peak: 0.90), policy: shipped))
        #expect(WakeCalibration.fires(clip(peak: 0.90), policy: shipped.withThreshold(0.8)))
        // Every clip is judged from quiet: a policy mid-run from the last
        // clip must not carry a hit across.
        var used = shipped.withThreshold(0.8)
        _ = used.observe(score: 0.85, at: 1.0)
        #expect(!WakeCalibration.fires([S(time: 1.05, score: 0.85)], policy: used))
    }

    @Test func picksTheThresholdThatKeepsTheNearMissesOutAndCatchesTheMost() {
        // Three "Hey Moe"s peaking at 0.96, 0.88 and 0.80; two near misses
        // peaking at 0.70 and 0.60. Shipped catches one. Any threshold in
        // (0.70, 0.80] catches all three and none of the misses; the pick
        // is the highest of those.
        let positives = [clip(peak: 0.96), clip(peak: 0.88), clip(peak: 0.80)]
        let confusables = [clip(peak: 0.70), clip(peak: 0.60)]
        let pick = WakeCalibration.pick(positives: positives, confusables: confusables,
                                        shipped: shipped, current: shipped)
        #expect(pick != nil)
        guard let pick else { return }
        #expect(pick.before == .init(positives: 3, caught: 1, confusables: 2, falseAccepts: 0))
        #expect(pick.after == .init(positives: 3, caught: 3, confusables: 2, falseAccepts: 0))
        // 0.80 × 0.9 (the window after the peak) is 0.71999997 in Float:
        // two windows at or over 0.71 fire; 0.72 leaves one window and
        // misses the third clip.
        #expect(pick.threshold == 0.71)
        // The pick fires on all three and on neither near miss when replayed.
        let chosen = shipped.withThreshold(pick.threshold)
        #expect(positives.allSatisfy { WakeCalibration.fires($0, policy: chosen) })
        #expect(!confusables.contains { WakeCalibration.fires($0, policy: chosen) })
    }

    @Test func fewestFalseAcceptsBeatsMoreRecall() {
        // A near miss that peaks at 0.90 is above every positive but one.
        // Catching the other two positives means letting it in; the picker
        // does not, and keeps the one clean catch it started with.
        let positives = [clip(peak: 0.96), clip(peak: 0.85), clip(peak: 0.85)]
        let confusables = [clip(peak: 0.90)]
        let pick = WakeCalibration.pick(positives: positives, confusables: confusables,
                                        shipped: shipped, current: shipped)!
        #expect(pick.after.falseAccepts == 0)
        #expect(pick.after.caught == 1)
        #expect(pick.threshold >= 0.91)
    }

    @Test func aHigherThresholdCanBePickedWhenTheShippedOneMisfires() {
        // A near miss firing at the shipped threshold, and a strong
        // positive: the way out is up, not down.
        let positives = [clip(peak: 0.99)]
        let confusables = [clip(peak: 0.96)]
        let pick = WakeCalibration.pick(positives: positives, confusables: confusables,
                                        shipped: shipped, current: shipped)!
        #expect(pick.before.falseAccepts == 1)
        #expect(pick.after.falseAccepts == 0)
        #expect(pick.after.caught == 1)
        #expect(pick.threshold > 0.95)
    }

    @Test func neverAStepBackwardsOnTheClipsItMeasured() {
        // The threshold in force is always a candidate, even when it is
        // not on the hundredths grid.
        let current = shipped.withThreshold(0.855)
        let positives = [clip(peak: 0.96), clip(peak: 0.95)]
        let pick = WakeCalibration.pick(positives: positives, confusables: [],
                                        shipped: shipped, current: current, candidates: [0.99])!
        #expect(pick.after.caught >= pick.before.caught)
        #expect(pick.threshold == 0.855)
    }

    @Test func neverFewerOfYourOwnThanNow() {
        // The shape `Moe --wake-pick` showed on synthesised voices: most of
        // the names fire where the shipped head sits, a few never will, and
        // four near misses score as high as the names do. "Fewest false
        // accepts first" on its own walks up to 0.99 here, where one near
        // miss is left and not one name. The floor stops at the highest
        // threshold that still catches the eight it had.
        //
        // With `strong` at 0.95, one window at or over the threshold fires
        // once the threshold is 0.95 or more, so a clip peaking at 0.985
        // fires up to 0.98 and not at 0.99.
        let positives = Array(repeating: clip(peak: 0.985), count: 8) + Array(repeating: clip(peak: 0.40), count: 4)
        let confusables = [0.01, 0.46, 0.965, 0.99, 0.08, 0.28, 0.975, 0.96].map { clip(peak: Float($0)) }
        let pick = WakeCalibration.pick(positives: positives, confusables: confusables,
                                        shipped: shipped, current: shipped)!
        #expect(pick.before == .init(positives: 12, caught: 8, confusables: 8, falseAccepts: 4))
        #expect(pick.after == .init(positives: 12, caught: 8, confusables: 8, falseAccepts: 1))
        #expect(pick.threshold == 0.98)
        #expect(WakeCalibration.summary(pick, changed: true)
                == "Moe now catches 8 of 12 of your “Hey Moe”s and 1 of the 8 near misses. Before: 8 of 12 and 4.")
        // The answer the floor exists to refuse: nothing reaches 0.99 but
        // one near miss.
        let degenerate = WakeCalibration.tally(positives: positives, confusables: confusables,
                                               policy: shipped.withThreshold(0.99))
        #expect(degenerate == .init(positives: 12, caught: 0, confusables: 8, falseAccepts: 1))
    }

    @Test func aThresholdThatCatchesNothingIsNotAnAnswer() {
        // Every name below every near miss: no threshold helps, and the
        // one that "fixes" the near misses by hearing nothing is refused.
        // Whatever catches a name here lets both near misses in.
        let positives = [clip(peak: 0.6), clip(peak: 0.55)]
        let confusables = [clip(peak: 0.9), clip(peak: 0.8)]
        let pick = WakeCalibration.pick(positives: positives, confusables: confusables,
                                        shipped: shipped, current: shipped)!
        #expect(pick.before.caught == 0)
        #expect(pick.after.caught >= 1)
        #expect(pick.after.falseAccepts == 2)
    }

    @Test func nothingToMeasureIsNil() {
        // No clip any threshold catches: nil, not a pick of nothing.
        #expect(WakeCalibration.pick(positives: [clip(peak: 0.3)], confusables: [],
                                     shipped: shipped, current: shipped) == nil)
        #expect(WakeCalibration.pick(positives: [], confusables: [clip(peak: 0.5)],
                                     shipped: shipped, current: shipped) == nil)
    }

    @Test func aHeadThatShipsLowIsTunedFromItsOwnNumber() {
        // v6 (2026-09-23) ships at 0.28 with three hits and its scores stop
        // near 0.85. Under the old fixed floor of 0.5 every candidate caught
        // fewer of the owner's names than 0.28 did, so the pick was always
        // "nothing changed". Here a near miss peaking at 0.40 fires at the
        // shipped 0.28; the way out is a little up, and it must be allowed.
        let v6 = WakePolicy(threshold: 0.28, strongThreshold: 1.01, requiredHits: 3)
        #expect(WakeCalibration.lowestThreshold(for: v6) == 0.28)
        #expect(WakeCalibration.lowestThreshold(for: shipped) == 0.5)
        let positives = [clip(peak: 0.80), clip(peak: 0.70), clip(peak: 0.60)]
        let confusables = [clip(peak: 0.40)]
        let pick = WakeCalibration.pick(positives: positives, confusables: confusables,
                                        shipped: v6, current: v6)!
        #expect(pick.before.falseAccepts == 1)
        #expect(pick.after.falseAccepts == 0)
        #expect(pick.after.caught == 3)
        #expect(pick.threshold > 0.28 && pick.threshold < 0.5)
        // Never below the shipped number, however clean the clips are.
        let clean = WakeCalibration.pick(positives: [clip(peak: 0.3)], confusables: [],
                                         shipped: v6, current: v6)
        #expect((clean?.threshold ?? 0.28) >= 0.28)
    }

    @Test func aThresholdOnlyAppliesToTheHeadItWasMeasuredOn() {
        // v5's per-Mac 0.9 on v6 would have silenced the wake word.
        #expect(WakeCalibration.tuningApplies(tunedFor: "2026-09-23", head: "2026-09-23"))
        #expect(!WakeCalibration.tuningApplies(tunedFor: "2026-09-06", head: "2026-09-23"))
        // A file from before tunings named their head applies to no head that has a name.
        #expect(!WakeCalibration.tuningApplies(tunedFor: nil, head: "2026-09-23"))
        #expect(WakeCalibration.tuningApplies(tunedFor: nil, head: nil))
    }

    @Test func theSentence() {
        let pick = WakeCalibration.Pick(threshold: 0.8,
                                        after: .init(positives: 12, caught: 11, confusables: 8, falseAccepts: 0),
                                        before: .init(positives: 12, caught: 8, confusables: 8, falseAccepts: 2))
        #expect(WakeCalibration.summary(pick, changed: true)
                == "Moe now catches 11 of 12 of your “Hey Moe”s and none of the 8 near misses. Before: 8 of 12 and 2.")
        let same = WakeCalibration.Pick(threshold: 0.95,
                                        after: .init(positives: 12, caught: 12, confusables: 8, falseAccepts: 1),
                                        before: .init(positives: 12, caught: 12, confusables: 8, falseAccepts: 1))
        #expect(WakeCalibration.summary(same, changed: false)
                == "Moe already catches all 12 of your “Hey Moe”s and 1 of the 8 near misses — the setting it had is the best one for this Mac, so nothing changed.")
        let one = WakeCalibration.Pick(threshold: 0.8,
                                       after: .init(positives: 1, caught: 1, confusables: 1, falseAccepts: 0),
                                       before: .init(positives: 1, caught: 0, confusables: 1, falseAccepts: 0))
        #expect(WakeCalibration.summary(one, changed: true)
                == "Moe now catches 1 of 1 of your “Hey Moe” and none of the 1 near miss. Before: 0 of 1 and none.")
    }
}
