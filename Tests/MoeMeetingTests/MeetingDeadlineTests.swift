import Foundation
import Testing
@testable import MoeMeeting

// MARK: - The deadline on "Writing your notes…"

struct DeadlineTests {

    @Test func workThatFinishesInTimeIsReturned() async {
        let out = await Deadline.run(seconds: 5) { "notes" }
        #expect(out == "notes")
    }

    /// The case that has no other way out: `finish` never returns, so the
    /// meeting would sit at `.stopping` for as long as the app runs.
    ///
    /// **This used to assert on elapsed wall-clock time, and it was flaky.**
    /// It failed two full runs in three — 5.5 s and 10.2 s against a 3 s
    /// bound — and passed alone in 0.159 s. What it was measuring was the
    /// cooperative thread pool under ~850 tests in parallel, which is not the
    /// thing it exists for, and the bound had already been raised once from
    /// the same cause. A red suite has to mean something.
    ///
    /// So the claim is proved as an *ordering* instead, which no amount of
    /// load can change: the work cannot finish until this test lets it, and
    /// the test does not let it until `run` has already come back. `out` is
    /// nil, so the timer reached `DeadlineBox` first and the work did not —
    /// and `gate.workHasFinished` is false, so at the moment the waiting
    /// stopped the work was still going. That is exactly "the waiting stops
    /// even though the work does not", with no clock in it anywhere.
    @Test func workThatNeverReturnsGivesNilAtTheDeadline() async {
        let gate = Gate()
        let out: String? = await Deadline.run(seconds: 0.05) {
            // Not cancellable on purpose: an ASR call that has stopped
            // responding will not notice cancellation either — `run` cancels
            // its worker on the way out and this must not care — and the
            // point is that the *waiting* stops.
            await gate.wait()
            gate.workDidFinish()
            return "too late"
        }
        // The claim is that the *waiting* stopped, and `out == nil` is that
        // claim: the deadline won the race against work that never returns.
        //
        // There used to be a wall-clock bound here too, and it failed twice on
        // this machine — at 3.12 s against 3, then at 5.09 s against 4.5. It
        // was not measuring the deadline. The work in this test is
        // deliberately uncancellable and holds a cooperative-pool thread for
        // 5 s, so on a loaded machine the continuation resumes late even
        // though the wait itself ended on time. Chasing that with a bigger
        // number would only move the flake. The bound that is left is a hang
        // detector, nothing finer.
        #expect(out == nil)
        #expect(!gate.workHasFinished)
        // Let the abandoned work run to its end, so nothing is left parked on
        // a continuation. `DeadlineBox` has already settled, so this second
        // arrival is dropped — `theWinnerIsWhoeverGotThereFirstAndOnlyOnce`
        // is the test for that.
        gate.open()
    }

    @Test func theWinnerIsWhoeverGotThereFirstAndOnlyOnce() async {
        for _ in 0..<20 {
            let out = await Deadline.run(seconds: 0.001) { "fast" }
            #expect(out == "fast" || out == nil)      // never a crash, never two resumes
        }
    }

    @Test func aZeroOrNegativeDeadlineStillReturns() async {
        let out: Int? = await Deadline.run(seconds: -1) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return 1
        }
        #expect(out == nil)
    }
}

/// Work that stops until the test says otherwise.
///
/// It replaces a five-second sleep loop and a stopwatch. A duration is a
/// measurement of the machine; this is an ordering the test controls, so it
/// says the same thing whether it runs alone or with 850 others on a laptop
/// that is compiling at the time.
///
/// Deliberately not cancellation-aware, for the same reason the work it
/// stands in for is not: `Deadline.run` cancels its worker on the way out and
/// an ASR call that has stopped responding does not notice.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    private var finished = false

    /// True once the work got all the way to its `return`.
    var workHasFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func workDidFinish() {
        lock.lock(); finished = true; lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            waiter = c
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let c = waiter
        waiter = nil
        lock.unlock()
        c?.resume()
    }
}

// MARK: - The budget the deadline is set from

/// The number this was — a flat 180 s — could not have finished a real
/// meeting. These are the three costs it has to cover, from the project's
/// own measurements.
struct MeetingFinishBudgetTests {

    /// Diarization is ~0.03× realtime over the whole system stream: 110 s
    /// for an hour, 220 s for two. A flat 180 s is under the second of
    /// those before the model load or the summary have run at all.
    @Test func theBudgetClearsMeasuredDiarizationOnLongMeetings() {
        for hours in [0.5, 1.0, 2.0, 3.0, 10.0] {
            let recorded = hours * 3600
            let diarization = 0.03 * recorded
            let modelLoad = 12.9
            #expect(MeetingFinishBudget.seconds(recorded: recorded) > diarization + modelLoad)
        }
        // The flat value it replaced does not, from two hours up.
        #expect(180 < 0.03 * 7200 + 12.9)
    }

