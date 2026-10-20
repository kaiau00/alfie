import Foundation
import Testing
@testable import MoeMeeting

// MARK: - The speech gate, measured

// The gate is two conditions on a 100 ms frame (`Windowing.hasSpeech`):
// at least `Windowing.speechOverNoiseDb` (12 dB) above the *enclosing
// window's* 10th-percentile frame level, and above
// `Windowing.absoluteFloorDb` (-50 dBFS). Three such frames make a window
// worth transcribing; two make a segment worth keeping.
//
// It replaces an absolute floor, which could not do the job. -45 threw
// away a real meeting whose microphone sat near -52 dBFS. -50 recovers
// that meeting and, measured below, admits steady room tone at -49, a fan
// at -47 and at -51, an AGC holding near-silence at -50 and a
// syllable-modulated far-end leak at -52 — every one of which a recogniser
// turns into sentences that were never said. No absolute number separates
// those from quiet speech, because they overlap it in level. What
// separates them is that they are *steady* and speech is not.
//
// These tests print what they measure. `scripts/test.sh` shows the table.

/// A deterministic noise source, so every number in this file is
/// reproducible and a failure is never a reroll away from passing.
private struct Noise {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / 4_194_304.0 - 1        // [-1, 1)
    }
    mutating func samples(_ n: Int) -> [Float] { (0..<n).map { _ in next() } }
}

private func rmsDb(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return -200 }
    var sum = 0.0
    for v in samples { sum += Double(v * v) }
    return 20 * log10(max(Float((sum / Double(samples.count)).squareRoot()), 1e-10))
}

/// `samples` scaled so its rms is exactly `db` dBFS.
private func at(_ db: Float, _ samples: [Float]) -> [Float] {
    let gain = pow(10, (db - rmsDb(samples)) / 20)
    return samples.map { $0 * gain }
}

/// Steady broadband noise at a level: room tone, a fan, the comfort noise
/// an AGC or an echo canceller puts out over silence. Whatever its level,
/// nothing in it stands out from the rest of it.
private func steady(_ db: Float, seconds: Double = 3) -> [Float] {
    var n = Noise()
    return at(db, n.samples(Int(16_000 * seconds)))
}

/// A sine at an amplitude — the two fixtures the old absolute floor was
/// chosen to reject, kept exactly as they were so the comparison holds.
private func tone(amplitude: Float, seconds: Double = 1, rate: Int = 16_000) -> [Float] {
    (0..<Int(Double(rate) * seconds)).map { Float(sin(Double($0) * 0.3)) * amplitude }
}

/// An echo canceller's residual: comfort noise whose gain follows the far
/// end's syllable rate. `swingDb` is the peak-to-trough of the envelope —
/// residual echo suppression flattens the far end's own 30 dB dynamic
/// range to a few decibels, which is what makes a leak a leak rather than
/// just quiet speech.
private func modulatedLeak(_ db: Float, swingDb: Float = 6, seconds: Double = 3) -> [Float] {
    var n = Noise()
    let raw = n.samples(Int(16_000 * seconds))
    let shaped = raw.enumerated().map { i, v -> Float in
        let t = Double(i) / 16_000
        let g = -Double(swingDb) * (1 - cos(2 * .pi * 4 * t)) / 2      // 0 … -swingDb
        return v * Float(pow(10, g / 20))
    }
    return at(db, shaped)
}

/// A quiet meeting: a soft room with somebody talking softly in it.
/// `bursts` are syllable-shaped, which is the whole difference from the
/// signals above.
private func quietSpeech(roomDb: Float, voiceDb: Float, seconds: Double = 10,
                         burst: Double = 0.3, every: Double = 2.5) -> [Float] {
    var n = Noise()
    var out = at(roomDb, n.samples(Int(16_000 * seconds)))
    var voice = Noise()
    let gain = pow(10, (voiceDb - rmsDb(at(0, voice.samples(1600)))) / 20)
    var start = 1.0
    while start + burst <= seconds {
        let from = Int(start * 16_000), count = Int(burst * 16_000)
        for k in 0..<count {
            let t = Double(k) / Double(count)
            let shape = Float(sin(.pi * t))                     // one syllable
            out[from + k] += voice.next() * gain * shape
        }
        start += every
    }
    return out
}

