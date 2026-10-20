import Foundation

/// A premium-voice render that has stopped producing sound, noticed in about
/// a second instead of whenever the operating system gets round to it.
///
/// Measured 2026-09-29 (`~/moe-voice-notes/audit-2026-09-29/audit-cutoffs.md`):
/// at 20:49:35 Moe began "Watchdog script works (…)", the person heard 2.6 s
/// of it, and then **67 s of silence** before the socket was finally reported
/// dead and the sentence went to the local voice. On 09-25 a socket that was
/// already dead held the first word back for 36 s, and a credential request
/// that hung for 46.9 s left Moe "speaking" with no sound for 41 s. Nothing
/// watched the stream: every Moe connection on that Mac goes through a local
/// filter proxy, so the far side dying never reaches the socket as an error.
///
/// The rule, kept apart from the audio so it is a test and not a belief:
/// - **Before any audio**: past `firstAudioDeadline` from the start of the
///   render — credential, connect and all — it is stalled. 1,027 renders
///   measured from 09-23 to 09-29: p99 2.6 s from start to first audio, and
///   every one past 3 s was one of the hangs above or a local warm-up.
/// - **Mid-stream**: no new audio for `gapDeadline` while the player holds
///   less than `lowBuffer` — the person is about to hear, or is hearing, a
///   hole. With plenty buffered a slow chunk is inaudible and left alone,
///   up to `hardGap`, past which a stream that has not finished never will.
public struct TtsStallWatch: Sendable, Equatable {

    public static let firstAudioDeadline: TimeInterval = 3.0
    public static let gapDeadline: TimeInterval = 1.0
    public static let lowBuffer: TimeInterval = 0.3
    public static let hardGap: TimeInterval = 4.0

    public enum Verdict: Equatable, Sendable {
        case fine
        /// No audio at all since the render began, for this long.
        case stalledBeforeAudio(seconds: TimeInterval)
        /// Audio stopped arriving mid-render, for this long.
        case stalledMidStream(seconds: TimeInterval)
    }

    public let began: Date
    public private(set) var lastAudio: Date?
    public private(set) var finished = false

    public init(began: Date) { self.began = began }

    /// A chunk of audio arrived.
    public mutating func audio(at time: Date) { lastAudio = time }

    /// The render ended on its own — nothing more to watch.
    public mutating func finish() { finished = true }

    /// - Parameter bufferedSeconds: audio scheduled on the player and not yet
    ///   played — how long the person will go on hearing sound if nothing
    ///   more arrives.
    public func verdict(now: Date, bufferedSeconds: TimeInterval) -> Verdict {
        guard !finished else { return .fine }
        guard let last = lastAudio else {
            let waited = now.timeIntervalSince(began)
            return waited >= Self.firstAudioDeadline ? .stalledBeforeAudio(seconds: waited) : .fine
        }
        let gap = now.timeIntervalSince(last)
        if gap >= Self.hardGap { return .stalledMidStream(seconds: gap) }
        if gap >= Self.gapDeadline, bufferedSeconds < Self.lowBuffer { return .stalledMidStream(seconds: gap) }
        return .fine
    }
}

/// What `TtsStallGuard` throws: a connection failure for every rule that
/// cares (`PremiumVoiceReconnect`), so it is one quiet episode and never a
/// "couldn't speak that".
public struct TtsStalled: Error, PremiumVoiceConnectionFailure, CustomStringConvertible, Equatable {
    public let verdict: TtsStallWatch.Verdict
    public var isConnectionDrop: Bool { true }
    public init(_ verdict: TtsStallWatch.Verdict) { self.verdict = verdict }
    public var description: String {
        switch verdict {
        case .stalledBeforeAudio(let s): return "stalled: no audio \(String(format: "%.1f", s)) s after the render began"
        case .stalledMidStream(let s): return "stalled: no audio for \(String(format: "%.1f", s)) s mid-sentence"
        case .fine: return "stalled"
        }
    }
}

