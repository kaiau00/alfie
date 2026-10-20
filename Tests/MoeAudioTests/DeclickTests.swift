import Foundation
import Testing
@testable import MoeAudio

/// A filter that rewrites samples in Moe's own voice, so the tests that
/// matter are the ones about restraint: what it must not touch.
///
/// Real speech is the hard case. A plosive is a fast attack — a /t/ or a /k/
/// burst rises in a couple of samples — and an earlier, looser version of
/// this detector called 1,185 of them "clicks" in one passage. Nothing here
/// is worth having if it smooths consonants.
struct DeclickTests {

    private static let rate: Double = 24_000

    /// A 200 Hz tone at a comfortable level: band-limited, like speech.
    private func tone(_ samples: Int, freq: Double = 200, amp: Float = 0.3) -> [Float] {
        (0..<samples).map {
            amp * Float(sin(2 * Double.pi * freq * Double($0) / Self.rate))
        }
    }

    /// The pass ships **off** (`Declick.passes == 0`) because it made Kokoro
    /// scratchy — see the notes in `Declick`. These tests are about the
    /// algorithm, so they ask for it by name.
    private static let testPasses = 4

    private func repaired(_ input: [Float]) -> (out: [Float], count: Int) {
        var s = input
        let n = Declick.repair(&s, sampleRate: Self.rate, passes: Self.testPasses)
        return (s, n)
    }

    @Test func itIsOffByDefault() {
        var input = tone(4_800)
        input[2_400] = 0.95
        let untouched = input
        let n = Declick.repair(&input, sampleRate: Self.rate)
        #expect(n == 0, "the de-click must not run unless asked for")
        #expect(input == untouched)
    }

    // MARK: - What it must remove

    @Test func aSingleSampleSpikeIsRepaired() {
        var input = tone(4_800)
        let at = 2_400
        let before = input[at]
        input[at] = 0.95                      // jumps, and comes straight back
        let (out, count) = repaired(input)
        #expect(count >= 1)
        // Mended to roughly where the tone was, not left at the spike.
        #expect(abs(out[at] - before) < 0.02, "\(out[at]) vs \(before)")
    }

    @Test func aSpikeEitherWayIsRepaired() {
        for spike in [Float(0.95), -0.95] {
            var input = tone(4_800)
            input[2_400] = spike
            let (_, count) = repaired(input)
            #expect(count >= 1, "missed a \(spike > 0 ? "positive" : "negative") spike")
        }
    }

    @Test func aRunOfSpikesIsBrokenUpByTheRepeatedPasses() {
        // The reason `passes` is 3: one walk left 46 of Kokoro's 262 behind,
        // because mending a sample is what makes its neighbour visible.
        //
        // Two *adjacent* full-scale spikes in opposite directions is harsher
        // than anything the models emit, and this deliberately does not claim
        // both are removed — see the limitation in `Declick`'s notes. What it
        // does claim is that the pass moves the signal back towards the tone
        // rather than leaving the pair intact.
        var input = tone(4_800)
        input[2_400] = 0.9
        input[2_401] = -0.9
        let clean = tone(4_800)
        let (out, count) = repaired(input)
        #expect(count >= 1)
        let before = abs(input[2_400] - clean[2_400]) + abs(input[2_401] - clean[2_401])
        let after = abs(out[2_400] - clean[2_400]) + abs(out[2_401] - clean[2_401])
        #expect(after < before * 0.7, "\(after) vs \(before)")
    }

    @Test func aSpikeOnTheFirstSampleIsCaughtWhenThePreviousFrameIsGiven() {
        // The streaming case. Without `previous` the first sample of every
        // 80 ms frame is a blind spot — twelve chances a second to miss one.
        let lead = tone(2_400)
        var frame = tone(2_400)
        frame[0] = 0.95
        let n = Declick.repair(&frame, sampleRate: Self.rate, previous: lead,
                               passes: Self.testPasses)
        #expect(n >= 1)
    }

