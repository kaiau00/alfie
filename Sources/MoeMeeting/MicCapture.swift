import Accelerate
import AVFoundation
import Foundation
import MoeObjC

// Microphone side of a meeting: its own AVAudioEngine input with voice
// processing on. Without echo cancellation the mic hears the speakers and
// "them" is transcribed twice (once as "you"); with it the leak drops to
// -55…-70 dBFS (MEETING-MODE.md). Resampled to 16 kHz mono on the way to
// the sink.

public final class MicCapture {
    public let sink: SampleSink
    /// A second reader of the 16 kHz mono buffers, beside the sink: the
    /// app's own recogniser while the user whispers to Moe with the hold
    /// key (MEETING-MODE.md, Phase A2). One engine on the microphone, two
    /// consumers — never a second `AVAudioEngine` on the same input.
    public let forward = BufferForward()
    private let engine = AVAudioEngine()
    private var resampler: Resampler?
    public private(set) var inputFormat: AVAudioFormat?
    /// The input device the engine actually opened, read back from the
    /// audio unit after `start` — not the one we asked for, because we ask
    /// for nothing and take the system default, and the system default is
    /// exactly what silently becomes a phone in a pocket.
    public private(set) var device: AudioDeviceInfo?
    /// How the bus was reduced to mono: voice processing hands back the
    /// processed mic plus the canceller's reference channels, and taking
    /// the wrong one is a plausible way to record near-silence.
    public private(set) var channelPath = ""
    /// Input channels the device itself has, read from the HAL. Printed
    /// beside the bus width because the two disagreeing is the whole
    /// question: a device with one input channel behind a seven-channel
    /// voice-processing bus means six of those seven are not the microphone.
    public private(set) var deviceInputChannels = 0
    /// Per-channel energy on the raw bus, accumulated in the tap. This is
    /// the only thing that can say which channel the microphone is on, and
    /// it costs one multiply-accumulate per sample.
    private var levels: ChannelLevels?
    /// When the tap last delivered a buffer, and since when every buffer
    /// has been exactly zero — the two ways a microphone dies under a
    /// running engine. Written on the audio thread, read by `watchdog`.
    private let pulse = MicPulse()
    private var observer: NSObjectProtocol?
    private var lastRestart: TimeInterval = 0
    /// Times the input was rebuilt mid-meeting. For the log and the tests.
    public private(set) var restarts = 0
    /// One line per rebuild, for the caller's log.
    public var onEvent: ((String) -> Void)?

    public init(sink: SampleSink, echoCancel: Bool = true) {
        self.sink = sink
        self.echoCancelWanted = echoCancel
        self.echoCancel = echoCancel
    }

    // MARK: - Not over a call
    //
    // Voice processing is not a filter on our copy of the microphone: it
    // switches the built-in microphone itself into its multi-channel raw
    // mode, for every process. Measured on 2026-09-02 with a raw Core Audio
    // input client standing in for Telegram (whose WebRTC engine reads the
    // device that way): the moment `setVoiceProcessingEnabled(true)` ran in
    // another process, the device's input stream went from 1 to 3 channels
    // and the client's audio fell from -25 dBFS to -57 dBFS — the far end
    // stopped hearing the user — and came back the instant the voice
    // processing was released. Which is exactly the report: "on the
    // MacBook mic nobody hears me during a meeting, and the moment I stop
    // the meeting they do." Two voice-processing clients coexist (FaceTime,
    // Zoom); a plain input beside a voice-processing one does not.
    //
    // So echo cancellation is only used when no call app has the
    // microphone: an in-person meeting, a recording of a video. While a
    // call app holds it — at start, or when one arrives mid-meeting — the
    // input is plain, the call keeps the user's voice, and the mic hears
    // the speakers, which the timeline already tolerates (headphone users
    // never had the leak either).

    /// Echo cancellation as asked for by the caller.
    ///
    /// Not a `let` any more: `dropEchoCancellation` clears it for the rest
    /// of the meeting when the call-audio tap turns out to be the thing
    /// paying for it. Without that, every `restart` — the watchdog's, the
    /// configuration-change observer's — would switch voice processing back
    /// on and kill the tap again.
    public private(set) var echoCancelWanted: Bool
    /// The call app the microphone was left plain for, by name.
    public private(set) var echoCancelHeldBy: String?
    /// The live check, replaceable for tests.
    var callsOnMicrophone: () -> [CallApp] = { CallApps.holdingMicrophone() }
    private var lastCallCheck: TimeInterval = 0
    /// How often the watchdog asks Core Audio who has the microphone.
    public var callCheckEvery: TimeInterval = 2

