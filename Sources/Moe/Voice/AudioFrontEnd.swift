import AVFoundation
import Foundation
import MoeVoice
import MoeMeeting
import MoeObjC
import Synchronization

/// The one audio graph: microphone in, Moe's voice out, echo cancellation
/// between them. VOICE-PLAN.md §3.
///
/// Built once and kept up for as long as anything might need it. The old
/// engine built and tore this down around every turn, which is where the
/// engine restarts in front of slow turns, the -10875 format errors and the
/// "cut off mid-sentence" bugs all came from.
///
/// Voice processing (Apple's echo canceller) is enabled on *both* nodes,
/// as `AudioGate` proved and `MicCapture` already does, and the ducking of
/// every other app's audio that comes with it is switched off. Everything
/// Moe says goes out through this graph, so the canceller has Moe's voice
/// as its reference and the microphone does not hear it.
///
/// The render thread does one thing: copy channel 0 into a ring buffer and
/// signal. No allocation, no actor hop, no lock. A dedicated task drains
/// the ring and feeds `AudioPipeline`, which owns everything downstream.
@MainActor
final class AudioFrontEnd {

    enum Cue { case wake, close }

    // MARK: - Configuration

    /// Apple's voice processing on the graph, as wanted. Default on: every
    /// open-mic mode needs it, and the ducking it used to cost is disabled
    /// below. What actually runs is `echoCancellationActive`: never while
    /// a call app holds the microphone (see `MicHolders`) — voice
    /// processing flips the built-in microphone into its raw multi-channel
    /// mode for every process and the call's far end stops hearing the
    /// user. Checked at start and every `callCheckSeconds` while the graph
    /// is up; the graph restarts to change it, and `onRestarted` says so.
    var echoCancellation = true
    private(set) var echoCancellationActive = false
    /// The call app the microphone was left plain for.
    private(set) var echoCancellationHeldBy: String?
    /// The live check, replaceable for tests.
    var callAppsOnMicrophone: () -> [CallMicDebounce.Holder] = {
        CallApps.holdingMicrophone().map { .init(name: $0.name, isBrowser: $0.kind == .browser) }
    }
    var callCheckSeconds: Double = 2
    private var callWatch: Task<Void, Never>?
    /// Whether Moe has audio queued or playing — a restart stops the player,
    /// so only a dedicated call app may take the microphone mid-sentence.
    /// Set by `VoiceEngine`.
    var playbackBusy: () -> Bool = { false }
    /// The call the watchdog has decided owns the microphone, if any. Set
    /// through `CallMicDebounce` (and at once for a dedicated call app), so
    /// a browser's two-second grab never reaches the graph (ticket #12).
    private var callHolding: String?
    private var callDebounce = CallMicDebounce()
    private let callClock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Voice processing came on or went off (the graph restarted for it).
    var onEchoCancellationChanged: ((Bool) -> Void)?

    // MARK: - Outputs (main actor)

    /// One scheduled buffer has been played out: its length in frames and
    /// the tag it was scheduled with, so a completion that belongs to a
    /// playback already stopped can be told apart from the current one.
    var onBufferHeard: ((_ frames: Int, _ tag: Int) -> Void)?
    var onError: ((String) -> Void)?
    /// The device changed under a running graph (headphones, AirPods, a
    /// display with audio). The graph was restarted if it was wanted.
    var onRestarted: (() -> Void)?
    /// The player lost what it had queued (device change): no completion
    /// will ever come for those buffers.
    var onPlaybackLost: (() -> Void)?

    // MARK: - Graph

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let cuePlayer = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat
    private var cueFormat: AVAudioFormat
    private(set) var isRunning = false
    /// `start()` was asked for and `stop()` has not been: what to restore
    /// after the device changes under us.
    private var wantedUp = false
    private var teardown: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    /// The device belongs to someone else (a meeting); buffers arrive
    /// through `feedExternalInput` instead.
    private(set) var externalInput = false

    // MARK: - Capture path

    private let ring: SampleRing
    private let pipeline: AudioPipeline
    private let signal: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private var drain: Task<Void, Never>?

    init(pipeline: AudioPipeline, playbackRate: Double = 24_000) {
        self.pipeline = pipeline
        self.ring = SampleRing(capacity: 48_000 * 4)
        self.playbackFormat = AVAudioFormat(standardFormatWithSampleRate: playbackRate, channels: 1)!
        self.cueFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let (stream, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.signal = stream
        self.wake = cont
        engine.attach(player)
        engine.attach(cuePlayer)
        startDrain()
        // The device changed under us: AirPods on, headphones out, a
        // display with speakers. The engine stops itself and the tap goes
        // dead — Moe would look alive and hear nothing, and the next
        // `play()` would throw. Bring it back if it was wanted.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.deviceChanged() }
        }
    }

