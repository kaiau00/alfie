import Foundation
import Testing
@testable import MoeVoice

/// The "Teach Moe its name" card as a state machine: step order, retakes,
/// pauses and cancels at every point, stale reports from abandoned takes,
/// and the result in words.
struct WakeTeachFlowTests {

    typealias F = WakeTeachFlow

    /// Two names and one sound-alike: enough for every path, small enough
    /// to read.
    func flow() -> F {
        F(lines: [.init(say: "Hey Moe", note: "normally", isName: true),
                  .init(say: "Hey Moe", note: "quietly", isName: true),
                  .init(say: "Hey Joe", note: "a near miss", isName: false)])
    }

    /// Start, microphone open, on line 0.
    func started() -> F {
        var f = flow()
        #expect(f.send(.start) == [.openMic])
        #expect(f.step == .starting)
        #expect(f.send(.micReady) == [.record(line: 0, take: 1)])
        return f
    }

    /// Keep the clip in flight and let the beat pass.
    func keep(_ f: inout F) {
        f.send(.speechBegan(take: f.take))
        #expect(f.send(.clip(take: f.take, .kept)) == [.beat])
        _ = f.send(.advance)
    }

    // MARK: Step order

    @Test func walksEveryLineInOrderThenMeasures() {
        var f = started()
        #expect(f.step == .listening(0))
        #expect(f.send(.speechBegan(take: 1)) == [])
        #expect(f.step == .hearing(0))
        #expect(f.send(.clip(take: 1, .kept)) == [.beat])
        #expect(f.step == .gotIt(0))
        #expect(f.send(.advance) == [.record(line: 1, take: 2)])
        #expect(f.step == .listening(1))
        keep(&f)
        #expect(f.step == .listening(2))
        f.send(.speechBegan(take: f.take))
        f.send(.clip(take: f.take, .kept))
        // After the last line the microphone closes and measuring begins.
        #expect(f.send(.advance) == [.closeMic, .measure])
        #expect(f.step == .measuring(done: 0, total: 0))
        #expect(f.keptCount == 3 && f.keptNames == 2)
        #expect(f.send(.measuring(done: 2, total: 3)) == [])
        #expect(f.step == .measuring(done: 2, total: 3))
    }

    @Test func spaceDuringTheBeatDoesNothing() {
        var f = started()
        f.send(.clip(take: 1, .kept))
        // Space maps to nothing here, and a stray pause is ignored: the
        // beat moves on by itself.
        #expect(f.primary == nil)
        #expect(f.send(.pause) == [])
        #expect(f.step == .gotIt(0))
    }

    @Test func dotsFollowTheLines() {
        var f = started()
        #expect(f.dots == [.current, .pending, .pending])
        keep(&f)
        #expect(f.dots == [.done, .current, .pending])
        f.send(.clip(take: f.take, .rejected(.nothingHeard)))
        f.send(.skip)
        #expect(f.dots == [.done, .skipped, .current])
    }

    // MARK: Retake

    @Test func aBadClipWaitsForARetakeOfTheSameLine() {
        var f = started()
        #expect(f.send(.clip(take: 1, .rejected(.nothingHeard))) == [])
        #expect(f.step == .retake(0, .nothingHeard))
        #expect(!f.kept[0])
        // It does not move on by itself.
        #expect(f.send(.advance) == [])
        #expect(f.primary?.event == .retake)
        #expect(f.send(.retake) == [.record(line: 0, take: 2)])
        #expect(f.step == .listening(0))
    }

    @Test func eachProblemHasItsOwnAdvice() {
        let all: [F.Problem] = [.nothingHeard, .tooQuiet, .tooShort, .clipped]
        #expect(Set(all.map(\.title)).count == all.count)
        #expect(Set(all.map(\.advice)).count == all.count)
    }

    // MARK: The judge, on measured levels

    typealias L = F.ClipLevel