    /// `HermesMeetingBrain` gives the summary request 180 s of its own
    /// (`timeoutIntervalForResource`). An outer deadline of 180 s can never
    /// let that inner one report a failure; it must sit above it even for a
    /// meeting of no length at all.
    @Test func theBudgetSitsAboveTheSummaryRequestsOwnCeiling() {
        #expect(MeetingFinishBudget.seconds(recorded: 0) > 180)
        #expect(MeetingFinishBudget.base > 180)
    }

    @Test func itGrowsWithTheRecordingAndNeverGoesBackwards() {
        #expect(MeetingFinishBudget.seconds(recorded: 600) == 300)      // 10 min → 5 min
        #expect(MeetingFinishBudget.seconds(recorded: 3600) == 600)     // 1 h → 10 min
        #expect(MeetingFinishBudget.seconds(recorded: 7200) == 960)     // 2 h → 16 min
        #expect(MeetingFinishBudget.seconds(recorded: 3601)
                >= MeetingFinishBudget.seconds(recorded: 3600))
        // And it stops growing: past this it is no longer a hang detector.
        #expect(MeetingFinishBudget.seconds(recorded: 100 * 3600) == MeetingFinishBudget.ceiling)
    }

    /// `recorder.elapsed` is a clock difference; it must not be able to
    /// hand this a negative or a NaN and get a deadline that fires at once.
    @Test func nonsenseDurationsFallBackToTheBase() {
        #expect(MeetingFinishBudget.seconds(recorded: 0) == MeetingFinishBudget.base)
        #expect(MeetingFinishBudget.seconds(recorded: -60) == MeetingFinishBudget.base)
        #expect(MeetingFinishBudget.seconds(recorded: .nan) == MeetingFinishBudget.base)
        #expect(MeetingFinishBudget.seconds(recorded: .infinity).isFinite)
    }
}

// MARK: - One owner for meeting.json

/// The deadline stops *waiting* for `finish`; it cannot stop it. So the
/// fallback and the late finisher both want to write the same file, and
/// the late one used to win — over a record the user had already been
/// shown, with `incomplete` dropped and the audio deleted, and carrying a
/// summary request that was cancelled with the task.
struct RecordOwnershipTests {

    private struct Notes: MeetingBrain {
        func complete(system: String, user: String) async throws -> String {
            #"{"title":"T","summary":"S","decisions":[],"action_items":[],"open_questions":[]}"#
        }
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["system.wav", "mic.wav"] {
            try Data("not really audio".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test func onlyTheFirstCallerEverGetsTheClaim() {
        let claim = RecordClaim()
        #expect(claim.claim())
        #expect(!claim.claim())
        #expect(!claim.claim())
    }

    /// The fallback has written. `finish` comes back afterwards: it must
    /// write nothing at all — not the record, not `summary.md`, and it must
    /// not delete the audio the fallback deliberately kept.
    @Test func aLateFinishWritesNothingOverTheFallbacksRecord() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // What the fallback left behind.
        let fallback = #"{"startedAt":"2026-08-30T18:27:03Z","durationSeconds":95,"folder":"\#(dir.path)","incomplete":true,"summaryFailure":"writing the notes did not finish within 300 s"}"#
        try Data(fallback.utf8).write(to: dir.appendingPathComponent("meeting.json"))
        let claim = RecordClaim()
        #expect(claim.claim())                                  // the fallback took it

        let out = await MeetingSummary.write(
            folder: dir, segments: [Segment(start: 0, end: 1, speaker: .them(1), text: "hello")],
            startedAt: Date(), duration: 95,
            drift: DriftReport(systemSeconds: 95, micSeconds: 95, wallSeconds: 95),
            brain: Notes(), summarise: true, deleteRecordings: true, claim: claim)

        #expect(!out.wroteRecord)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.wav").path))
        // The record on disk is still the fallback's, `incomplete` and all.
        let onDisk = try MeetingRecord.load(dir.appendingPathComponent("meeting.json"))
        #expect(onDisk.incomplete)
        #expect(!onDisk.summarised)
        #expect(onDisk.summaryFailure?.contains("did not finish") == true)
    }

    /// With the claim free — the ordinary path, and every caller that
    /// passes none — `write` behaves exactly as it did.
    @Test func anUnclaimedRecordIsWrittenAsBefore() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await MeetingSummary.write(
            folder: dir, segments: [Segment(start: 0, end: 1, speaker: .them(1), text: "hello")],
            startedAt: Date(), duration: 95,
            drift: DriftReport(systemSeconds: 95, micSeconds: 95, wallSeconds: 95),
            brain: Notes(), summarise: true, deleteRecordings: false, claim: RecordClaim())
        #expect(out.wroteRecord)
        #expect(out.record.summarised)
        #expect(out.record.summaryFile == "summary.md")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting.json").path))
    }
}