    private func deviceChanged() {
        Log.write("audio: device configuration changed")
        let wanted = wantedUp
        let idleFuse = teardown != nil
        if isRunning {
            // Whatever was queued on the player is gone with the device;
            // the pump must not wait for its completions.
            player.stop()
            onPlaybackLost?()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        guard wanted, !externalInput else { return }
        // Let the device settle before the graph is rebuilt on it.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.wantedUp, !self.isRunning else { return }
            do {
                try self.start()
                // `start()` cancels a pending teardown; a graph that was
                // on its way down must still go down.
                if idleFuse { self.scheduleTeardown(after: 60) }
                self.onRestarted?()
            } catch {
                Log.write("audio: restart after device change failed: \(error)")
                self.onError?("Microphone unavailable after the audio device changed: \(error.localizedDescription)")
            }
        }
    }

    private func startDrain() {
        let ring = self.ring
        let pipeline = self.pipeline
        let signal = self.signal
        drain = Task.detached(priority: .userInitiated) {
            var scratch = [Float](repeating: 0, count: ring.capacity)
            for await _ in signal {
                if ring.takeOverflow() {
                    Log.write("audio: ring overflow — input dropped (consumer stalled)")
                }
                let rate = ring.rate
                let n = ring.read(into: &scratch)
                guard n > 0 else { continue }
                await pipeline.ingest(Array(scratch[0..<n]), rate: rate)
            }
        }
    }

    // MARK: - Lifecycle

