import Foundation
import Testing
@testable import MoeVoice

/// What this pins is the owner's complaint from 2026-09-05: "I paused for
/// literally not even a second, and then it just ended my turn." The VAD
/// will not report a stop until it has heard 250 ms of quiet, so the turn
/// model was always being handed that quarter-second — and measured against
/// the shipped model, a quarter-second of trailing silence takes it from
/// telling finished from mid-sentence by 0.435 down to 0.285.
struct TurnAudioTests {

    private let rate = 16_000

    private func tone(_ seconds: Double, level: Float = 0.3) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { i -> Float in
            let phase: Float = 2 * .pi * 220 * Float(i) / Float(rate)
            return level * Foundation.sin(phase)
        }
    }
    private func quiet(_ seconds: Double) -> [Float] {
        // Not digital silence: a real microphone's floor, which is what the
        // trimmer has to cut through.
        (0..<Int(Double(rate) * seconds)).map { _ in Float.random(in: -0.0008...0.0008) }
    }

    @Test func theQuarterSecondTheVadWaitsForIsRemoved() {
        let audio = tone(1.0) + quiet(0.25)
        let out = TurnAudio.trimTrailingSilence(audio)
        #expect(abs(Double(out.count) / Double(rate) - 1.0) < 0.02)
    }

    @Test func aLongPauseIsRemovedToo() {
        let out = TurnAudio.trimTrailingSilence(tone(2.0) + quiet(3.0))
        #expect(abs(Double(out.count) / Double(rate) - 2.0) < 0.02)
    }

    /// Silence *inside* the turn is the person thinking mid-sentence, and it
    /// is exactly the evidence the model needs. Only the tail goes.
    @Test func silenceInTheMiddleIsKept() {
        let out = TurnAudio.trimTrailingSilence(tone(0.5) + quiet(0.6) + tone(0.5) + quiet(0.3))
        #expect(abs(Double(out.count) / Double(rate) - 1.6) < 0.02)
    }

    @Test func keepLeavesTheMarginItIsAskedFor() {
        let out = TurnAudio.trimTrailingSilence(tone(1.0) + quiet(0.5), keep: 0.1)
        #expect(abs(Double(out.count) / Double(rate) - 1.1) < 0.02)
    }

    @Test func audioThatDoesNotEndInSilenceIsUntouched() {
        let audio = tone(1.5)
        #expect(TurnAudio.trimTrailingSilence(audio).count == audio.count)
    }

    // MARK: - Never hand the model nothing

    /// A buffer with no speech in it cannot be reasoned about, and an empty
    /// array would make the model answer a question about nothing.
    @Test func silenceThroughoutComesBackWhole() {
        let audio = quiet(2.0)
        #expect(TurnAudio.trimTrailingSilence(audio).count == audio.count)
    }

    @Test func digitalSilenceComesBackWhole() {
        let audio = [Float](repeating: 0, count: rate)
        #expect(TurnAudio.trimTrailingSilence(audio).count == audio.count)
    }

    @Test func aBufferTooShortToFrameComesBackWhole() {
        let audio = [Float](repeating: 0.2, count: 50)
        #expect(TurnAudio.trimTrailingSilence(audio).count == 50)
    }

    @Test func emptyIsEmpty() {
        #expect(TurnAudio.trimTrailingSilence([]).isEmpty)
    }

    /// Level is judged against the clip's own peak, so the same sentence
    /// through a quiet microphone trims the same way as through a loud one.
    @Test func gainDoesNotChangeWhereItCuts() {
        let loud = tone(1.0, level: 0.9) + quiet(0.4)
        let soft = loud.map { $0 * 0.02 }
        let a = TurnAudio.trimTrailingSilence(loud).count
        let b = TurnAudio.trimTrailingSilence(soft).count
        #expect(abs(a - b) < rate / 50)
    }
}

// The piano case (2026-09-05, "I finished talking, but there was still audio
// going through") used to be `TurnPolicy.wordsHaveStalled`, a 6 s net that
// only ran while the VAD said speech and was never re-armed. It is now the
// machine's `.wordStall` clock — see `NoiseEndpointTests`.