    // MARK: - Staying alive
    //
    // A 78-minute recording on 2026-09-02 had a working microphone for
    // twelve minutes and −∞ dBFS for the remaining sixty-six. Nothing had
    // crashed: the engine was still "running", the tap was still
    // installed, and another app taking a call on the same input had
    // simply left this graph with nothing to deliver. Nothing noticed
    // except the health line, which only wrote "mic silent" every few
    // minutes. Two things fix that: the system's own word that the audio
    // configuration changed under the engine, and, because that word does
    // not always come, a watchdog on the buffers themselves.

    /// Every buffer's arrival and whether it carried any sound at all.
    /// Cheap: a max-magnitude over one channel per callback.
    final class MicPulse: @unchecked Sendable {
        private let lock = NSLock()
        private var lastBuffer: TimeInterval = 0
        private var zeroSince: TimeInterval?

        func note(_ buffer: AVAudioPCMBuffer, at now: TimeInterval) {
            var peak: Float = 0
            if let p = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                vDSP_maxmgv(p, 1, &peak, vDSP_Length(buffer.frameLength))
            }
            lock.lock()
            lastBuffer = now
            if peak > 0 { zeroSince = nil } else if zeroSince == nil { zeroSince = now }
            lock.unlock()
        }

        func reset(at now: TimeInterval) {
            lock.lock(); lastBuffer = now; zeroSince = nil; lock.unlock()
        }

