import Foundation
import Testing
@testable import MoeMeeting

/// The shared Core Audio reading, held to how many times it actually asks
/// the daemon.
///
/// "Did it return signals" is a check that cannot fail — a cache that has
/// silently stopped caching returns exactly the same signals as one that is
/// working. So every test here counts reads through an injected reader, and
/// the counts are the assertions.
///
/// Serialised because the cache is process-wide state.
@Suite(.serialized)
struct ProcessSignalCacheTests {

    private let sample = [
        CallSignal(bundleID: "us.zoom.xos", input: true, output: true),
        CallSignal(bundleID: "com.apple.Safari", input: false, output: true),
    ]

    private func fresh() { ProcessList.Signals.invalidate(resettingCount: true) }

    /// The case that had `coreaudiod` at 12% of a core with Moe idle: two
    /// timers on different clocks, both asking, neither seeing the other's
    /// answer. A minute of the real cadence — `MeetingWatcher` at 1.5 s and
    /// `AudioFrontEnd.watchCallApps` at 2 s — is 40 + 30 = 70 polls.
    @Test func twoTimersOnDifferentClocksShareOneReading() {
        fresh()
        var reads = 0
        let reader: () -> [CallSignal] = { reads += 1; return self.sample }
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        var moments: [Double] = []
        moments += stride(from: 0.0, to: 60.0, by: 1.5)
        moments += stride(from: 0.0, to: 60.0, by: 2.0)
        moments.sort()

        for at in moments {
            _ = ProcessList.Signals.current(now: t0.addingTimeInterval(at), read: reader)
        }

        #expect(moments.count == 70)
        #expect(reads < moments.count)
        #expect(reads <= 50)
    }

    /// The optimisation must not buy call-detection latency: `maxAge` is
    /// under `MeetingWatcher`'s 1.5 s, so the fastest poll always reads.
    @Test func theFastestPollAlwaysGetsAFreshReading() {
        fresh()
        #expect(ProcessList.Signals.maxAge < 1.5)

        var reads = 0
        let reader: () -> [CallSignal] = { reads += 1; return self.sample }
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<20 {
            _ = ProcessList.Signals.current(now: t0.addingTimeInterval(Double(i) * 1.5), read: reader)
        }
        #expect(reads == 20)
    }

    /// Inside the window the daemon is asked once however many callers
    /// arrive, and they all get the same answer.
    @Test func callersInsideTheWindowShareOneRead() {
        fresh()
        var reads = 0
        let reader: () -> [CallSignal] = { reads += 1; return self.sample }
        let t0 = Date(timeIntervalSinceReferenceDate: 100)

        let a = ProcessList.Signals.current(now: t0, read: reader)
        let b = ProcessList.Signals.current(now: t0.addingTimeInterval(0.3), read: reader)
        let c = ProcessList.Signals.current(now: t0.addingTimeInterval(1.19), read: reader)
        #expect(reads == 1)
        #expect(a.map(\.bundleID) == b.map(\.bundleID))
        #expect(b.map(\.bundleID) == c.map(\.bundleID))

        _ = ProcessList.Signals.current(now: t0.addingTimeInterval(1.21), read: reader)
        #expect(reads == 2)
    }

    /// A cached answer must not survive a clock going backwards — a wake
    /// from sleep, or a time change. Stale here means Moe believes a call
    /// app still holds the microphone when it does not, and turns echo
    /// cancellation back on under a live call.
    @Test func aClockGoingBackwardsForcesARead() {
        fresh()
        var reads = 0
        let reader: () -> [CallSignal] = { reads += 1; return self.sample }
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        _ = ProcessList.Signals.current(now: t0, read: reader)
        #expect(reads == 1)
        _ = ProcessList.Signals.current(now: t0.addingTimeInterval(-30), read: reader)
        #expect(reads == 2)
    }

    /// `invalidate()` must drop the reading, not just the count.
    @Test func invalidateForcesTheNextRead() {
        fresh()
        var reads = 0
        let reader: () -> [CallSignal] = { reads += 1; return self.sample }
        let t0 = Date(timeIntervalSinceReferenceDate: 500)
        _ = ProcessList.Signals.current(now: t0, read: reader)
        ProcessList.Signals.invalidate()
        _ = ProcessList.Signals.current(now: t0.addingTimeInterval(0.1), read: reader)
        #expect(reads == 2)
    }

    /// The counter is the only thing every test above can fail on, so it has
    /// to be real: it moves on a read and not on a hit.
    @Test func theReadCounterTracksActualReads() {
        fresh()
        let t0 = Date(timeIntervalSinceReferenceDate: 2_000)
        #expect(ProcessList.Signals.readsPerformed == 0)
        _ = ProcessList.Signals.current(now: t0, read: { self.sample })
        #expect(ProcessList.Signals.readsPerformed == 1)
        _ = ProcessList.Signals.current(now: t0.addingTimeInterval(0.5), read: { self.sample })
        #expect(ProcessList.Signals.readsPerformed == 1)
        _ = ProcessList.Signals.current(now: t0.addingTimeInterval(2.0), read: { self.sample })
        #expect(ProcessList.Signals.readsPerformed == 2)
    }
}