    // MARK: - What it must leave alone

    @Test func aPlosiveAttackIsNotTouched() {
        // Silence, then a fast but band-limited rise — a few samples, not one.
        var input = [Float](repeating: 0, count: 2_400)
        let burst = tone(2_400, freq: 3_000, amp: 0.7)
        for (i, v) in burst.enumerated() {
            let ramp = min(Float(i) / 40, 1)      // ~1.7 ms attack
            input.append(v * ramp)
        }
        let (out, count) = repaired(input)
        #expect(count == 0, "smoothed \(count) sample(s) of a plosive")
        #expect(out == input)
    }

    @Test func aCleanToneIsUntouched() {
        let input = tone(24_000)
        let (out, count) = repaired(input)
        #expect(count == 0)
        #expect(out == input)
    }

    @Test func silenceIsUntouched() {
        let input = [Float](repeating: 0, count: 4_800)
        let (out, count) = repaired(input)
        #expect(count == 0)
        #expect(out == input)
    }

    @Test func quietDitherIsUntouched() {
        // Alternating at ±1 LSB reverses direction on every sample, which is
        // the impulse *shape* — the absolute floor is what keeps it out.
        let lsb = Float(1) / 32_767
        let input = (0..<4_800).map { $0 % 2 == 0 ? lsb : -lsb }
        let (out, count) = repaired(input)
        #expect(count == 0)
        #expect(out == input)
    }

    @Test func loudSpeechIsJudgedAgainstItselfNotAgainstSilence() {
        // A busy, loud passage has large steps everywhere; none of them are
        // clicks, and a fixed threshold would call all of them clicks.
        var rng = SystemRandomNumberGenerator()
        let input = (0..<24_000).map { _ in Float.random(in: -0.6...0.6, using: &rng) }
        let (_, count) = repaired(input)
        // Noise is not band-limited, so a few samples may qualify; the point
        // is that it is not wholesale.
        #expect(Double(count) < Double(input.count) * 0.01, "repaired \(count) of 24000")
    }

    // MARK: - Shape of the thing

    @Test func repairingTwiceChangesNothingTheSecondTime() {
        var input = tone(4_800)
        input[2_400] = 0.95
        var once = input
        _ = Declick.repair(&once, sampleRate: Self.rate, passes: Self.testPasses)
        var twice = once
        let n = Declick.repair(&twice, sampleRate: Self.rate, passes: Self.testPasses)
        #expect(n == 0)
        #expect(twice == once)
    }

    @Test func aBufferTooShortToJudgeIsReturnedUnchanged() {
        for size in [0, 1, 2] {
            var input = [Float](repeating: 0.5, count: size)
            let n = Declick.repair(&input, sampleRate: Self.rate, passes: Self.testPasses)
            #expect(n == 0)
            #expect(input.count == size)
        }
    }

    @Test func theLevelOfThePassageIsBarelyMoved() {
        // Measured on a real Kokoro render: 258 of 158,400 samples changed
        // and RMS moved 0.21%. The guarantee this encodes is that a de-click
        // is a repair, not a gain change.
        var input = tone(24_000)
        var injected = 0
        for i in stride(from: 500, to: 24_000, by: 500) { input[i] = 0.95; injected += 1 }
        let quiet = rms(input)
        let (out, count) = repaired(input)
        // Most, not all: a spike sitting on the tone's own peak is a smaller
        // second difference relative to the local level, and is much less
        // audible there. 31 of 47 on this signal; 262 → 16 on a real render.
        #expect(count >= injected / 2, "repaired \(count) of \(injected)")
        #expect(abs(rms(out) - quiet) / quiet < 0.05)
    }

    private func rms(_ d: [Float]) -> Float {
        (d.reduce(Float(0)) { $0 + $1 * $1 } / Float(d.count)).squareRoot()
    }
}