    /// Real "Hey Moe"s that woke the live wake word in standby — the
    /// stream the card records from — read out of the wake turns' debug
    /// clips on the owner's Mac (voice/debug, 2026-09-23…25): the voice
    /// (90th-percentile 32 ms frame), the room (20th percentile) and the
    /// loudest sample. Every one of these woke Moe, so every one must be
    /// kept, and without a "quiet" note. Under the old rule (peak < 0.02
    /// is too quiet) the six with a peak under 0.02 were refused.
    static let wokeMoe: [(speechDb: Float, floorDb: Float, peak: Float)] = [
        (-54.3, -89.0, 0.0091),  // 20260923T212613
        (-59.4, -88.7, 0.0137),  // 20260923T224427
        (-50.7, -82.2, 0.0154),  // 20260924T171528
        (-56.7, -84.4, 0.0071),  // 20260924T214937
        (-59.4, -90.8, 0.0060),  // 20260924T234318
        (-60.6, -85.0, 0.0046),  // 20260925T131934 — the 10th percentile
        (-54.3, -83.1, 0.0211),  // the median voice (−54.3 dBFS)
        (-48.3, -82.7, 0.0268),  // 20260924T002301 — the loudest
    ]

    @Test func everyHeyMoeThatWokeMoeInStandbyIsKept() {
        for c in Self.wokeMoe {
            let l = L(seconds: 1.4, speechDb: c.speechDb, floorDb: c.floorDb, peak: c.peak, clippedSamples: 0)
            #expect(F.judge(l) == .keep, "voice \(c.speechDb) dBFS, peak \(c.peak)")
        }
    }

    /// The same, from samples: 0.35 s of room at −85 dBFS, the phrase at
    /// −56.7 dBFS RMS (a sine, so its peak is 0.0021 — far under the old
    /// 0.02 bar), 0.45 s of room. Measured and judged as the recorder does.
    @Test func aClipAtTheOwnersStandbyLevelMeasuresAsSpeechAndIsKept() {
        let clip = Self.synth(roomDb: -85, voiceDb: -56.7)
        let l = L.measure(clip)
        #expect(abs(l.speechDb - -56.7) < 1.0)
        #expect(abs(l.floorDb - -85) < 2.0)
        #expect(l.peak < 0.02)
        #expect(F.judge(l) == .keep)
    }

    /// The owner's 2026-09-04 clips, recorded with voice processing on:
    /// the median one (voice −18.6 dBFS, peak 0.38) is plainly kept too.
    @Test func aProcessedClipIsKept() {
        #expect(F.judge(L(seconds: 2.75, speechDb: -18.6, floorDb: -74.8, peak: 0.378, clippedSamples: 0)) == .keep)
    }

    @Test func quietIsKeptWithANoteAndOnlyNothingIsRefused() {
        // Under every real "Hey Moe" but still a voice: kept, with a note.
        #expect(F.judge(L(seconds: 1.4, speechDb: -66, floorDb: -86, peak: 0.003, clippedSamples: 0)) == .keepQuiet)
        // The room and nothing else.
        #expect(F.judge(L(seconds: 1.4, speechDb: -80, floorDb: -86, peak: 0.0004, clippedSamples: 0)) == .reject(.nothingHeard))
        // Loud, but no louder than a loud room: nothing over it.
        #expect(F.judge(L(seconds: 1.4, speechDb: -50, floorDb: -53, peak: 0.02, clippedSamples: 0)) == .reject(.nothingHeard))
        #expect(F.judge(L.measure(Self.synth(roomDb: -85, voiceDb: -85))) == .reject(.nothingHeard))
    }

    @Test func tooShortAndClippedAreStillRefused() {
        #expect(F.judge(L(seconds: 0.25, speechDb: -30, floorDb: -80, peak: 0.5, clippedSamples: 0)) == .reject(.tooShort))
        #expect(F.judge(L(seconds: 0.8, speechDb: -6, floorDb: -80, peak: 1.0, clippedSamples: 40)) == .reject(.clipped))
        #expect(F.judge(L(seconds: 0.8, speechDb: -6, floorDb: -80, peak: 1.0, clippedSamples: 2)) == .keep)
        #expect(F.clippedSamples([0.1, -1.0, 0.995, 0.5]) == 2)
    }

    @Test func theLogLineCarriesEveryNumber() {
        let l = L(seconds: 1.42, speechDb: -54.3, floorDb: -85.2, peak: 0.0211, clippedSamples: 0)
        #expect(l.description == "voice -54.3 dBFS, room -85.2 dBFS, peak 0.021 (-33.5 dBFS), 1.42 s")
        #expect(F.Verdict.keepQuiet.words == "kept, quiet")
        #expect(F.Verdict.reject(.nothingHeard).words == "not kept: nothingHeard")
    }