/// One row of the table: what the gate saw and what it decided.
@discardableResult
private func row(_ name: String, _ samples: [Float], minFrames: Int = 3) -> Bool {
    let levels = Windowing.frameLevelsDb(samples).sorted()
    let floor = Windowing.noiseFloorDb(samples) ?? -200
    let verdict = Windowing.hasSpeech(samples, minFrames: minFrames)
    print(String(format: "  %-46@  rms %7.1f  p10 %7.1f  loudest %7.1f  contrast %5.1f dB  →  %@",
                 name as NSString, rmsDb(samples), floor, levels.last ?? -200,
                 (levels.last ?? -200) - floor,
                 (verdict ? "SPEECH" : "reject") as NSString))
    return verdict
}

struct SpeechGateTests {

    /// The two guards the old absolute floor existed for. They are steady
    /// tones, so the relative half rejects them without reference to their
    /// level — which is why the absolute floor no longer has to be tuned
    /// around them.
    @Test func theTwoExistingGuardsAreStillRejected() {
        print("\n-- the guards that stop a recogniser inventing words --")
        let leak = tone(amplitude: 0.003, seconds: 3)      // echo-cancelled far end
        let quiet = tone(amplitude: 0.004)                 // quiet under a hallucinated line
        #expect(abs(rmsDb(leak) - -53.47) < 0.05)
        #expect(abs(rmsDb(quiet) - -50.97) < 0.05)
        #expect(!row("far-end leak (0.003 sine)", leak))
        #expect(!row("quiet stretch (0.004 sine)", quiet))
        // And now for the right reason: both are rejected even with the
        // absolute floor taken away entirely.
        #expect(!Windowing.hasSpeech(leak, floorDb: -200))
        #expect(!Windowing.hasSpeech(quiet, floorDb: -200))
    }

    /// What -50 as an absolute floor admits, and the relative gate does
    /// not. Every one of these is a real thing a laptop input produces,
    /// and every one of them was transcribed into sentences.
    @Test func theAdversarialSetIsRejected() {
        print("\n-- steady noise an absolute floor at -50 cannot reject --")
        #expect(!row("room tone -46", steady(-46)))
        #expect(!row("room tone -49", steady(-49)))
        #expect(!row("fan -47", steady(-47)))
        #expect(!row("fan -51", steady(-51)))
        #expect(!row("AGC'd near-silence -50", steady(-50)))
        #expect(!row("modulated far-end leak -52 (6 dB swing)", modulatedLeak(-52)))
    }

    /// Speech, at the levels a laptop actually records it — including a
    /// window as quiet overall as the microphone that started all this.
    @Test func speechPasses() {
        print("\n-- speech --")
        let ordinary = quietSpeech(roomDb: -55, voiceDb: -25)
        let quiet = quietSpeech(roomDb: -62, voiceDb: -44, burst: 0.3, every: 2.5)
        #expect(row("ordinary voice over room tone -55", ordinary))
        #expect(row("quiet voice, window rms ≈ -52", quiet))
        // The window the old floor was raised to recover: overall level in
        // the same place as the far-end leak above, and it passes, because
        // what is in it is not steady.
        #expect(abs(rmsDb(quiet) - -52) < 2)
    }