        /// Seconds since a buffer arrived, and seconds of unbroken zeros.
        func read(at now: TimeInterval) -> (sinceBuffer: TimeInterval, zeros: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            return (now - lastBuffer, zeroSince.map { now - $0 } ?? 0)
        }
    }

    /// No buffer for this long means the graph is dead, whatever
    /// `engine.isRunning` says.
    public var stallSeconds: TimeInterval = 5
    /// Exact zeros for this long means the input is delivering nothing —
    /// a real room is never digitally silent; a muted microphone is, and
    /// a rebuild every minute costs it nothing.
    public var deadSilenceSeconds: TimeInterval = 20
    /// Never rebuild more often than this: a rebuild is a ~100 ms gap.
    public var restartCooldown: TimeInterval = 60

    /// Called on a timer by whoever owns the meeting. Rebuilds the input
    /// when it has stopped delivering; returns the line to log, if any.
    public func watchdog(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        guard inputFormat != nil else { return nil }
        // A call that began after the meeting did: give it the microphone
        // back at once — no cooldown, this is the far end hearing nothing.
        if echoCancel, now - lastCallCheck >= callCheckEvery {
            lastCallCheck = now
            if let app = callsOnMicrophone().first {
                return restart(because: "\(app.name) is on the microphone, echo cancellation off so it hears you", at: now)
            }
        }
        guard now - lastRestart >= restartCooldown else { return nil }
        let p = pulse.read(at: now)
        let why: String
        if p.sinceBuffer > stallSeconds {
            why = String(format: "no microphone audio for %.0f s", p.sinceBuffer)
        } else if p.zeros > deadSilenceSeconds {
            why = String(format: "microphone dead silent for %.0f s", p.zeros)
        } else {
            return nil
        }
        return restart(because: why, at: now)
    }

    /// Tear the input down and build it again on whatever the default
    /// input is now. The sink keeps its position; the forward keeps its
    /// consumer. Returns the line to log.
    @discardableResult
    public func restart(because why: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
        lastRestart = now
        restarts += 1
        let handler = forward.handler
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pulse.reset(at: now)
        do {
            try start()
            forward.handler = handler
            let line = "microphone restarted (\(why)) — now \(description)"
            onEvent?(line)
            return line
        } catch {
            let line = "microphone restart failed (\(why)): \(error.localizedDescription)"
            onEvent?(line)
            return line
        }
    }

    /// Give up echo cancellation for the rest of this meeting, and rebuild
    /// the input without it.
    ///
    /// The one thing that is worth more than a clean microphone is hearing
    /// the other side of the call at all. Voice processing in this process
    /// makes the meeting tap deliver digital silence (`TapWatch`), and a
    /// meeting with no call audio labels every voice in the room as the
    /// user — which is worse than the leak this was cancelling, and unlike
    /// the leak it cannot be repaired afterwards.
    ///
    /// Returns the line to log, or nil when it was already off.
    @discardableResult
    public func dropEchoCancellation() -> String? {
        guard echoCancelWanted else { return nil }
        echoCancelWanted = false
        guard inputFormat != nil else { return nil }
        return restart(because: "the call audio was silent while echo cancellation was on")
    }

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
        }
    }

    /// Echo cancellation on the mic, as actually running. Without it the
    /// mic hears the speakers, and "them" leaks into "you" whenever the
    /// user is not on headphones; with it, no call app hears the user at
    /// all (see "Not over a call"), so it is `echoCancelWanted` minus any
    /// call app on the microphone.
    public private(set) var echoCancel: Bool

    public func start() throws {
        let input = engine.inputNode
        let calls = callsOnMicrophone()
        echoCancelHeldBy = calls.first?.name
        echoCancel = echoCancelWanted && calls.isEmpty
        lastCallCheck = ProcessInfo.processInfo.systemUptime
        if !echoCancel, input.isVoiceProcessingEnabled {
            // A restart after a call arrived: the unit is still in voice
            // processing mode from the last start. Off, while stopped.
            try input.setVoiceProcessingEnabled(false)
            if engine.outputNode.isVoiceProcessingEnabled {
                try engine.outputNode.setVoiceProcessingEnabled(false)
            }
        }
        if echoCancel {
            // Same recipe AudioGate proved: enable while stopped, before the
            // graph is built. Output node must be in the graph for VPIO to
            // have a reference path, so connect a silent mixer to it.
            try input.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
            // VPIO ducks every other app's audio by default (macOS 14+).
            // In a meeting that is the call itself — turn it off.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false,
                                                                      duckingLevel: .min)
            let hw = engine.outputNode.inputFormat(forBus: 0)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hw)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TapError("no microphone input format (is a mic connected?)")
        }
        inputFormat = format
        // Voice processing hands back a bus wider than the microphone:
        // the processed mic plus the canceller's reference channels. Which
        // index the microphone lands on is **not** documented anywhere we
        // have found, and it is not stable — `VoiceEngine.buildGraph` records
        // 3 channels on one run and 7 on another on this same machine, whose
        // input device has one input channel and whose output device has two.
        //
        // Channel 0 is what this has always taken, and the spike's own
        // recording says it was right there: `scripts/fixtures/meeting/mic.wav`
        // carries the far end at -18 dBFS for the first second and then drops
        // 45 dB as the canceller converges, which is the signature of an
        // echo-cancelled microphone and not of a speaker reference feed (that
        // would have stayed loud for the whole eight seconds, as system.wav
        // did). So channel 0 is kept — changing a capture path that has
        // produced real audio, on a hypothesis, is how you lose the next
        // meeting too.
        //
        // What is added instead is the measurement that settles it: every
        // channel's level is accumulated in the tap and reported, so one
        // line of the next meeting's log says which channel the microphone
        // is actually on. See `channelReport()`.
        let takeChannel0 = format.channelCount > 2
        channelPath = takeChannel0
            ? "channel 0 of \(format.channelCount) (voice-processing bus)"
            : format.channelCount == 1 ? "mono" : "downmix of \(format.channelCount)"
        levels = ChannelLevels(channels: Int(format.channelCount))
        let sourceFormat = takeChannel0
            ? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            : format
        guard let r = Resampler(from: sourceFormat) else {
            throw TapError("no converter from \(sourceFormat) to 16 kHz mono")
        }
        resampler = r
        let sink = self.sink
        let forward = self.forward
        // One mono scratch buffer for the channel-0 copy, reused: the tap
        // block must not allocate per callback.
        let scratch = takeChannel0 ? AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 8192) : nil
        // Tap with the bus's own format (see AudioGate: a mono format on a
        // multi-channel bus is a mismatch, not a downmix request).
        let levels = self.levels
        let pulse = self.pulse
        pulse.reset(at: ProcessInfo.processInfo.systemUptime)
        // Through MoeObjC: `installTapOnBus:` raises an Objective-C exception
        // on a format mismatch after a device change, and one unwinding
        // through the watchdog's Task corrupted the executor and crashed the
        // app later (2026-09-30 15:57). As a thrown error it reaches
        // `restart`'s catch, which logs "microphone restart failed".
        try MoeObjC.catchException {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            pulse.note(buffer, at: ProcessInfo.processInfo.systemUptime)
            levels?.add(buffer)
            var source = buffer
            if takeChannel0 {
                guard let mono = scratch, buffer.frameLength <= mono.frameCapacity,
                      let src = buffer.floatChannelData?[0], let dst = mono.floatChannelData?[0]
                else { return }
                mono.frameLength = buffer.frameLength
                dst.update(from: src, count: Int(buffer.frameLength))
                source = mono
            }
            guard let mono = r.convert(source) else { return }
            sink.append(mono)
            forward.deliver(mono)
        }
        }
        engine.prepare()
        try engine.start()
        // After start, not before: enabling voice processing can move the
        // engine onto a different device than the one it was created with.
        //
        // But the audio unit's `deviceID` is not the microphone. A voice
        // processing unit is duplex — one AU spanning input and output — and
        // it answers with the *output* device: on this machine the first
        // meeting to log a device named "MacBook Air Speakers
        // [BuiltInSpeakerDevice]" as the microphone it had opened, while the
        // default input was "MacBook Air Microphone [BuiltInMicrophoneDevice]".
        // That is worse than not logging it at all — it sent the diagnosis
        // after a device that was never in the input path. So the answer is
        // only believed when the device it names actually has input channels.
        device = AudioDevices.inputDevice(reportedByAudioUnit: input.auAudioUnit.deviceID)
        if let device { deviceInputChannels = AudioDevices.channelCount(device.id, input: true) }

        // The system's own word that the graph's devices or formats changed
        // under it — a headset unplugged, another app's voice processing
        // taking the input. The engine stops itself on this and does not
        // start again; the tap stays installed on a dead node.
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self, self.inputFormat != nil else { return }
                self.restart(because: "audio configuration changed")
            }
        }
    }

    /// One line for the log at meeting start: which microphone, on what
    /// transport, at what format, echo cancellation on or off.
    public var description: String {
        var parts = [device?.label ?? "unknown input device"]
        if deviceInputChannels > 0 { parts[0] += " \(deviceInputChannels) in ch" }
        if let f = inputFormat {
            parts.append(String(format: "%.0f Hz × %u ch → %@", f.sampleRate, f.channelCount, channelPath))
        }
        if echoCancel {
            parts.append("echo cancellation on")
        } else if let echoCancelHeldBy {
            parts.append("echo cancellation off (\(echoCancelHeldBy) has the microphone)")
        } else {
            parts.append("echo cancellation off")
        }
        return parts.joined(separator: ", ")
    }

    /// Every channel of the raw bus, in dBFS since capture started, with a
    /// verdict on whether the channel being recorded is the loudest one.
    /// Nil before the first buffer. Cheap: it reads six accumulated doubles.
    public func channelReport() -> ChannelReport? {
        guard let levels, let db = levels.dbfs() else { return nil }
        return ChannelReport.make(db: db, chosen: Int(inputFormat?.channelCount ?? 1) > 2 ? 0 : nil)
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        forward.handler = nil
        inputFormat = nil
    }
}

