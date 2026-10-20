import Foundation
import Testing
@testable import MoeVoice

struct WakePolicyTests {

    /// `#expect` cannot hold a mutating call; run the scores first.
    private func fires(_ p: inout WakePolicy, _ scores: [(Float, Double)]) -> [Bool] {
        scores.map { p.observe(score: $0.0, at: $0.1) }
    }

    @Test func oneHitIsAGuessARunIsADetection() {
        var p = WakePolicy(threshold: 0.5, requiredHits: 2)
        #expect(fires(&p, [(0.6, 0.00), (0.6, 0.08)]) == [false, true])
        var four = WakePolicy(threshold: 0.5, requiredHits: 4)
        #expect(fires(&four, [(0.6, 0.00), (0.6, 0.08), (0.6, 0.16), (0.6, 0.24)]) == [false, false, false, true])
    }

    @Test func aPartialPhraseThatFadesNeverFires() {
        // LiveKit's negative fixture through a rolling window: four windows
        // over 0.5 while only its first second is inside, then it falls.
        var p = WakePolicy(threshold: 0.5, requiredHits: 5)
        let trace: [(Float, Double)] = [(0.37, 0.98), (0.79, 1.08), (0.88, 1.14), (0.73, 1.24), (0.63, 1.30), (0.33, 1.40), (0.16, 1.46)]
        #expect(!fires(&p, trace).contains(true))
    }

    @Test func anEmphaticWindowFiresAlone() {
        var p = WakePolicy(threshold: 0.5, requiredHits: 3)
        #expect(fires(&p, [(0.9, 0)]) == [false])
        #expect(fires(&p, [(0.96, 1)]) == [true])
    }

    @Test func aMissBetweenHitsBreaksTheRun() {
        var p = WakePolicy(threshold: 0.5)
        #expect(fires(&p, [(0.6, 0.00), (0.2, 0.08), (0.6, 0.16), (0.6, 0.24)]) == [false, false, false, true])
    }

    @Test func hitsFarApartAreNotConsecutive() {
        // The VAD gated the head off in between: two unrelated windows.
        var p = WakePolicy(threshold: 0.5)
        #expect(fires(&p, [(0.6, 0.0), (0.6, 1.0), (0.6, 1.08)]) == [false, false, true])
    }

    @Test func afterADetectionTheHeadIsIgnoredForAWhile() {
        var p = WakePolicy(threshold: 0.5, refractorySeconds: 2)
        #expect(fires(&p, [(0.95, 0), (0.95, 0.08), (0.95, 1.9), (0.95, 2.1)]) == [true, false, false, true])
    }

    @Test func theStrongThresholdDefaultsHigh() {
        let p = WakePolicy(threshold: 0.68)
        #expect(p.strongThreshold == 0.95)
        let higher = WakePolicy(threshold: 0.97)
        #expect(higher.strongThreshold == 0.97)
        let explicit = WakePolicy(threshold: 0.5, strongThreshold: 0.8)
        #expect(explicit.strongThreshold == 0.8)
        #expect(WakePolicy(requiredHits: 0).requiredHits == 1)
        // A sidecar strong at or below the threshold would make every hit
        // fire: ignored, the default stands. At or above 1: never.
        let below = WakePolicy(threshold: 0.6, strongThreshold: 0.4, requiredHits: 3)
        #expect(below.strongThreshold == 0.95)
        var never = WakePolicy(threshold: 0.5, strongThreshold: 1.01, requiredHits: 3)
        #expect(fires(&never, [(0.999, 0), (0.999, 0.08)]) == [false, false])
    }

    @Test func resetForgetsTheRunButNotTheRefractory() {
        var p = WakePolicy(threshold: 0.5)
        _ = fires(&p, [(0.6, 5)])
        p.reset()
        #expect(fires(&p, [(0.6, 5.08)]) == [false])
        // Fired, then the head switched off and on within the refractory:
        // the phrase is still in the window and must not fire twice.
        var q = WakePolicy(threshold: 0.5)
        _ = fires(&q, [(0.96, 0)])
        q.reset()
        #expect(fires(&q, [(0.96, 0.5)]) == [false])
        #expect(fires(&q, [(0.96, 2.5)]) == [true])
    }
}