    /// Bring the graph up if it is not. Cheap when it already is.
    func start() throws {
        teardown?.cancel(); teardown = nil
        wantedUp = true
        guard !isRunning, !externalInput else { return }

        let input = engine.inputNode
        let output = engine.outputNode

        // Must be set while the engine is stopped: it swaps the unit for a
        // duplex VoiceProcessingIO and re-shapes the buses. Never while a
        // call app holds the microphone: the call would lose the user.
        // A dedicated call app is believed at once, as before; a browser is
        // left to the watchdog, which waits for it to hold (`CallMicDebounce`).
        if let call = callAppsOnMicrophone().first(where: { !$0.isBrowser }) {
            callHolding = call.name
        }
        echoCancellationHeldBy = callHolding
        let wasActive = echoCancellationActive
        echoCancellationActive = echoCancellation && callHolding == nil
        if echoCancellationActive {
            if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
            if !output.isVoiceProcessingEnabled { try output.setVoiceProcessingEnabled(true) }
            // The canceller ducks every other app's audio by default. That
            // is the "music goes quiet when Moe listens" complaint, and it
            // is a setting, not a law.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false,
                                                                      duckingLevel: .min)
        } else {
            if input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(false) }
            if output.isVoiceProcessingEnabled { try? output.setVoiceProcessingEnabled(false) }
        }

        // Read the shape back — never assume it. Observed 3 channels on one
        // run and 7 on another, on the same machine.
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw NSError(domain: "Alfie.Audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone input (is one connected?)"])
        }
        let outHW = output.inputFormat(forBus: 0)

        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.connect(cuePlayer, to: engine.mainMixerNode, format: cueFormat)
        // Never nil: nil re-derives from a bus that just changed shape,
        // which is what produces -10875 "format not supported" at start().
        engine.connect(engine.mainMixerNode, to: output,
                       format: AVAudioFormat(standardFormatWithSampleRate: outHW.sampleRate,
                                             channels: outHW.channelCount) ?? outHW)

        ring.clear()                       // samples at the old rate, if any
        ring.rate = micFormat.sampleRate
        let ring = self.ring
        let wake = self.wake
        // Through MoeObjC: `installTapOnBus:` raises an Objective-C exception
        // on a format mismatch after a device change, which Swift cannot
        // catch and which corrupts the concurrency runtime on its way out
        // (2026-09-30). Thrown instead, it reaches whatever already handles a
        // graph that failed to start.
        try MoeObjC.catchException {
        input.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { buffer, _ in
            // Render thread. Channel 0 is the echo-cancelled microphone; the
            // rest are the canceller's reference channels.
            guard let channels = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            ring.write(channels[0], count: n)
            wake.yield(())
        }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        applyBypass()
        let vp = echoCancellationActive ? "on\(voiceProcessingBypassed ? " (bypassed while idle)" : ""), ducking off"
            : (echoCancellationHeldBy.map { "off (\($0) has the microphone)" } ?? "off")
        Log.write("audio: graph up (\(Int(micFormat.sampleRate)) Hz × \(micFormat.channelCount) in, voice processing \(vp))")
        if wasActive != echoCancellationActive { onEchoCancellationChanged?(echoCancellationActive) }
        watchCallApps()
    }

    /// While the graph is up, ask Core Audio every `callCheckSeconds` who
    /// has the microphone. A call app arriving takes voice processing off
    /// at once (its far end hears nothing until then); one leaving brings
    /// it back. Either way the graph restarts, like a device change.
    private func watchCallApps() {
        callWatch?.cancel()
        guard echoCancellation else { return }
        callWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.callCheckSeconds ?? 2) * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isRunning, !self.externalInput else { return }
                let decision = self.callDebounce.observe(
                    holders: self.callAppsOnMicrophone(),
                    cancellerOn: self.echoCancellationActive,
                    speaking: self.playbackBusy(),
                    now: self.callClock())
                switch decision {
                case .keep:
                    continue
                case .giveUp(let app):
                    Log.write("audio: \(app) is on the microphone, voice processing off so it hears you")
                    self.callHolding = app
                case .takeBack:
                    Log.write("audio: call app gone, voice processing back on")
                    self.callHolding = nil
                }
                self.restartForVoiceProcessing()
                return
            }
        }
    }

    // MARK: - Bypass

    /// Whether the canceller is currently doing nothing. Starts true: an
    /// idle Moe has no playback to cancel.
    private(set) var voiceProcessingBypassed = true

    /// Stop the canceller working without taking it out of the graph.
    ///
    /// **What this is worth.** Apple's voice-processing unit runs a neural
    /// echo canceller and noise suppressor over every buffer, on the CPU
    /// through BNNS. Measured on this Mac with a standalone AVAudioEngine
    /// doing nothing but rendering, three ways:
    ///
    ///     voice processing off entirely     0.2% of a core   (3 ch in)
    ///     voice processing on, bypassed     3.5%             (7 ch in)
    ///     voice processing on, running     20.6%             (7 ch in)
    ///
    /// A stack profile of an idle Moe put **78% of its busy CPU** inside
    /// that unit's DSP — more than every model in the app put together.
    ///
    /// **Why bypass rather than disable.** `setVoiceProcessingEnabled` can
    /// only be changed with the engine stopped, so switching it costs a
    /// full graph restart: 1–2 seconds in this Mac's own logs, playback in
    /// flight lost, and the input channel count changes under everything.
    /// Far too slow to flip per reply. This property can be set on the live
    /// unit, and the measurement above did exactly that — on, bypassed, on
    /// again — inside one run of one engine.
    ///
    /// **Why it is safe to bypass when idle.** The canceller exists to
    /// subtract Moe's own speaker output from the microphone. With nothing
    /// playing there is nothing to subtract, and the industry does the same
    /// — always-on assistants run AEC around playback, not around the
    /// clock. What it must never be is bypassed *while Moe is speaking*:
    /// that is what makes barge-in possible and what stops the VAD hearing
    /// Moe as a person. `VoiceEngine` un-bypasses on the way into a turn,
    /// not at the moment sound starts, so the filter has the thinking pause
    /// to converge.
    ///
    /// A no-op when voice processing is not active at all, which is the
    /// case while a call app holds the microphone.
    func setVoiceProcessingBypassed(_ bypass: Bool) {
        guard voiceProcessingBypassed != bypass else { return }
        guard isRunning, echoCancellationActive, let au = engine.inputNode.audioUnit else {
            // Remember the wish: `start()` applies it once the unit exists,
            // so a bypass asked for while the graph was down is not lost.
            voiceProcessingBypassed = bypass
            return
        }
        var flag: UInt32 = bypass ? 1 : 0
        let status = AudioUnitSetProperty(au,
                                          kAUVoiceIOProperty_BypassVoiceProcessing,
                                          kAudioUnitScope_Global, 0,
                                          &flag, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            // Never leave the flag saying something the unit is not doing:
            // the failure that matters is believing the canceller is on
            // while Moe speaks, and hearing itself.
            Log.write("audio: could not \(bypass ? "bypass" : "un-bypass") voice processing (\(status))")
            voiceProcessingBypassed = false
            return
        }
        voiceProcessingBypassed = bypass
    }

    /// Push the current bypass wish at a unit that has just come up.
    private func applyBypass() {
        guard isRunning, echoCancellationActive, let au = engine.inputNode.audioUnit else { return }
        var flag: UInt32 = voiceProcessingBypassed ? 1 : 0
        let status = AudioUnitSetProperty(au,
                                          kAUVoiceIOProperty_BypassVoiceProcessing,
                                          kAudioUnitScope_Global, 0,
                                          &flag, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            Log.write("audio: voice-processing bypass unavailable (\(status)); the canceller runs continuously")
            voiceProcessingBypassed = false
        }
    }

    /// Down and up again with the current voice-processing decision.
    /// Playback in flight is lost, as on a device change.
    private func restartForVoiceProcessing() {
        let idleFuse = teardown != nil
        player.stop()
        onPlaybackLost?()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        do {
            try start()
        } catch {
            // Voice processing refused on this device: plain input is
            // better than a dead microphone. Once more, without it.
            Log.write("audio: restart for voice processing failed (\(error)); retrying plain")
            let wanted = echoCancellation
            echoCancellation = false
            defer { echoCancellation = wanted }
            do { try start() } catch {
                Log.write("audio: plain restart failed too: \(error)")
                onError?("Microphone unavailable: \(error.localizedDescription)")
                return
            }
        }
        if idleFuse { scheduleTeardown(after: 60) }
        onRestarted?()
    }

    /// Take the graph down now: tap removed, engine stopped, microphone off.
    func stop() {
        teardown?.cancel(); teardown = nil
        callWatch?.cancel(); callWatch = nil
        wantedUp = false
        stopPlayback()
        if isRunning { cuePlayer.stop() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        Log.write("audio: graph down")
    }

    /// Let the graph go if nothing asks for it again within `seconds`.
    func scheduleTeardown(after seconds: Double) {
        teardown?.cancel()
        teardown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.stop()
        }
    }

    // MARK: - External input (meeting mode)

    /// The meeting's `MicCapture` owns the device from now on. Its 16 kHz
    /// buffers arrive through `feedExternalInput`; this graph stays down.
    func attachExternalInput() {
        stop()
        externalInput = true
        // Nothing from the old source may be read at the new source's rate.
        ring.clear()
        ring.rate = 16_000
        Log.write("audio: external input attached (meeting mic)")
    }

    func detachExternalInput() {
        guard externalInput else { return }
        externalInput = false
        ring.clear()
        Log.write("audio: external input detached")
    }

    /// One mono buffer from the meeting's mic, on its audio thread.
    nonisolated func feedExternalInput(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        ring.rate = buffer.format.sampleRate
        ring.write(channels[0], count: n)
        wake.yield(())
    }

    // MARK: - Playback

    /// The synthesiser's rate. Reconnects the player, which is safe while
    /// the engine runs as long as the player is stopped first.
    func setPlaybackRate(_ rate: Double) {
        guard rate != playbackFormat.sampleRate,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        stopPlayback()
        playbackFormat = format
        if isRunning {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    /// Queue samples on the player. Completion is reported through
    /// `onBufferHeard` when the hardware has played them — not when they
    /// were rendered — because that is the moment a person hears silence.
    @discardableResult
    func schedule(_ samples: [Float], tag: Int) -> Bool {
        guard isRunning, engine.isRunning, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if !player.isPlaying, !playbackPaused { player.play() }
        let frames = samples.count
        player.scheduleBuffer(buffer, at: nil, options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.onBufferHeard?(frames, tag) }
        }
        return true
    }

    /// The reply, held. Buffers already scheduled stay scheduled and new
    /// ones may still be added; none of it sounds until `resumePlayback`.
    private var playbackPaused = false

    func pausePlayback() {
        guard isRunning, !playbackPaused else { return }
        playbackPaused = true
        player.pause()
    }

    func resumePlayback() {
        guard playbackPaused else { return }
        playbackPaused = false
        if isRunning, !player.isPlaying { player.play() }
    }

    /// Drop everything queued on the player, now. `player.stop()` does not
    /// reliably call the completion handlers of what it drops, so the caller
    /// must forget its own count too.
    func stopPlayback() {
        playbackPaused = false
        if isRunning { player.stop() }
    }

    /// Quieten the reply without stopping it.
    ///
    /// Someone has started talking over Moe and it is not yet known whose
    /// voice it is. Stopping would be wrong if the answer turns out to be
    /// "the television"; carrying on at full volume would be rude if it
    /// turns out to be the person. Ducking is what a person does in the
    /// same half-second, and it is reversible, which stopping is not.
    ///
    /// Ramped, not switched (`DuckRamp`): −14 dB over 40 ms going down, back
    /// over 200 ms. An instant cut and an instant restore both read as a
    /// glitch; a fall this short is still the half-syllable a person takes
    /// to yield.
    func duck(_ on: Bool) {
        duckRamp?.cancel()
        let from = player.volume
        let to: Float = on ? DuckRamp.duckedGain : 1
        let steps = DuckRamp.steps(from: from, to: to, duration: on ? DuckRamp.downSeconds : DuckRamp.upSeconds)
        duckRamp = Task { @MainActor [weak self] in
            var elapsed = 0.0
            for step in steps {
                let wait = step.t - elapsed
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard !Task.isCancelled, let self else { return }
                elapsed = step.t
                self.player.volume = step.gain
            }
        }
    }
    private var duckRamp: Task<Void, Never>?

    /// A paused reply picking up again: from the ducked level, back up over
    /// the same 200 ms, so the first syllable after a pause is not a jolt.
    func fadeBackIn() {
        duckRamp?.cancel()
        player.volume = DuckRamp.duckedGain
        duck(false)
    }

    /// Playback latency after a buffer is scheduled, for the trace.
    var outputLatency: TimeInterval {
        isRunning ? engine.outputNode.presentationLatency : 0
    }

    // MARK: - Cues

    /// A short tone through the same graph, so the canceller hears it too.
    func cue(_ kind: Cue) {
        guard isRunning, engine.isRunning else { return }
        let tones: [(Double, Double)]
        switch kind {
        case .wake:  tones = [(659.25, 0.07), (880.0, 0.09)]     // E5 → A5, up
        case .close: tones = [(659.25, 0.07), (523.25, 0.10)]    // E5 → C5, down
        }
        guard let buffer = Self.render(tones, format: cueFormat) else { return }
        if !cuePlayer.isPlaying { cuePlayer.play() }
        cuePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    private static func render(_ tones: [(Double, Double)], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = tones.reduce(0) { $0 + Int($1.1 * rate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        let out = buffer.floatChannelData![0]
        var i = 0
        for (hz, seconds) in tones {
            let n = Int(seconds * rate)
            for k in 0..<n {
                let t = Double(k) / rate
                let env = min(1, Double(k) / (rate * 0.008)) * min(1, Double(n - k) / (rate * 0.03))
                out[i] = Float(sin(2 * .pi * hz * t) * env * 0.12)
                i += 1
            }
        }
        return buffer
    }
}

// MARK: - Ring buffer

/// Single producer (the render thread), single consumer (the drain task).
/// Fixed storage, two counters, no locks.
final class SampleRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let rateHz = Atomic<Int>(48_000)
    private let overflowed = Atomic<Bool>(false)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    var rate: Double {
        get { Double(rateHz.load(ordering: .relaxed)) }
        set { rateHz.store(Int(newValue), ordering: .relaxed) }
    }

    /// Everything unread is forgotten. For the consumer side, between
    /// sources — never while the producer is writing.
    func clear() {
        consumed.store(written.load(ordering: .acquiring), ordering: .releasing)
    }

    /// True once, if input was ever dropped. Read by the drain task, which
    /// may log; the render thread must not.
    func takeOverflow() -> Bool {
        overflowed.exchange(false, ordering: .relaxed)
    }

    /// Producer side. If the consumer has fallen more than a whole ring
    /// behind, the incoming samples are dropped rather than the old ones
    /// overwritten under the reader.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        let w = written.load(ordering: .relaxed)
        let r = consumed.load(ordering: .acquiring)
        guard w - r + count <= capacity else {
            overflowed.store(true, ordering: .relaxed)
            return
        }
        var i = 0
        while i < count {
            let pos = (w + i) % capacity
            let run = min(count - i, capacity - pos)
            (storage + pos).update(from: src + i, count: run)
            i += run
        }
        written.store(w + count, ordering: .releasing)
    }

    /// Consumer side. Returns how many samples were copied into `into`.
    func read(into dst: inout [Float]) -> Int {
        let w = written.load(ordering: .acquiring)
        let r = consumed.load(ordering: .relaxed)
        let n = min(w - r, dst.count)
        guard n > 0 else { return 0 }
        dst.withUnsafeMutableBufferPointer { out in
            var i = 0
            while i < n {
                let pos = (r + i) % capacity
                let run = min(n - i, capacity - pos)
                (out.baseAddress! + i).update(from: storage + pos, count: run)
                i += run
            }
        }
        consumed.store(r + n, ordering: .releasing)
        return n
    }
}
