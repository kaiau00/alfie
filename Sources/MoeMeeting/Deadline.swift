import Foundation

// MARK: - How long the end of a meeting is allowed to take

/// The wall-clock budget for `MeetingSession.finish`, in seconds.
///
/// It has to scale with the recording, because one of the three costs
/// inside `finish` does. A flat 180 s — which is what this was — does not
/// survive a real meeting:
///
///   * diarization runs over the *whole* system stream at ~0.03× realtime
///     (MEETING-MODE.md, "about 110 s for an hour"): an hour costs ~110 s
///     and two hours ~220 s, and the second of those is already past three
///     minutes before anything else has run;
///   * `HermesMeetingBrain` allows the summary request 180 s
///     (`timeoutIntervalForResource`), so a flat 180 s outer deadline can
///     never let the inner one report a real failure — it fires first,
///     always, whatever the meeting's length;
///   * the Parakeet model load is 12.5–12.9 s warm, on top of both.
///
/// So: a base that clears the summary's own ceiling and the model load
/// with slack, plus three times the measured diarization rate. This is a
/// hang detector, not a progress bar — it should only ever fire when
/// something has genuinely stopped responding.
public enum MeetingFinishBudget {
    /// Model load + the summary's own 180 s ceiling + slack.
    public static let base: Double = 240
    /// Three times the measured 0.03× realtime diarization.
    public static let perRecordedSecond: Double = 0.1
    /// However long the recording, an hour of waiting is past the point
    /// where this is a hang detector — and an hour still covers ten hours
    /// of diarization at the measured rate.
    public static let ceiling: Double = 3600

    /// 10 min of meeting → 5 min; 1 h → 10 min; 2 h → 16 min.
    ///
    /// `duration` comes from `recorder.elapsed`, a clock difference: a
    /// negative, a NaN or an infinity must give the base rather than a
    /// deadline that fires immediately or never.
    public static func seconds(recorded duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return base }
        return Swift.min(ceiling, base + perRecordedSecond * duration)
    }
}

// MARK: - One owner for meeting.json

/// Which of the two ends of a meeting owns `meeting.json`.
///
/// `Deadline.run` stops *waiting* for `finish`; it cannot stop it. So when
/// the budget fires there are two writers for one file: the fallback
/// (`MeetingSession.transcriptOnlyOutcome`), which writes immediately and
/// is what the panel, the Meetings tab, the agent's memory and any
/// Telegram delivery are all built from — and `finish`, still running,
/// which writes whenever it finally returns.
///
/// The late one used to win, silently, and it is the worse record: its
/// summary request was cancelled with the task, so it says "brain
/// unavailable", it has no `incomplete` flag, and it deletes the audio the
/// fallback deliberately kept. The user was left reading "Writing the
/// notes took too long" over a different meeting.
///
/// First writer wins, and after that nothing on disk moves. The fallback
/// runs at the deadline and `finish` by definition later, so in practice
/// the fallback wins; the claim exists for the one ordering where it does
/// not — `finish` writing in the moments before the box settles — and
/// there the fallback adopts the record it finds rather than replacing it.
public final class RecordClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    public init() {}

    /// True for the first caller and only the first caller.
    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

// MARK: - A deadline on work that has no timeout of its own

/// Runs an async job with a wall-clock deadline, returning nil when it is
/// not done in time.
///
/// `MeetingTranscriber.finish` loads models, recognises the tail of the
/// recording and diarizes the whole system stream. None of those have a
/// timeout: if one of them never returns, the meeting parks at `.stopping`
/// and the panel says "Writing your notes…" for as long as the app runs,
/// with no way out and no notes.
///
/// The job is *not* structured-concurrency-cancelled away — an ASR call
/// that has stopped responding will not notice cancellation — so this
/// deliberately stops *waiting* rather than pretending to stop the work.
/// The caller falls back to what is already on disk, and that record then
/// stands: see `RecordClaim` for why the late finisher must not overwrite
/// it.
public enum Deadline {
    public static func run<T: Sendable>(seconds: Double,
                                        _ work: @escaping @Sendable () async -> T) async -> T? {
        let box = DeadlineBox<T>()
        let worker = Task { let value = await work(); box.settle(value) }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(Swift.max(0, seconds) * 1_000_000_000))
            box.settle(nil)
        }
        let out = await box.wait()
        worker.cancel()
        timer.cancel()
        return out
    }
}

/// Whichever of the two tasks gets there first wins, exactly once.
final class DeadlineBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var settled = false
    private var pending: T??

    func settle(_ value: T?) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let c = continuation
        continuation = nil
        if c == nil { pending = .some(value) }
        lock.unlock()
        c?.resume(returning: value)
    }

    func wait() async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            lock.lock()
            if let p = pending {
                pending = nil
                lock.unlock()
                c.resume(returning: p)
                return
            }
            continuation = c
            lock.unlock()
        }
    }
}