    /// Why the baseline for a segment must come from its window. A
    /// segment's span is a second of speech with 100 ms of slack, so its
    /// own quietest tenth is either that speech or — in a padded window —
    /// digital silence at -200 dBFS. Either way it passes itself.
    @Test func aSegmentMeasuredAgainstItselfPassesEverything() {
        print("\n-- a segment cannot be its own baseline --")
        let window = steady(-46, seconds: 30)
        // Any second of it, with the slack the segment filter adds.
        let span = Array(window[(16_000 * 5)..<(16_000 * 6 + 1600)])
        // Against the window's floor: rejected, as the whole window is.
        #expect(!Windowing.hasSpeech(span, minFrames: 2, noiseFloorDb: Windowing.noiseFloorDb(window)))
        // Against its own: the contrast inside a stretch of steady noise is
        // a fraction of a decibel, so this one still fails — it is the
        // *padded* case that is dangerous.
        var padded = [Float](repeating: 0, count: 16_000)
        padded += Array(window[0..<(16_000 * 2)])
        padded += [Float](repeating: 0, count: 16_000)
        print(String(format: "  padded segment's own p10 %.1f dBFS vs the window's %.1f dBFS",
                     Windowing.noiseFloorDb(padded) ?? 0, Windowing.noiseFloorDb(window) ?? 0))
        #expect((Windowing.noiseFloorDb(padded) ?? 0) < -150)
        #expect(Windowing.hasSpeech(padded, minFrames: 2))                     // its own baseline: passes
        #expect(!Windowing.hasSpeech(padded, minFrames: 2,
                                     noiseFloorDb: Windowing.noiseFloorDb(window)))   // the window's: does not
    }

    /// The absolute half still earns its place: in a digitally silent room
    /// the 10th percentile is -200 dBFS and *everything* is 12 dB above the
    /// floor, so without it a faint tick would read as speech.
    @Test func theAbsoluteFloorStopsTheRelativeGateFiringOnSilence() {
        var samples = [Float](repeating: 0, count: 16_000 * 5)
        var n = Noise()
        // Three well-separated 100 ms frames at -60 dBFS in digital silence.
        for f in [10, 20, 30] {
            let quiet = at(-60, n.samples(1600))
            for k in 0..<1600 { samples[f * 1600 + k] = quiet[k] }
        }
        #expect(Windowing.noiseFloorDb(samples)! < -150)
        #expect(!Windowing.hasSpeech(samples))                  // the floor rejects it
        #expect(Windowing.hasSpeech(samples, floorDb: -200))    // without it, the relative half alone does not
    }

    /// Pre-existing, and unchanged by this: a cough and typing are not
    /// steady, so the relative gate has no more to say about them than the
    /// absolute floor did. Both still reach the recogniser.
    @Test func aCoughAndTypingStillPassAsTheyDidBefore() {
        print("\n-- not fixed by this, and not made worse (pre-existing) --")
        var n = Noise()
        var cough = steady(-55, seconds: 5)
        let burst = at(-20, n.samples(4800))                   // 300 ms
        for k in 0..<4800 { cough[16_000 + k] = burst[k] }
        var typing = steady(-55, seconds: 5)
        for click in stride(from: 8_000, to: 70_000, by: 2_400) {
            let tap = at(-26, n.samples(480))                  // 30 ms
            for k in 0..<480 { typing[click + k] = tap[k] }
        }
        #expect(row("a cough", cough))
        #expect(row("keyboard typing", typing))
    }

    /// The frame count still has to be met: one loud click is not a
    /// sentence, whatever its level and whatever the room.
    @Test func oneLoudClickInSilenceIsStillNotSpeech() {
        var samples = [Float](repeating: 0, count: 16_000 * 5)
        for i in 20_000..<20_960 { samples[i] = Float(sin(Double(i) * 0.3)) }
        #expect(!Windowing.hasSpeech(samples))
        for i in 24_000..<24_960 { samples[i] = Float(sin(Double(i) * 0.3)) }
        for i in 28_000..<28_960 { samples[i] = Float(sin(Double(i) * 0.3)) }
        #expect(Windowing.hasSpeech(samples))
    }

    /// Where the relative bar sits, measured with everything else held
    /// still: whole 100 ms frames dropped into a room at -46 dBFS, so the
    /// absolute floor can never be what decides it.
    @Test func theBarIsTwelveDecibelsOverTheRoom() {
        print("\n-- where the bar sits (a -46 dBFS room, so -50 is not in play) --")
        for over in [Float(8), 10, 12, 14] {
            var s = steady(-46, seconds: 5)
            var n = Noise()
            for f in [10, 20, 30] {
                let loud = at(-46 + over, n.samples(1600))
                for k in 0..<1600 { s[f * 1600 + k] = loud[k] }
            }
            let floor = Windowing.noiseFloorDb(s)!
            let loudest = Windowing.frameLevelsDb(s).max()!
            let verdict = Windowing.hasSpeech(s)
            print(String(format: "  three frames %+.0f dB over the room → contrast %.1f dB → %@",
                         Double(over), loudest - floor,
                         (verdict ? "SPEECH" : "reject") as NSString))
            #expect(verdict == (over >= 12))
        }
    }

    /// Health is not recognition. They were the same constant; the two
    /// questions are different and the pressure on them is opposite.
    @Test func healthHasItsOwnThresholdNow() {
        #expect(ChannelHealth().soundDb == ChannelHealth.defaultSoundDb)
        #expect(ChannelHealth.defaultSoundDb == -50)
        #expect(Windowing.absoluteFloorDb == -50)
        #expect(Windowing.speechOverNoiseDb == 12)
    }
}