/// The setting itself, pinned. Trimming to nothing was measured as the worst
/// of the settings tried — it drags *finished* scores from 0.645 to 0.376 —
/// and Smart Turn's contribution guide says its training samples end with
/// "around 200ms of silence. More silence than this is also fine."
struct PauseKeptTests {

    @Test func thePauseIsKeptNotRemoved() {
        // The model was trained on ~200 ms of trailing silence; trimming to
        // nothing was measured as the worst setting of those tried.
        #expect(TurnAudio.pauseTheModelWasTrainedOn >= 0.2)
    }

    /// Past 0.3 s the separation flattens (0.422 at 0.30 s, 0.421 at 0.50 s),
    /// and every extra millisecond is one the person waits.
    @Test func andNotMoreThanTheKnee() {
        #expect(TurnAudio.pauseTheModelWasTrainedOn <= 0.35)
    }

    /// What the constant is for: the VAD reports a stop after 250 ms and the
    /// hop to read the buffer adds a variable tail, so a turn arrives with
    /// *more* than the trained amount, not less. Capping it is the job.
    @Test func aLongPauseIsCutBackToIt() {
        let rate = 16_000
        let tone = (0..<rate).map { i -> Float in
            0.3 * Foundation.sin(2 * .pi * 220 * Float(i) / Float(rate))
        }
        let quiet = (0..<(rate * 2)).map { _ in Float.random(in: -0.0008...0.0008) }
        let out = TurnAudio.trimTrailingSilence(tone + quiet,
                                                keep: TurnAudio.pauseTheModelWasTrainedOn)
        let seconds = Double(out.count) / Double(rate)
        #expect(abs(seconds - (1.0 + TurnAudio.pauseTheModelWasTrainedOn)) < 0.02)
    }
}

/// Item 3 of the 2026-09-22 voice audit (H6): in noise the energy trim cuts
/// nothing, and Smart Turn is handed the sentence plus seconds of room.
struct TrimAfterLastWordTests {

    private let rate = 16_000

    private func tone(_ seconds: Double, level: Float = 0.3) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { i -> Float in
            level * Foundation.sin(2 * .pi * 220 * Float(i) / Float(rate))
        }
    }
    /// A fan: broadband noise at about a quarter of the speech level —
    /// well above the energy trim's "twentieth of the peak".
    private func fan(_ seconds: Double) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { _ in Float.random(in: -0.12...0.12) }
    }
    private func secs(_ a: [Float]) -> Double { Double(a.count) / Double(rate) }

    /// The failure, pinned: the energy trim leaves the whole noise tail on.
    @Test func theEnergyTrimCannotSeeANoisyTail() {
        let audio = tone(2.0) + fan(3.0)
        #expect(secs(TurnAudio.trimTrailingSilence(audio, keep: 0.3)) > 4.5)
    }

    @Test func cutsTheNoiseAfterTheLastWord() {
        let audio = tone(2.0) + fan(3.0)
        // The last partial landed ~0.2 s after the word ended; it is now 2.8 s
        // after that.
        let cut = TurnAudio.trimAfterLastWord(audio, secondsSinceLastWord: 2.8)
        // Speech, the recogniser's lag (0.2 s here, unmeasured in the app so
        // it keeps it), plus the pause the model was trained on.
        #expect(abs(secs(cut) - 2.5) < 0.02)
        // And the energy trim after it cannot put the noise back.
        #expect(secs(TurnAudio.trimTrailingSilence(cut, keep: 0.3)) <= secs(cut))
    }

    /// In a quiet room the last word is a fraction of a second back and
    /// nothing changes.
    @Test func aRecentWordCutsNothing() {
        let audio = tone(2.0) + fan(0.1)
        #expect(TurnAudio.trimAfterLastWord(audio, secondsSinceLastWord: 0.1).count == audio.count)
    }

    /// Never down to nothing: a timestamp from before this audio began is not
    /// a reason to hand the model an empty clip.
    @Test func neverCutsToNothing() {
        let audio = tone(1.0)
        #expect(TurnAudio.trimAfterLastWord(audio, secondsSinceLastWord: 30).count == audio.count)
    }
}