/// Wraps a render so a stall ends it with `TtsStalled` rather than silence.
///
/// The render's own start — the credential, the socket — happens *inside*
/// the guarded stream, because that is where the 46.9 s hang was. When the
/// guard trips, whatever the render later produces is dropped, and dropping
/// its stream is what tells the cloud voice to stop generating.
public enum TtsStallGuard {

    public static func wrap(
        pollEvery poll: TimeInterval = 0.1,
        now: @escaping @Sendable () -> Date = { Date() },
        bufferedSeconds: @escaping @Sendable () async -> TimeInterval,
        start: @escaping @Sendable () async throws -> AsyncThrowingStream<[Float], Error>
    ) -> AsyncThrowingStream<[Float], Error> {
        let (out, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let state = WatchBox(TtsStallWatch(began: now()))
        let producer = Task {
            do {
                let inner = try await start()
                for try await frame in inner {
                    guard await state.open else { break }
                    await state.audio(at: now())
                    continuation.yield(frame)
                }
                if await state.close() { continuation.finish() }
            } catch {
                if await state.close() { continuation.finish(throwing: error) }
            }
        }
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                guard await state.open else { return }
                let buffered = await bufferedSeconds()
                let verdict = await state.watch.verdict(now: now(), bufferedSeconds: buffered)
                if verdict != .fine, await state.close() {
                    producer.cancel()
                    continuation.finish(throwing: TtsStalled(verdict))
                    return
                }
            }
        }
        continuation.onTermination = { _ in
            producer.cancel()
            watchdog.cancel()
        }
        return out
    }

    /// The watch, and whether the wrapped stream is still being fed — the
    /// first of the producer and the watchdog to close it decides how it
    /// ends.
    private actor WatchBox {
        var watch: TtsStallWatch
        var open = true
        init(_ watch: TtsStallWatch) { self.watch = watch }
        func audio(at time: Date) { watch.audio(at: time) }
        /// True for the one caller that closed it.
        func close() -> Bool {
            guard open else { return false }
            open = false
            watch.finish()
            return true
        }
    }
}

/// Where to pick a failed cloud batch up on the local engine, so the person
/// does not hear again what they have just heard.
///
/// On 2026-09-29 at 20:50 the socket died 2.6 s into a sentence and the local
/// voice started it again from the top; on 20:08 a 556-character batch was
/// re-spoken whole. Audio already handed to the player is going to play, so
/// every sentence of the batch whose audio is *entirely* in that audio is
/// done; the fallback starts at the first one that is not.
///
/// Where a sentence ends in the audio is estimated from characters, as
/// `SpeechBatch.partEnds` does, at the rate this voice has actually been
/// speaking. The estimate errs toward repeating: a sentence counts as
/// delivered only when its estimated end sits `marginSeconds` inside the
/// audio already scheduled. A repeated half-sentence is a stumble; a
/// skipped one is a hole.
public enum SpeechResume {

    public static let marginSeconds: Double = 0.5

    /// - Returns: how many leading parts are already fully in the scheduled
    ///   audio and must not be rendered again.
    public static func partsDelivered(lengths: [Int], samplesScheduled: Int,
                                      samplesPerChar: Double, sampleRate: Double,
                                      marginSeconds: Double = marginSeconds) -> Int {
        guard samplesScheduled > 0, samplesPerChar > 0 else { return 0 }
        let usable = Double(samplesScheduled) - marginSeconds * sampleRate
        var cumulative = 0
        var delivered = 0
        for (i, n) in lengths.enumerated() {
            // Parts are joined with a space in the batch.
            cumulative += n + (i == 0 ? 0 : 1)
            guard Double(cumulative) * samplesPerChar <= usable else { break }
            delivered = i + 1
        }
        // The last part can never be "delivered" by an estimate: the stream
        // failed, so its end did not arrive.
        return min(delivered, max(0, lengths.count - 1))
    }
}