/// A swappable consumer of audio buffers, safe to set from the main thread
/// while the audio thread reads it. The lock is uncontended in practice
/// (set twice per hold); no allocation on the audio thread.
public final class BufferForward: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ((AVAudioPCMBuffer) -> Void)?
    /// Buffers delivered so far — for tests and the log, never the audio.
    private(set) public var delivered = 0

    public init() {}

    public var handler: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    public var isAttached: Bool { handler != nil }

    /// Called on the audio thread. The buffer is the resampler's own,
    /// reused per callback: a consumer must copy what it keeps.
    public func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let h = current
        delivered += 1
        lock.unlock()
        h?(buffer)
    }
}

// MARK: - Which channel is the microphone

/// Per-channel energy on the raw input bus, accumulated on the audio thread.
///
/// This exists because nothing else can answer the question. A voice
/// processing bus is wider than the microphone — three channels on one run
/// of this machine, seven on another, behind a device with one input
/// channel — and no documentation we have found says which index the
/// processed microphone lands on. Guessing is what a comment does;
/// measuring is what this does, and it costs one multiply-accumulate per
/// sample and no allocation per callback.
public final class ChannelLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var sums: [Double]
    private var frames = 0

    public init(channels: Int) {
        sums = [Double](repeating: 0, count: max(channels, 1))
    }

    /// Called on the audio thread. Non-interleaved Float only, which is what
    /// an `AVAudioEngine` tap delivers; an interleaved buffer is ignored
    /// rather than read wrongly.
    public func add(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, !buffer.format.isInterleaved else { return }
        let n = Int(buffer.frameLength)
        let channels = min(Int(buffer.format.channelCount), sums.count)
        guard n > 0, channels > 0 else { return }
        // Summed outside the lock so the audio thread holds it for the
        // length of an array copy, not of the arithmetic.
        var local = [Double](repeating: 0, count: channels)
        for ch in 0..<channels {
            let p = data[ch]
            var s: Double = 0
            for i in 0..<n { s += Double(p[i]) * Double(p[i]) }
            local[ch] = s
        }
        lock.lock()
        for ch in 0..<channels { sums[ch] += local[ch] }
        frames += n
        lock.unlock()
    }

    /// Cumulative rms per channel in dBFS, since capture started. Nil until
    /// a buffer has arrived. Cumulative rather than windowed on purpose: the
    /// question is "has this channel ever carried anything", and a channel
    /// that carried speech at any point did carry speech.
    public func dbfs() -> [Float]? {
        lock.lock()
        let s = sums, n = frames
        lock.unlock()
        guard n > 0 else { return nil }
        return s.map { 20 * log10(max(Float(($0 / Double(n)).squareRoot()), 1e-10)) }
    }
}