    /// Room noise at `roomDb`, then a 0.7 s 220 Hz tone at `voiceDb` RMS,
    /// then room: the shape of a trimmed clip.
    static func synth(roomDb: Float, voiceDb: Float) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        let room = powf(10, roomDb / 20) * 1.7320508  // uniform noise: RMS = a/√3
        let voice = powf(10, voiceDb / 20) * 1.4142135
        func noise(_ n: Int) -> [Float] { (0..<n).map { _ in Float.random(in: -room...room, using: &rng) } }
        let tone = (0..<11_200).map { voice * sinf(2 * .pi * 220 * Float($0) / 16_000) + Float.random(in: -room...room, using: &rng) }
        return noise(5_600) + tone + noise(7_200)
    }

    // MARK: A quiet clip is kept

    @Test func aQuietClipIsKeptAndTheBeatSaysSo() {
        var f = started()
        f.send(.speechBegan(take: f.take))
        #expect(f.send(.clip(take: f.take, .keptQuiet)) == [.beat])
        #expect(f.step == .gotIt(0))
        #expect(f.kept[0])
        #expect(f.lastKeptQuiet)
        #expect(f.announcement == "\(F.Problem.tooQuiet.title). \(F.Problem.tooQuiet.advice)")
        _ = f.send(.advance)
        #expect(!f.lastKeptQuiet)
        f.send(.clip(take: f.take, .kept))
        #expect(f.announcement == "Got it")
    }

    @Test func aSkippedLineIsLeftOutAndTheCardMovesOn() {
        var f = started()
        f.send(.clip(take: 1, .rejected(.nothingHeard)))
        #expect(f.send(.skip) == [.record(line: 1, take: 2)])
        #expect(f.skipped[0] && !f.kept[0])
    }

    @Test func redoThePreviousLineDiscardsItsClip() {
        var f = started()
        keep(&f)
        #expect(f.canRedoPrevious)
        let effects = f.send(.redoPrevious)
        #expect(effects == [.stopRecording, .discard(line: 0), .record(line: 0, take: 3)])
        #expect(f.step == .listening(0))
        #expect(!f.kept[0])
        // Nothing before line 0 to redo.
        #expect(!f.canRedoPrevious)
        #expect(f.send(.redoPrevious) == [])
    }

    @Test func redoFromAPauseReopensTheMicrophone() {
        var f = started()
        keep(&f)
        f.send(.pause)
        #expect(f.send(.redoPrevious) == [.discard(line: 0), .openMic, .record(line: 0, take: 3)])
    }

    // MARK: Pause and cancel

    @Test func pauseStopsTheTakeAndGivesTheMicrophoneBack() {
        var f = started()
        f.send(.speechBegan(take: 1))
        #expect(f.send(.pause) == [.stopRecording, .closeMic])
        #expect(f.step == .paused(0))
        #expect(!f.micOpen)
        #expect(f.primary?.event == .resume)
        #expect(f.send(.resume) == [.openMic, .record(line: 0, take: 2)])
        #expect(f.step == .listening(0))
    }

    @Test func aLateReportFromAnAbandonedTakeIsIgnored() {
        var f = started()
        f.send(.pause)
        f.send(.resume)
        // Take 1 was abandoned by the pause; its report arrives now.
        #expect(f.send(.clip(take: 1, .kept)) == [])
        #expect(f.send(.speechBegan(take: 1)) == [])
        #expect(f.step == .listening(0))
        #expect(!f.kept[0])
        // The live take still counts.
        #expect(f.send(.clip(take: 2, .kept)) == [.beat])
    }

    @Test func cancelMidwayStopsEverythingAndLeavesNothingBehind() {
        var f = started()
        keep(&f)
        f.send(.speechBegan(take: f.take))
        let effects = f.send(.cancel)
        #expect(effects == [.stopRecording, .closeMic, .discard(line: 0), .dismiss])
        #expect(f.step == .closed)
        // Closed is closed: nothing moves it again.
        #expect(f.send(.clip(take: f.take, .kept)) == [])
        #expect(f.send(.start) == [])
        #expect(f.step == .closed)
    }

    @Test func cancelFromAPauseHasNoMicrophoneToClose() {
        var f = started()
        keep(&f)
        f.send(.pause)
        #expect(f.send(.cancel) == [.discard(line: 0), .dismiss])
    }

    @Test func cancelBeforeStartingJustCloses() {
        var f = flow()
        #expect(f.send(.cancel) == [.dismiss])
    }

    @Test func closingWhileMeasuringKeepsTheClips() {
        var f = started()
        keep(&f); keep(&f); keep(&f)
        #expect(f.send(.cancel) == [.dismiss])
    }

    @Test func finishEarlyMeasuresOnlyWithANameKept() {
        var f = started()
        f.send(.pause)
        #expect(!f.canFinishEarly)
        #expect(f.send(.finishEarly) == [])
        f.send(.resume)
        keep(&f)
        f.send(.pause)
        #expect(f.canFinishEarly)
        #expect(f.send(.finishEarly) == [.measure])
        #expect(f.step == .measuring(done: 0, total: 0))
    }

    @Test func noNameKeptMeansNothingToMeasure() {
        var f = started()
        f.send(.clip(take: f.take, .rejected(.nothingHeard))); f.send(.skip)
        f.send(.clip(take: f.take, .rejected(.nothingHeard))); f.send(.skip)
        f.send(.clip(take: f.take, .kept))
        #expect(f.send(.advance) == [.closeMic])
        #expect(f.step == .failed(.heardNothing))
        #expect(f.primary?.event == .teachAgain)
    }

    @Test func aMicrophoneThatWillNotOpenSaysWhy() {
        var f = flow()
        f.send(.start)
        #expect(f.send(.micFailed(.busy)) == [])
        #expect(f.step == .failed(.busy))
        #expect(f.send(.teachAgain) == [.openMic])
        #expect(f.step == .starting)
    }

    @Test func aMicrophoneThatWillNotReopenAfterAPause() {
        var f = started()
        f.send(.pause)
        f.send(.resume)
        #expect(f.send(.micFailed(.unavailable("gone"))) == [.stopRecording])
        #expect(f.step == .failed(.unavailable("gone")))
    }

    // MARK: Result

    let pick = WakeCalibration.Pick(threshold: 0.24,
                                    after: .init(positives: 12, caught: 11, confusables: 8, falseAccepts: 1),
                                    before: .init(positives: 12, caught: 8, confusables: 8, falseAccepts: 2))

    @Test func theResultReadsAsBeforeAndAfter() {
        var f = started()
        keep(&f); keep(&f); keep(&f)
        #expect(f.send(.measured(pick, changed: true)) == [])
        guard case .result(let o) = f.step else { Issue.record("not a result: \(f.step)"); return }
        #expect(o.headline == "Catches 11 of your 12 “Hey Moe”s (was 8) · lets through 1 of 8 sound-alikes (was 2)")
        #expect(o.title == "Moe hears you better now")
        #expect(o.summary == WakeCalibration.summary(pick, changed: true))
        #expect(f.primary?.title == "Done")
        #expect(f.send(.cancel) == [.dismiss])
    }

    @Test func aNumberThatDidNotMoveHasNoWas() {
        let same = WakeCalibration.Pick(threshold: 0.28,
                                        after: .init(positives: 12, caught: 12, confusables: 8, falseAccepts: 0),
                                        before: .init(positives: 12, caught: 12, confusables: 8, falseAccepts: 0))
        let o = F.Outcome(pick: same, changed: false)
        #expect(o.headline == "Catches 12 of your 12 “Hey Moe”s · lets through 0 of 8 sound-alikes")
        #expect(o.title == "Moe already hears you well")
        let one = F.Outcome(pick: .init(threshold: 0.3, after: .init(positives: 1, caught: 1, confusables: 0, falseAccepts: 0),
                                        before: .init(positives: 1, caught: 0, confusables: 0, falseAccepts: 0)),
                            changed: true)
        #expect(one.headline == "Catches 1 of your 1 “Hey Moe” (was 0)")
    }

    @Test func teachAgainStartsFreshFromTheResult() {
        var f = started()
        keep(&f); keep(&f); keep(&f)
        f.send(.measured(pick, changed: true))
        #expect(f.send(.teachAgain) == [.openMic])
        #expect(f.keptCount == 0)
        #expect(f.send(.micReady) == [.record(line: 0, take: f.take)])
    }

    @Test func measuringCanFailHonestly() {
        var f = started()
        keep(&f); keep(&f); keep(&f)
        f.send(.measureFailed(.unavailable("No model")))
        #expect(f.step == .failed(.unavailable("No model")))
    }

    @Test func voiceOverHearsEachPrompt() {
        var f = started()
        #expect(f.announcement == "1 of 3. Say: Hey Moe")
        f.send(.clip(take: f.take, .rejected(.clipped)))
        #expect(f.announcement?.hasPrefix(F.Problem.clipped.title) == true)
    }
}
