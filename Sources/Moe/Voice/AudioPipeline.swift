import AVFoundation
import FluidAudio
import Foundation
import MoeVoice

/// Everything downstream of the microphone, on one actor, off the main
/// thread: resample to 16 kHz, meter, pre-roll, capture, VAD, and feeding
/// the streaming recogniser. VOICE-PLAN.md §2 (the detectors).
///
/// The front end hands it raw samples at whatever rate the device runs;
/// what comes out is a handful of events on the main actor. Nothing here
/// decides anything — `VoiceMachine` does that with what this reports.
actor AudioPipeline {

    enum Output: Sendable {
        case level(Float)
        case speechStarted
        case speechEnded
        /// Already in speech, and a louder voice joined it
        /// (`NoiseFloorGate.Edge.rose`): somebody talking over Moe's reply,
        /// whose echo the VAD has been calling speech all along.
        case speechRose
        case partial(String)
        case endOfUtterance(String)
        /// The wake head heard the name (with its score).
        case woke(Float)
        /// One VAD chunk (256 ms): Silero's probability, the chunk's loudest
        /// frame, the room's floor, and whether speech is on after the gate.
        /// For the turn trace and the debug clips; nothing decides on it.
        case vad(probability: Float, peakDb: Float, floorDb: Float?, speech: Bool)
    }

    static let rate: Double = 16_000
    /// One frame: 32 ms at 16 kHz.
    static let frame = 512

    private let sink: @Sendable (Output) -> Void

    // Resampling
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    private var acc: [Float] = []

    // Meter
    private var meter = LevelMeter()
    private var meterTick = 0

    // Pre-roll: the last couple of seconds, always, so a capture that
    // starts on a wake match or a key-down still has the first syllable.
    private var preroll: [Float] = []
    private let prerollCap = Int(rate * 2.5)

    // Capture for the accurate re-read
    private var capturing = false
    private var capture: [Float] = []
    private let captureCap = Int(rate * 600)
    private var captureCapWarned = false

    // Streaming recogniser
    private var asr: StreamingEouAsrManager?
    private var asrOn = false
    private var primeGeneration = 0

    /// The same 16 kHz frames the capture keeps, handed onward as they
    /// arrive — to the cloud recogniser, which reads them live so the
    /// re-read at the end of the turn is a force-end and a wait of ~180 ms
    /// rather than an upload. Called only while capturing; whoever holds
    /// the sink decides whether it wants them.
    enum CloudFeed: Sendable {
        case audio([Float])
        /// `takeCapture` ran: everything fed so far was the turn just
        /// taken, and what follows is the next one.
        case turnTaken
    }
    private var cloudSink: (@Sendable (CloudFeed) -> Void)?
    private let asrFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

    // VAD
    private var vad: VadManager?
    private var vadState: VadStreamState?
    private var vadAcc: [Float] = []
    private let vadChunk = VadManager.chunkSize
    private var vadConfig = VadSegmentationConfig()
    /// Speech as reported onward: the VAD's edges held to the room's noise
    /// floor (`NoiseFloorGate`). A fan the VAD calls speech is not an onset; a
    /// VAD stuck "in speech" over steady noise ends once the level has sat
    /// on the floor for most of a second.
    private(set) var inSpeech = false
    private var gate = NoiseFloorGate()
    /// The VAD's own view, ungated — what the wake head listens around, so
    /// a soft "Hey Moe" in a noisy room is still scored.
    private var vadRawInSpeech = false

    // Wake head: the name, from the audio, while the VAD hears speech
    // and for a moment after — the phrase must have just ended inside
    // the window, and the VAD reports the end a quarter second late.
    private var wakeHead: WakeHead?
    private var wakePolicy = WakePolicy()
    /// The highest score of the current run of windows above the near-miss
    /// floor, and whether that run fired. Logged when the run ends without
    /// firing, so a "Hey Moe" the head heard but the threshold refused
    /// leaves a line — until 2026-09-06 nothing did, and a miss was
    /// indistinguishable from silence.
    private var nearMissPeak: Float = 0
    private var nearMissFired = false
    static let nearMissFloor: Float = 0.5
    private var wakeOn = false
    private var wakeBusy = false
    /// The last stride boundary seen, and the last one scored.
    private var wakeStride = 0
    private var wakeScoredStride = -2
    private let wakeTailSeconds = 0.6
    private var speechEndedAt: Double?
    /// Samples ingested at 16 kHz, and the same as seconds.
    private var ingested = 0
    private var clock: Double = 0

    init(sink: @escaping @Sendable (Output) -> Void) {
        self.sink = sink
        vadConfig.minSilenceDuration = 0.25
        vadConfig.speechPadding = 0.03
    }

    // MARK: - Wiring

    func attach(asr: StreamingEouAsrManager) {
        self.asr = asr
    }

    func attach(vad: VadManager) async {
        self.vad = vad
        vadState = await vad.makeStreamState()
    }

    /// - Parameter primeSeconds: switched on mid-sound (a VAD onset over a
    ///   reply), feed the recogniser the last this-many seconds first, so
    ///   the word the onset was late for is not missing its front.
    func setAsr(_ on: Bool, primeSeconds: Double = 0) async {
        primeGeneration &+= 1
        let generation = primeGeneration
        guard on else { asrOn = false; return }
        guard !asrOn else { return }
        guard primeSeconds > 0, let asr else { asrOn = true; return }
        // Off for live frames while priming (`AsrPrimer`): the pre-roll is
        // fed by absolute position until it has caught up with everything
        // ingested, each piece copied out before any await, and the switch
        // goes on with no suspension after the last check.
        var fedThrough = ingested - min(preroll.count, Int(primeSeconds * Self.rate))
        while true {
            let take = AsrPrimer.catchUp(fedThrough: fedThrough, ingested: ingested, available: preroll.count)
            if take == 0 { break }
            let target = ingested
            let piece = Array(preroll.suffix(take))
            var i = 0
            while i < piece.count {
                let end = min(piece.count, i + Self.frame)
                await feedAsr(asr, Array(piece[i..<end]))
                guard generation == primeGeneration else { return }   // switched off meanwhile
                i = end
            }
            fedThrough = target
        }
        asrOn = true
    }

    private func feedAsr(_ asr: StreamingEouAsrManager, _ frame: [Float]) async {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: asrFormat, frameCapacity: AVAudioFrameCount(frame.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frame.count)
        frame.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: frame.count)
        }
        _ = try? await asr.process(audioBuffer: buffer)
    }

    func setCloudSink(_ sink: (@Sendable (CloudFeed) -> Void)?) {
        cloudSink = sink
    }

    func attach(wake: WakeHead, policy: WakePolicy) {
        wakeHead = wake
        wakePolicy = policy
    }

    func setWake(_ on: Bool) {
        guard on != wakeOn else { return }
        wakeOn = on
        wakeScoredStride = -2
        wakePolicy.reset()
    }

    /// The rise margin (`NoiseFloorGate.Tuning.riseMarginDb`) — for the
    /// bench's sweeps; the app keeps the default.
    func setRiseMargin(_ db: Float) {
        gate.tuning.riseMarginDb = db
    }

    /// Every head score with its audio time — for the bench, never set in
    /// the app.
    private var wakeProbe: (@Sendable (Float, Double) -> Void)?
    func setWakeProbe(_ probe: (@Sendable (Float, Double) -> Void)?) {
        wakeProbe = probe
    }

    /// Start (with the pre-roll) or stop keeping audio for the re-read.
    func setCapture(_ on: Bool, prerollSeconds: Double) {
        // `on` while already capturing is a new owner of the buffer (the
        // echo test, an enrolment), not a no-op: what is in there belongs
        // to whoever asked last.
        guard on != capturing || on else { return }
        capturing = on
        captureCapWarned = false
        if on {
            let keep = min(preroll.count, Int(prerollSeconds * Self.rate))
            capture = Array(preroll.suffix(keep))
            // The pre-roll too: the first syllable is in it.
            if !capture.isEmpty { cloudSink?(.audio(capture)) }
        } else {
            // Off means gone. Left behind, the last turn's audio stays
            // readable through `peekCapture` for the whole rest of the
            // session — and on 2026-09-03 it was read: the wake word's
            // owner-voice check scored a conversation that had ended
            // minutes earlier, got the same 0.11 every time, and refused
            // every "Hey Moe" after the first. A buffer nobody is filling
            // must not still answer questions.
            capture.removeAll(keepingCapacity: true)
        }
    }

    /// The person started talking after a wait: throw away the silence
    /// that came before, keep a little context.
    func trimCapture(keepLastSeconds: Double) {
        guard capturing else { return }
        let keep = Int(keepLastSeconds * Self.rate)
        if capture.count > keep { capture.removeFirst(capture.count - keep) }
    }

    /// Hand over the capture and start a fresh one (still on, if it was).
    func takeCapture() -> [Float] {
        defer { capture.removeAll(keepingCapacity: true) }
        if capturing { cloudSink?(.turnTaken) }
        return capture
    }

    /// The whole capture so far, left where it is — for the accurate read
    /// that starts on the VAD's edge (`ProgressiveRead`). Queued through
    /// `VoiceEngine.pipe` like everything else, so it is always a prefix of
    /// the `takeCapture` that follows it.
    func peekCapture() -> [Float] { capture }

    /// The last `seconds` of the capture, left where it is — for the turn
    /// model to look at a pause without ending the turn.
    func peekCapture(lastSeconds seconds: Double) -> [Float] {
        let n = min(capture.count, Int(seconds * Self.rate))
        return Array(capture.suffix(n))
    }

    /// How much has been captured so far, in seconds.
    var captureSeconds: Double { Double(capture.count) / Self.rate }

    /// The last `seconds` of what the microphone heard, capture or no
    /// capture. The pre-roll runs the whole time the graph is up, which
    /// is what standby needs: there is no capture there, so anything
    /// asking "what did that voice sound like" at a wake match has to
    /// read this rather than a buffer that was last written to during
    /// some earlier conversation.
    func peekRecent(lastSeconds seconds: Double) -> [Float] {
        let n = min(preroll.count, Int(seconds * Self.rate))
        return Array(preroll.suffix(n))
    }

    func resetAsr() async {
        await asr?.reset()
    }

    /// Everything back to quiet — between owners of the microphone.
    func resetVad() async {
        vadAcc.removeAll(keepingCapacity: true)
        inSpeech = false
        vadRawInSpeech = false
        gate.resetSpeech()
        if let vad { vadState = await vad.makeStreamState() }
    }

    // MARK: - Ingest

    func ingest(_ samples: [Float], rate: Double) async {
        let mono16k = resample(samples, from: rate)
        guard !mono16k.isEmpty else { return }
        acc.append(contentsOf: mono16k)
        while acc.count >= Self.frame {
            let frame = Array(acc.prefix(Self.frame))
            acc.removeFirst(Self.frame)
            await process(frame)
        }
    }

    private func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != Self.rate else { return samples }
        if converter == nil || converterRate != rate {
            guard let inFmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let c = AVAudioConverter(from: inFmt, to: asrFormat) else {
                return SpeechRouter.resample(samples, from: rate)
            }
            converter = c
            converterRate = rate
        }
        guard let converter,
              let inFmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { return SpeechRouter.resample(samples, from: rate) }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let outCap = AVAudioFrameCount(Double(samples.count) * Self.rate / rate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: asrFormat, frameCapacity: outCap) else { return [] }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, let data = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength)))
    }

    private func process(_ frame: [Float]) async {
        // Read before any await: a frame that arrived while the recogniser
        // was being primed is fed by the primer, from the pre-roll, not here.
        let feedAsrNow = asrOn
        ingested += frame.count
        clock = Double(ingested) / Self.rate
        // Meter, at ~30 Hz.
        frame.withUnsafeBufferPointer { meter.update(db: LevelMeter.db(of: $0)) }
        meterTick += 1
        if meterTick % 2 == 0 { sink(.level(meter.level)) }

        // Pre-roll.
        preroll.append(contentsOf: frame)
        if preroll.count > prerollCap + Self.frame * 16 {
            preroll.removeFirst(preroll.count - prerollCap)
        }

        // Capture.
        if capturing {
            if capture.count < captureCap {
                capture.append(contentsOf: frame)
                cloudSink?(.audio(frame))
            } else if !captureCapWarned {
                captureCapWarned = true
                Log.write("voice: hit the 600 s recording cap — anything after this is not kept")
            }
        }

        // VAD, in the model's own window.
        if let vad, var state = vadState {
            vadAcc.append(contentsOf: frame)
            if vadAcc.count >= vadChunk {
                let chunk = Array(vadAcc.prefix(vadChunk))
                vadAcc.removeFirst(vadChunk)
                if let result = try? await vad.processStreamingChunk(chunk, state: state, config: vadConfig) {
                    state = result.state
                    vadState = state
                    var raw: NoiseFloorGate.VadEdge?
                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            raw = .start
                            vadRawInSpeech = true
                        case .speechEnd:
                            raw = .end
                            vadRawInSpeech = false
                            speechEndedAt = clock
                        }
                    }
                    let level = NoiseFloorGate.levels(chunk, frame: Self.frame)
                    let refusedBefore = gate.refusedOnsets
                    let edge = gate.observe(chunkDb: level.meanDb, peakDb: level.peakDb, vad: raw)
                    sink(.vad(probability: result.probability, peakDb: level.peakDb,
                              floorDb: gate.floorDb, speech: gate.inSpeech))
                    if gate.refusedOnsets > refusedBefore, let floor = gate.floorDb {
                        Log.write(String(format: "vad: speech-shaped but %.0f dB over the room (%.0f dBFS) — not an onset",
                                         level.peakDb - floor, floor))
                    }
                    switch edge {
                    case .started?:
                        inSpeech = true
                        sink(.speechStarted)
                    case .ended?:
                        inSpeech = false
                        if raw != .end, let floor = gate.floorDb {
                            Log.write(String(format: "vad: still \"speech\" but back at the room's level (%.0f dBFS) — speech ended",
                                             floor))
                        }
                        sink(.speechEnded)
                    case .rose?:
                        sink(.speechRose)
                    case nil:
                        break
                    }
                }
            }
        }

        // The wake head, every embedding stride, on the last two seconds
        // — only around speech, so an empty room costs the VAD alone.
        // Windows end on stride boundaries of the audio clock, so one is
        // exactly a stride after the last and the head can reuse fifteen
        // of its sixteen embeddings; a gap (gated off, or busy) means the
        // next score is a full run.
        if wakeOn, let wakeHead, !wakeBusy {
            let stride = ingested / WakeHead.strideSamples
            if stride > wakeStride {
                wakeStride = stride
                let nearSpeech = vadRawInSpeech || (speechEndedAt.map { clock - $0 < wakeTailSeconds } ?? false)
                let lag = ingested % WakeHead.strideSamples
                if nearSpeech, preroll.count >= WakeHead.windowSamples + lag {
                    let end = preroll.count - lag
                    let window = Array(preroll[(end - WakeHead.windowSamples) ..< end])
                    let at = clock
                    let contiguous = wakeScoredStride == stride - 1
                    wakeBusy = true
                    let score = try? await wakeHead.score(window, contiguous: contiguous)
                    wakeBusy = false
                    wakeScoredStride = score == nil ? -2 : stride
                    if let score, let wakeProbe { wakeProbe(score, at) }
                    var fired = false
                    if wakeOn, let score, wakePolicy.observe(score: score, at: at) {
                        fired = true
                        sink(.woke(score))
                    }
                    if let score {
                        if fired { nearMissFired = true }
                        if score >= Self.nearMissFloor {
                            nearMissPeak = max(nearMissPeak, score)
                        } else if nearMissPeak > 0 {
                            if !nearMissFired {
                                Log.write("wake: near miss — peaked at \(String(format: "%.2f", nearMissPeak))")
                            }
                            nearMissPeak = 0
                            nearMissFired = false
                        }
                    }
                }
            }
        }

        // The streaming recogniser, only when something is listening.
        if feedAsrNow, asrOn, let asr {
            await feedAsr(asr, frame)
        }
    }
}