/// What the per-channel measurement says, in a form a log line and a test
/// can both read.
public struct ChannelReport: Equatable, Sendable {
    /// Cumulative rms per channel, dBFS.
    public var db: [Float]
    /// The channel being written to the recording, or nil when the whole bus
    /// was reduced (mono passes through, stereo is averaged) and there is no
    /// choice to second-guess.
    public var chosen: Int?
    /// Set when some other channel is carrying real audio and the one being
    /// recorded is not — the signature of recording a reference channel.
    public var warning: String?
    /// Set when the recorded channel is below anything a live microphone
    /// produces, even in a silent room.
    public var implausiblyQuiet = false

    /// A channel has to be at least this loud for "something else is louder"
    /// to mean anything. A room where nobody is speaking puts every channel
    /// near the floor together, and that must never raise an alarm.
    public static let signalFloorDb: Float = -55
    /// Below this, the channel is not a microphone in a quiet room. The one
    /// meeting measured with a real microphone and nobody talking sat at
    /// -65 dBFS median (~-70 at the 10th percentile); digital silence reads
    /// -200 and a dithered dead channel about -90. -80 has more than ten
    /// decibels of margin on both sides of that gap.
    public static let liveMicFloorDb: Float = -80
    /// How much louder another channel must be before it is worth saying so.
    public static let marginDb: Float = 10

    public static func make(db: [Float], chosen: Int?,
                            marginDb: Float = ChannelReport.marginDb) -> ChannelReport {
        var report = ChannelReport(db: db, chosen: chosen)
        guard let chosen, chosen < db.count else { return report }
        report.implausiblyQuiet = db[chosen] < liveMicFloorDb
        let others = db.enumerated().filter { $0.offset != chosen }
        guard let loudest = others.max(by: { $0.element < $1.element }),
              loudest.element >= signalFloorDb,
              loudest.element - db[chosen] >= marginDb
        else { return report }
        report.warning = String(format: "recording channel %d at %@, but channel %d is %.0f dB louder"
                                + " — the microphone is probably not on channel %d",
                                chosen, LevelLog.dbfs(db[chosen]), loudest.offset,
                                loudest.element - db[chosen], chosen)
        return report
    }

    /// `channels ch0 -62 dBFS, ch1 -∞, ch2 -∞ → recording ch0`
    public var line: String {
        let each = db.enumerated().map { "ch\($0.offset) \(LevelLog.dbfs($0.element))" }
        var s = "channels " + each.joined(separator: ", ")
        if let chosen { s += " → recording ch\(chosen)" }
        return s
    }
}
