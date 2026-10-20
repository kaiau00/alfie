import Foundation
import Testing
@testable import MoeVoice

/// Moe going silent mid-sentence: 67 s on 2026-09-29 20:49, 36 s and 41 s on
/// 09-25, because nothing watched the premium voice's stream
/// (`~/moe-voice-notes/audit-2026-09-29/audit-cutoffs.md`).
struct TtsStallGuardTests {

    private let t0 = Date(timeIntervalSince1970: 1_759_176_000)

    // MARK: - The rule

    @Test("no audio at all: fine up to the deadline, stalled at it")
    func beforeAudio() {
        let watch = TtsStallWatch(began: t0)
        #expect(watch.verdict(now: t0.addingTimeInterval(2.9), bufferedSeconds: 0) == .fine)
        #expect(watch.verdict(now: t0.addingTimeInterval(3.0), bufferedSeconds: 0)
                == .stalledBeforeAudio(seconds: 3.0))
    }

    @Test("a slow chunk with plenty buffered is inaudible and left alone")
    func slowChunkWithBuffer() {
        var watch = TtsStallWatch(began: t0)
        watch.audio(at: t0.addingTimeInterval(0.2))
        #expect(watch.verdict(now: t0.addingTimeInterval(1.5), bufferedSeconds: 1.2) == .fine)
    }

    @Test("a gap while the player runs dry is a stall within a second")
    func gapWithEmptyPlayer() {
        var watch = TtsStallWatch(began: t0)
        watch.audio(at: t0.addingTimeInterval(0.25))
        #expect(watch.verdict(now: t0.addingTimeInterval(1.0), bufferedSeconds: 0.125) == .fine)
        #expect(watch.verdict(now: t0.addingTimeInterval(1.25), bufferedSeconds: 0.125)
                == .stalledMidStream(seconds: 1.0))
    }

    @Test("however much is buffered, a stream silent for the hard gap is over")
    func hardGap() {
        var watch = TtsStallWatch(began: t0)
        watch.audio(at: t0)
        #expect(watch.verdict(now: t0.addingTimeInterval(3.9), bufferedSeconds: 30) == .fine)
        #expect(watch.verdict(now: t0.addingTimeInterval(4.0), bufferedSeconds: 30)
                == .stalledMidStream(seconds: 4.0))
    }

    @Test("a finished render is never a stall")
    func finished() {
        var watch = TtsStallWatch(began: t0)
        watch.finish()
        #expect(watch.verdict(now: t0.addingTimeInterval(100), bufferedSeconds: 0) == .fine)
    }

    @Test("a stall is a dropped connection, so it is one quiet episode and never an error")
    func stallIsAConnectionDrop() {
        #expect(PremiumVoiceReconnect.isConnectionDrop(TtsStalled(.stalledMidStream(seconds: 1))))
    }

    // MARK: - The guard, against streams that misbehave

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    private func drain(_ stream: AsyncThrowingStream<[Float], Error>) async -> (frames: Int, error: Error?) {
        var frames = 0
        do {
            for try await _ in stream { frames += 1 }
            return (frames, nil)
        } catch {
            return (frames, error)
        }
    }

    @Test("a render whose start hangs — the 46.9 s credential — is ended, not waited for")
    func hungStart() async {
        let clock = Clock(t0)
        let stream = TtsStallGuard.wrap(pollEvery: 0.01, now: { clock.now }, bufferedSeconds: { 0 }) {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return AsyncThrowingStream { $0.finish() }
        }
        Task { try? await Task.sleep(nanoseconds: 50_000_000); clock.advance(3.1) }
        let began = Date()
        let result = await drain(stream)
        // Loose on purpose: the whole suite runs in parallel on a busy Mac.
        // What matters is that it did not wait out the 60 s start.
        #expect(Date().timeIntervalSince(began) < 30)
        guard case .stalledBeforeAudio = (result.error as? TtsStalled)?.verdict else {
            Issue.record("expected a stall before audio, got \(String(describing: result.error))")
            return
        }
    }

    @Test("a stream that goes quiet mid-sentence with the player dry is ended")
    func midStreamStall() async {
        let clock = Clock(t0)
        let (inner, feed) = AsyncThrowingStream<[Float], Error>.makeStream()
        let stream = TtsStallGuard.wrap(pollEvery: 0.01, now: { clock.now }, bufferedSeconds: { 0 }) { inner }
        feed.yield([0, 0, 0])
        Task { try? await Task.sleep(nanoseconds: 100_000_000); clock.advance(1.5) }
        let result = await drain(stream)
        #expect(result.frames == 1)
        guard case .stalledMidStream = (result.error as? TtsStalled)?.verdict else {
            Issue.record("expected a mid-stream stall, got \(String(describing: result.error))")
            return
        }
    }

    @Test("a healthy stream passes through untouched, and its own error keeps its type")
    func healthyAndOwnErrors() async {
        let clock = Clock(t0)
        let ok = TtsStallGuard.wrap(pollEvery: 0.01, now: { clock.now }, bufferedSeconds: { 0 }) {
            AsyncThrowingStream { c in c.yield([1]); c.yield([2]); c.finish() }
        }
        let good = await drain(ok)
        #expect(good.frames == 2 && good.error == nil)

        struct Refused: Error {}
        let bad = TtsStallGuard.wrap(pollEvery: 0.01, now: { clock.now }, bufferedSeconds: { 0 }) {
            throw Refused()
        }
        #expect(await drain(bad).error is Refused)
    }

    // MARK: - Where the local voice picks up

    @Test("what already reached the player is not said again; the piece that did not finish is")
    func resume() {
        // Three 50-character pieces at 1,000 samples a character, 24 kHz.
        let lengths = [50, 50, 50]
        #expect(SpeechResume.partsDelivered(lengths: lengths, samplesScheduled: 0,
                                            samplesPerChar: 1_000, sampleRate: 24_000) == 0)
        // 120,000 samples: the first two end at 50k and 101k, inside the
        // 108k that is 0.5 s short of the end.
        #expect(SpeechResume.partsDelivered(lengths: lengths, samplesScheduled: 120_000,
                                            samplesPerChar: 1_000, sampleRate: 24_000) == 2)
        // 110,000: the second ends at 101k, past 98k — repeated, not skipped.
        #expect(SpeechResume.partsDelivered(lengths: lengths, samplesScheduled: 110_000,
                                            samplesPerChar: 1_000, sampleRate: 24_000) == 1)
        // The last piece is never taken as delivered: the stream failed
        // before its end arrived.
        #expect(SpeechResume.partsDelivered(lengths: lengths, samplesScheduled: 10_000_000,
                                            samplesPerChar: 1_000, sampleRate: 24_000) == 2)
    }
}
