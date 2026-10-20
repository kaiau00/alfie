import Foundation
import Testing
@testable import MoeVoice

/// The early read may stand for a turn only when the turn *is* that read
/// plus quiet. Every way that can be false has a test here, because the
/// failure mode of a wrong "stands" is a dropped word that no log shows.
struct ProgressiveReadTests {

    private let rate = 16_000

    private func tone(_ seconds: Double, level: Float = 0.3) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { i -> Float in
            let phase: Float = 2 * .pi * 220 * Float(i) / Float(rate)
            return level * Foundation.sin(phase)
        }
    }
    /// A real microphone's floor, not digital silence.
    private func quiet(_ seconds: Double) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { _ in Float.random(in: -0.0008...0.0008) }
    }

    // MARK: - Coverage

    @Test func quietAfterTheReadStands() {
        let read = tone(2.0) + quiet(0.25)                 // what the VAD's edge handed over
        let turn = read + quiet(0.45)                      // the debounce, then the decision
        let snap = ProgressiveRead.Snapshot(read)
        guard case .stands(let q) = ProgressiveRead.coverage(of: snap, in: turn) else {
            Issue.record("a turn that is the read plus quiet must stand"); return
        }
        #expect(abs(q - 0.45) < 0.01)
    }

    @Test func theTurnBeingExactlyTheReadStands() {
        let read = tone(1.0) + quiet(0.25)
        let snap = ProgressiveRead.Snapshot(read)
        #expect(ProgressiveRead.coverage(of: snap, in: read) == .stands(quietSeconds: 0))
    }

    @Test func speechAfterTheReadIsStale() {
        let read = tone(2.0) + quiet(0.3)
        let turn = read + tone(0.5) + quiet(0.25)         // "…oh, and one more thing"
        guard case .stale(let why) = ProgressiveRead.coverage(of: ProgressiveRead.Snapshot(read), in: turn) else {
            Issue.record("speech after the read must not stand"); return
        }
        #expect(why.contains("speech"))
    }

    /// A word said softly after the pause. `TurnAudio` would trim it as
    /// silence at 5% of the peak; this must not, because here "silence"
    /// means "not transcribed".
    @Test func aSoftWordAfterTheReadIsStale() {
        let read = tone(2.0) + quiet(0.3)
        let turn = read + tone(0.4, level: 0.3 * 0.04) + quiet(0.25)   // 4% of the peak
        guard case .stale = ProgressiveRead.coverage(of: ProgressiveRead.Snapshot(read), in: turn) else {
            Issue.record("a soft word is a word"); return
        }
    }

    @Test func aBreathBelowTheFloorStillStands() {
        let read = tone(2.0) + quiet(0.3)
        let turn = read + tone(0.2, level: 0.3 * 0.01) + quiet(0.25)   // 1%: room tone, a breath
        guard case .stands = ProgressiveRead.coverage(of: ProgressiveRead.Snapshot(read), in: turn) else {
            Issue.record("the floor is 2% of the peak"); return
        }
    }

    /// `trimCapture` took the front off after the read: the sample counts
    /// may still line up, the audio does not.
    @Test func aCaptureTrimmedUnderTheReadIsStale() {
        let read = quiet(1.0) + tone(2.0) + quiet(0.3)
        let snap = ProgressiveRead.Snapshot(read)
        let trimmed = Array(read.dropFirst(rate / 2)) + quiet(0.5)
        guard case .stale(let why) = ProgressiveRead.coverage(of: snap, in: trimmed) else {
            Issue.record("a different prefix must not stand"); return
        }
        #expect(why.contains("changed"))
    }

    @Test func aCaptureShorterThanTheReadIsStale() {
        let read = tone(2.0) + quiet(0.3)
        let snap = ProgressiveRead.Snapshot(read)
        guard case .stale = ProgressiveRead.coverage(of: snap, in: Array(read.prefix(rate))) else {
            Issue.record("a read longer than the turn is of some other turn"); return
        }
    }

    @Test func nothingReadIsStale() {
        guard case .stale = ProgressiveRead.coverage(of: ProgressiveRead.Snapshot([]), in: tone(1.0)) else {
            Issue.record("an empty read stands for nothing"); return
        }
    }

    @Test func digitalSilenceStands() {
        let read = [Float](repeating: 0, count: rate)
        let turn = read + [Float](repeating: 0, count: rate / 2)
        guard case .stands = ProgressiveRead.coverage(of: ProgressiveRead.Snapshot(read), in: turn) else {
            Issue.record("no peak, nothing to be louder than"); return
        }
    }

    /// The last thing in the read may be the very end of a word — the
    /// frame that straddles the boundary is judged as "after", so a read cut
    /// mid-syllable is stale rather than standing on the half it heard.
    @Test func aReadCutMidWordIsStale() {
        let speech = tone(2.0)
        let read = Array(speech.prefix(speech.count - 800))   // 50 ms short of the word's end
        let turn = speech + quiet(0.7)
        guard case .stale = ProgressiveRead.coverage(of: ProgressiveRead.Snapshot(read), in: turn) else {
            Issue.record("half a word heard is a word missed"); return
        }
    }

    // MARK: - Claim and discard ordering

    /// The machine emits `.transcribe` then `.capture(false)` in one batch.
    /// The turn claims first; the capture-off that follows finds nothing to
    /// discard — and must not have discarded what the turn took.
    @Test func transcribeClaimsBeforeCaptureOffDiscards() {
        var slot = ProgressiveSlot<Int>()
        slot.begin(7)
        let claimed = slot.claim()        // `.transcribe`
        slot.discard()                    // `.capture(false)`
        #expect(claimed == 7)
        #expect(slot.claim() == nil)
    }

    /// The other order — capture off before any turn claimed it (Esc, a
    /// stop, the window closing) — leaves nothing for a later turn to pick
    /// up by mistake.
    @Test func captureOffBeforeAClaimLeavesNothing() {
        var slot = ProgressiveSlot<Int>()
        slot.begin(7)
        slot.discard()
        #expect(slot.claim() == nil)
        #expect(!slot.isPending)
    }

    /// A pause, more speech, another pause: the second read is the one that
    /// covers the turn, and the first is gone.
    @Test func aSecondReadReplacesTheFirst() {
        var slot = ProgressiveSlot<Int>()
        let g1 = slot.begin(1)
        let g2 = slot.begin(2)
        #expect(g2 == g1 + 1)
        #expect(slot.claim() == 2)
    }

    @Test func aClaimHappensOnce() {
        var slot = ProgressiveSlot<Int>()
        slot.begin(3)
        #expect(slot.claim() == 3)
        #expect(slot.claim() == nil)
    }

    // MARK: - The flag

    /// Off means the old path, exactly: nothing is started, so nothing can
    /// be claimed, so the turn is read whole as it always was.
    @Test func offNeverStarts() {
        #expect(!ProgressiveRead.shouldStart(enabled: false, accurateReady: true, capturing: true, local: true))
    }

    @Test func everyOtherGateHoldsOnItsOwn() {
        #expect(ProgressiveRead.shouldStart(enabled: true, accurateReady: true, capturing: true, local: true))
        #expect(!ProgressiveRead.shouldStart(enabled: true, accurateReady: false, capturing: true, local: true))
        #expect(!ProgressiveRead.shouldStart(enabled: true, accurateReady: true, capturing: false, local: true))
        // A cloud recogniser reading live, or Whisper: one recogniser per turn.
        #expect(!ProgressiveRead.shouldStart(enabled: true, accurateReady: true, capturing: true, local: false))
    }
}
