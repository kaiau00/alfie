import Foundation
import MoeVoice

/// Moe's voice: text in, audio out through the front end, and two honest
/// signals back — the first buffer heard, and the last. VOICE-PLAN.md §5.
///
/// One serial pump over a queue of things to say. A streaming backend
/// (PocketTTS) yields 80 ms frames as it synthesises, so the first sound is
/// out in tens of milliseconds; a whole-chunk backend yields once. Either
/// way the pump schedules audio on the player and waits, when it must, for
/// *room* — never for silence, which is what used to put the render time
/// of every sentence into a gap before it.
///
/// `onIdle` fires when nothing is queued, nothing is rendering and the
/// last scheduled buffer has been played out by the hardware. That — not
/// the arrival of the reply's last character — is when Moe has stopped
/// talking, and it is the moment the follow-up clock starts.
@MainActor
final class SpeechOut {

    var onFirstAudio: (() -> Void)?
    var onIdle: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Told once when the premium voice runs out of credits: shown, not
    /// spoken, and the reply carries on in the local voice.
    var onNotice: ((String) -> Void)?

    private(set) var busy = false

    private let frontEnd: AudioFrontEnd
    private var backend: TtsBackend?
    private var voice = ""

    private var queue: [(text: String, replyEnd: Int?)] = []
    private var pump: Task<Void, Never>?

    /// What the person has actually heard of the current reply: every
    /// piece whose last buffer has been played out. Read on a barge-in to
    /// know where to resume from, and to tell the brain where it was cut.
    private(set) var heardText = ""
    /// Everything queued this reply, heard or not — the echo filter's
    /// reference.
    private(set) var spokenText = ""
    /// How far into the *raw* reply text the person has heard: the offset
    /// the caller attached to the last piece that was fully played out.
    /// Text-based matching between heard speech and the reply fails on
    /// every markdown, newline or narration; an offset does not.
    private(set) var heardReplyOffset = 0
    /// Pieces in flight: text, the cumulative sample count at which each
    /// one is fully heard, and the reply offset it carries (nil for an
    /// aside or a narration, which are not part of the reply's text).
    private var pieces: [(text: String, endsAt: Int, replyEnd: Int?)] = []
    /// Whether any of this utterance is a reply's own text. A preview or a
    /// nudge carries no offsets, so a tap that paused one has nothing to
    /// pick up from — and resuming it would read out the last reply instead.
    private(set) var carriesReply = false
    private var pendingReplyEnd: Int?
    private var samplesQueued = 0
    private var samplesHeard = 0

    /// The words around the playhead: the end of the last sentence heard and
    /// the one playing now. What the microphone hears of Moe's own voice
    /// through the canceller is *these*, a few hundred milliseconds late —
    /// the reference the judge compares a barge-in's words against before it
    /// pauses anything (`BargeInJudge`), rather than the whole reply.
    var textAroundPlayhead: String {
        let playing = pieces.first?.text ?? ""
        let before = String(heardText.suffix(80))
        return [before, playing].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Just the words that can be coming back through the microphone now:
    /// the sentence playing and the last ~2 s heard before it (30 characters
    /// at ~15 characters a second) — the canceller's echo arrives within a
    /// few hundred milliseconds and the recogniser writes it about half a
    /// second later. What a lone stop word or the name is checked against
    /// (`BargeInJudge.echoesThePlayhead`, review N1).
    var wordsAtPlayhead: String {
        let playing = pieces.first?.text ?? ""
        let before = String(heardText.suffix(30))
        return [before, playing].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A new reply: forget what the last one said.
    func beginReply() {
        // A new reply is the premium voice's next chance: one voice per
        // reply, and a fresh try at every reply (`localForReply`).
        localForReply = false
        heardText = ""
        spokenText = ""
        heardReplyOffset = 0
        carriesReply = false
        pieces.removeAll()
        pendingReplyEnd = nil
        samplesQueued = 0
        samplesHeard = 0
    }

    /// Forget what was rendered but will never be heard: after a stop, the
    /// counters must describe only what actually played.
    private func forgetUnheard() {
        pieces.removeAll()
        pendingReplyEnd = nil
        samplesQueued = samplesHeard
    }
    /// Captured by each pump; a retired pump's tail must not touch the
    /// state of the one that replaced it.
    private var generation = 0
    private var scheduledSamples = 0
    private var firstAudioPending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How far ahead of the speaker the synthesiser may run, in seconds of
    /// audio queued on the player. Enough to cover the next render; little
    /// enough that an interruption throws away almost nothing.
    private let aheadSeconds: Double = 2.5

    /// How much audio to have in hand before the speaker starts, for a
    /// backend that streams.
    ///
    /// `AudioFrontEnd.schedule` calls `player.play()` on the first buffer it
    /// is given. With a whole-utterance backend that is right: one buffer
    /// arrives holding the entire sentence and it plays gaplessly. With
    /// PocketTTS it is wrong — the first buffer is one 80 ms Mimi frame, so
    /// the speaker starts with 80 ms in hand and the player runs dry the
    /// moment a frame is late. `AVAudioPlayerNode` does not report that; it
    /// keeps "playing", emits silence, and the next buffer resumes — and a
    /// resume after a gap is the faint tap you hear between words.
    ///
    /// Measured on this Mac: PocketTTS renders at 2.9× realtime, so once it
    /// is ahead it stays ahead — it produces 80 ms of audio in ~28 ms. It
    /// only starves at the start, before it has built any cushion. So the
    /// fix is a head start, not a bigger buffer: hold the first frames until
    /// there are 250 ms of them, then release and let it run.
    ///
    /// The cost is honest and small: first audio moves from ~65 ms to ~250 ms
    /// for a streaming engine, which is still inside Kokoro's 171–360 ms and
    /// nowhere near the 700 ms where a pause starts to read as broken. A tap
    /// in every reply is worse than 185 ms.
    ///
    /// Zero disables it, which is what a whole-utterance backend wants: its
    /// single buffer is already longer than any pre-roll.
    ///
    /// Raised from 0.25 s to 0.5 s on 2026-10-15. The 0.25 s was set from
    /// 2.9× on an idle Mac; in use, 17 PocketTTS replies from 10-02 to 10-15
    /// ran dry mid-reply (6 once, 4 twice, 7 three to eight times), each a
    /// gap in the middle of a word. A quarter second more before the first word is
    /// still well inside the 700 ms where a pause reads as broken.
    nonisolated static let preRollSeconds: Double = 0.5

    /// How fast a streaming engine has really been rendering, in seconds of
    /// audio per second of wall clock, across recent sentences. `nil` until
    /// one has been timed.
    ///
    /// 250 ms of head start was set from the 2.9× measured on an idle Mac.
    /// During a live turn the synthesiser shares the machine with the brain,
    /// the recogniser and the wake word, and it falls behind: moe.log on
    /// 2026-10-02 shows PocketTTS replies with 5, 6 and 8 underruns each, and
    /// every one is a gap in the middle of a word. So the head start is now
    /// sized from this, measured speed rather than assumed (`headStart`).
    private var liveSpeed: Double?
    /// When `liveSpeed` was last measured.
    private var liveSpeedAt: Date?

    /// After this long without a render, a fast measurement no longer
    /// describes the engine. Measured on PocketTTS from 10-02 to 10-15: the
    /// first frame took 126 ms at the median within a minute of the last
    /// sentence, 610 ms after more than a minute idle, and 19 of the 26
    /// first frames over a second came after such an idle.
    nonisolated static let speedGoesStaleSeconds: Double = 60

    /// The speed to size a head start from: the measured one, unless it is
    /// stale *and* flattering. A stale slow number is still a warning worth
    /// heeding; a stale fast one is the warm engine an idle Mac no longer
    /// has, and sizing from it is how the first sentence after a pause ran
    /// dry. Then nothing is assumed and the floor stands.
    nonisolated static func speedForHeadStart(measured: Double?, measuredAt: Date?, now: Date) -> Double? {
        guard let measured, let at = measuredAt else { return measured }
        if now.timeIntervalSince(at) > speedGoesStaleSeconds, measured >= 1.2 { return nil }
        return measured
    }

    /// Times the player was handed a buffer with nothing left queued while
    /// more of the same utterance was still coming — the underrun that makes
    /// the tap. Logged per reply so the fix is falsifiable rather than
    /// believed.
    private var underruns = 0

    /// The cloud voice's trailing silence past `TrailingSilence.keepSeconds`,
    /// taken off the generation just rendered. Played in front of the next
    /// generation if one follows — it is the pause between two sentences —
    /// and dropped when the reply ends, so "done speaking" is not half a
    /// second late (`TrailingSilence`).
    private var heldTail: HeldTail?

    /// Seconds of speech in `chars` characters. PocketTTS and Kokoro both
    /// land near 20 characters a second (82 characters in 4.0 s measured on
    /// 2026-10-06); 15 overestimates on purpose, since running dry is worse
    /// than starting a moment late.
    nonisolated static func speechSeconds(_ chars: Int) -> Double { Double(chars) / 15 }

    /// The head start for a sentence of `speechSeconds`, given the engine's
    /// measured `speed`.
    ///
    /// An engine rendering at `speed` × realtime falls behind by
    /// `1 - speed` seconds per second of speech, so it needs that much of the
    /// sentence in hand before the first word. Counted against 1.2×, not 1×:
    /// live speed wanders, and an engine measured at 1.1× is one busy second
    /// from starving. Capped at 2 s; past that a long sentence would rather
    /// risk one refill than keep the person waiting.
    nonisolated static func headStart(floor: Double, speechSeconds: Double, speed: Double?) -> Double {
        guard floor > 0, let speed, speed > 0 else { return floor }
        let need = speechSeconds * max(0, 1 - speed / 1.2)
        return min(max(floor, floor + need), 2.0)
    }

    init(frontEnd: AudioFrontEnd) {
        self.frontEnd = frontEnd
        // Buffers are tagged with the pump generation that scheduled them.
        // `player.stop()` does not reliably call the completion handlers of
        // what it drops, and one that arrives late would under-run the new
        // pump's count and call the reply drained while it is still playing.
        frontEnd.onBufferHeard = { [weak self] frames, tag in
            guard let self, tag == self.generation else { return }
            self.heard(frames)
        }
        // The device went away under the player: what was queued will
        // never complete. Forget it so the pump renders what is left onto
        // the new device, or finishes and says so.
        frontEnd.onPlaybackLost = { [weak self] in
            guard let self else { return }
            self.scheduledSamples = 0
            self.heldTail = nil
            self.forgetUnheard()
            self.wakeWaiters()
        }
    }

    func use(backend: TtsBackend, voice: String) {
        self.backend = backend
        self.voice = voice
        premiumSpent = false
        reconnect.reset()
        frontEnd.setPlaybackRate(backend.sampleRate)
    }

    /// A local engine to re-render one sentence on when the main backend
    /// fails it mid-reply — the cloud voice's socket dying, or a token
    /// refused. Nil for a local backend, which has nothing to fall back to.
    private var localFallback: (backend: TtsBackend, voice: String)?

    func setLocalFallback(_ backend: TtsBackend?, voice: String) {
        localFallback = backend.map { ($0, voice) }
    }

    /// The premium voice refused a render for want of credits
    /// (`PremiumVoiceSpent`): every later sentence goes straight to the local
    /// engine, until the voice is loaded again. Without it each batch paid a
    /// fresh credential and a refusal before the local voice spoke it.
    private(set) var premiumSpent = false
    /// The notice is given once, not once a sentence; a cloud render that
    /// succeeds again re-arms it.
    private var spentNoticeGiven = false
    /// A dropped connection, as one episode (`PremiumVoiceReconnect`): the
    /// first sentence spoken locally for it says so once; the voice coming
    /// back is logged, not announced. Nothing here decides *when* to try the
    /// cloud again — every render is a try, made only at a sentence
    /// boundary, and `VoiceGate`'s short backoff answers the ones in between
    /// locally without a request.
    private var reconnect = PremiumVoiceReconnect()

    /// The premium voice's connection failed during this reply: the rest of
    /// it is spoken locally, and the cloud is tried again on the next one.
    ///
    /// It used to be retried at the next batch, mid-reply, so one reply went
    /// Clive → Heart → Clive: 13 voice changes inside 7 replies from 09-23 to
    /// 09-29, five of them back and forth (`audit-cloud-local.md`). A voice
    /// that changes once, at a failure, reads as a hiccup; one that changes
    /// back half a paragraph later reads as two people.
    private(set) var localForReply = false

    /// How many samples the premium voice spends per character, learned
    /// from its own finished renders, so a failed batch can be picked up
    /// where its audio stopped (`SpeechResume`). ~14 characters a second at
    /// 24 kHz until the first render says otherwise.
    private var cloudSamplesPerChar: Double = 1_700

    /// Queue something to say. Starts talking as soon as audio exists.
    /// - Parameter replyEnd: the offset into the raw reply text that this
    ///   piece ends at, when it is part of a reply; nil for asides.
    func speak(_ text: String, replyEnd: Int? = nil) {
        guard backend != nil, !text.isEmpty else { return }
        queue.append((text, replyEnd))
        if replyEnd != nil { carriesReply = true }
        spokenText += (spokenText.isEmpty ? "" : " ") + text
        busy = true
        if pump == nil {
            firstAudioPending = true
            startPump()
        } else {
            wakeWaiters()
        }
    }

    /// Stop now and forget everything queued.
    /// Held mid-reply: the speaker is silent, the place is kept, and the
    /// pump keeps rendering ahead into the queue. `resume()` plays on from
    /// the exact sample; `stop()` throws it all away as before.
    private(set) var isPaused = false

    func pause() {
        guard busy, !isPaused else { return }
        isPaused = true
        frontEnd.pausePlayback()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        frontEnd.resumePlayback()
    }

    func stop() {
        isPaused = false
        pump?.cancel()
        pump = nil
        // The engine too, not only the pump: a cloud backend keeps
        // generating (and billing) until it is told to stop. A no-op for
        // the local ones.
        if let backend { Task { await backend.cancel() } }
        generation &+= 1
        queue.removeAll()
        frontEnd.stopPlayback()
        scheduledSamples = 0
        heldTail = nil
        forgetUnheard()
        busy = false
        wakeWaiters()
    }

    // MARK: - The pump

    private func startPump() {
        generation &+= 1
        let gen = generation
        pump = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == gen {
                if !self.queue.isEmpty {
                    // The premium voice is out of credits: the local engine,
                    // sentence by sentence, without asking the cloud first.
                    if self.premiumSpent || self.localForReply, self.backend?.isCloudBackend == true,
                       let local = self.localFallback {
                        let next = self.queue.removeFirst()
                        for piece in SpeechBatch.forLocalEngine([.init(text: next.text, replyEnd: next.replyEnd)]) {
                            guard self.generation == gen, !Task.isCancelled else { break }
                            await self.render(piece.text, replyEnd: piece.replyEnd, generation: gen, via: local)
                        }
                        continue
                    }
                    // A streaming cloud voice takes everything queued in one
                    // request, so it is spoken as a passage rather than as
                    // separately generated sentences (`SpeechBatch`). A local
                    // engine keeps its sentence-sized pieces.
                    if self.backend?.isCloudBackend == true {
                        let parts = SpeechBatch.take(parts: self.queue.map { .init(text: $0.text, replyEnd: $0.replyEnd) })
                        if parts.count > 1 {
                            self.queue.removeFirst(parts.count)
                            let text = parts.map(\.text).joined(separator: " ")
                            await self.render(text, replyEnd: parts.last?.replyEnd, parts: parts, generation: gen)
                            continue
                        }
                    }
                    let next = self.queue.removeFirst()
                    await self.render(next.text, replyEnd: next.replyEnd, generation: gen)
                    continue
                }
                if self.scheduledSamples <= 0 { break }
                // Nothing to render, audio still playing: wait for a buffer
                // to finish and look again — more text may have arrived.
                await self.waitForHeard()
            }
            guard self.generation == gen, !Task.isCancelled else { return }
            if let tail = self.heldTail {
                // Nothing followed the last generation: its silence is not
                // a pause before anything, and is never played.
                Log.write("tts: reply ended \(tail.milliseconds) ms sooner — trailing silence trimmed")
                self.heldTail = nil
            }
            self.pump = nil
            self.busy = false
            self.onIdle?()
        }
    }

    /// - Parameter via: the engine to render on instead of the configured
    ///   one — the local fallback, on the one retry after a cloud failure.
    /// - Parameter parts: the sentences a cloud batch was made of, so each
    ///   is marked heard when its share of the audio has played rather than
    ///   the whole passage at its last sample (`SpeechBatch.partEnds`).
    private func render(_ text: String, replyEnd: Int?, parts: [SpeechBatch.Piece]? = nil,
                        generation gen: Int,
                        via override: (backend: TtsBackend, voice: String)? = nil) async {
        guard let backend = override?.backend ?? self.backend else { return }
        var startQueued = samplesQueued
        let rate = backend.sampleRate
        let voice = override?.voice ?? self.voice
        let began = Date()
        var first = true
        var total = 0
        // Inworld only: every generation ends with ~0.5 s of silence
        // (`TrailingSilence`). A local engine's tail is its own and short.
        var trimmer: TrailingSilence? = (override == nil && backend.isCloudBackend)
            ? TrailingSilence(sampleRate: rate) : nil
        // The premium voice is watched: a stream that stops producing sound
        // is ended in about a second rather than whenever the socket is
        // declared dead — 67 s on 2026-09-29 (`TtsStallGuard`).
        let watched = override == nil && backend.isCloudBackend
        do {
            let stream: AsyncThrowingStream<[Float], Error>
            if watched {
                stream = TtsStallGuard.wrap(
                    bufferedSeconds: { [weak self] in
                        await self?.bufferedSeconds(at: rate) ?? 0
                    },
                    start: { try await backend.stream(text, voice: voice) })
            } else {
                stream = try await backend.stream(text, voice: voice)
            }
            // Held back until there is `preRollSeconds` of audio, so the
            // speaker does not start on 80 ms and immediately run dry.
            var preRoll: [Float] = []
            let preRollTarget = Int(rate * Self.headStart(
                floor: Self.preRollSeconds, speechSeconds: Self.speechSeconds(text.count),
                speed: Self.speedForHeadStart(measured: liveSpeed, measuredAt: liveSpeedAt, now: Date())))
            // True until the head start is in hand, and again after the
            // player runs dry, so a slow render costs one clean pause to
            // rebuild the cushion instead of a stutter on every frame.
            var rebuffering = true
            var produced = 0
            var firstFrameAt: Date?
            var synthesisMs: Int?
            for try await frame in stream {
                guard self.generation == gen, !Task.isCancelled else { return }
                // The synthesiser has produced sound. Marked here, before the
                // pre-roll and before the wait for room below, because neither
                // is synthesis and folding them in read as a slow model:
                // renders of *ten characters* logged at 12.5 s, which was the
                // previous sentences still playing against a queue held 2.5 s
                // ahead. Length did not predict the number, which is the tell
                // that it was never measuring the model.
                if synthesisMs == nil { synthesisMs = VoiceEngine.msSince(began) }
                if firstFrameAt == nil { firstFrameAt = Date() }
                produced += frame.count
                var samples = frame
                if trimmer != nil { samples = trimmer!.push(frame) }
                if !first, !rebuffering, scheduledSamples == 0 {
                    // Nothing queued and more still to come: the player has
                    // already emitted silence. Hold this frame and refill.
                    underruns += 1
                    rebuffering = true
                }
                if rebuffering, preRollTarget > 0, !preRoll.isEmpty || samples.count < preRollTarget {
                    preRoll.append(contentsOf: samples)
                    guard preRoll.count >= preRollTarget else { continue }
                    samples = preRoll
                    preRoll = []
                }
                rebuffering = false
                // Wait for room, never for silence.
                while Double(scheduledSamples) / rate > aheadSeconds {
                    await waitForHeard()
                    guard self.generation == gen, !Task.isCancelled else { return }
                }
                guard !samples.isEmpty else { continue }
                if first {
                    first = false
                    let waited = VoiceEngine.msSince(began) - (synthesisMs ?? 0)
                    Log.write("tts: \(text.count) chars synthesised in \(synthesisMs ?? 0) ms"
                              + (waited > 250 ? ", then queued \(waited) ms behind the reply still playing" : ""))
                }
                // The graph may be down for a moment after a device change;
                // rendered audio waits for it rather than being thrown at a
                // stopped engine and reported as heard.
                var waited = 0
                while !frontEnd.isRunning, waited < 25 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                    guard self.generation == gen, !Task.isCancelled else { return }
                }
                // The last generation's silence, if this one follows it: the
                // pause between the two sentences, put back.
                let pause = takeHeldTail(rate: rate)
                if !pause.isEmpty { samples = pause + samples }
                if frontEnd.schedule(samples, tag: gen) {
                    scheduledSamples += samples.count
                    total += samples.count
                    samplesQueued += samples.count
                    startQueued += pause.count
                    startedPlaying()
                }
            }
            // How fast that really was. Only a render that took real time
            // says anything: a whole-sentence engine yields once, instantly.
            if let start = firstFrameAt, self.generation == gen {
                let wall = Date().timeIntervalSince(start)
                if wall >= 0.3 {
                    let speed = Double(produced) / rate / wall
                    // A stale reading is replaced, not averaged in.
                    let fresh = Self.speedForHeadStart(measured: liveSpeed, measuredAt: liveSpeedAt, now: Date())
                    liveSpeed = fresh.map { 0.5 * $0 + 0.5 * speed } ?? speed
                    liveSpeedAt = Date()
                }
            }
            // The end of the generation: keep a natural stop, hold the rest.
            var held: [Float] = []
            if trimmer != nil {
                let end = trimmer!.finish()
                preRoll.append(contentsOf: end.keep)
                held = end.held
            }
            // Whatever is still held back at the end of the stream: a reply
            // shorter than the pre-roll would otherwise never be spoken.
            if !preRoll.isEmpty, self.generation == gen, !Task.isCancelled {
                let pause = takeHeldTail(rate: rate)
                if !pause.isEmpty { preRoll = pause + preRoll }
                if frontEnd.schedule(preRoll, tag: gen) {
                    scheduledSamples += preRoll.count
                    total += preRoll.count
                    samplesQueued += preRoll.count
                    startQueued += pause.count
                    if first {
                        first = false
                        Log.write("tts: \(text.count) chars synthesised in \(synthesisMs ?? VoiceEngine.msSince(began)) ms")
                    }
                    startedPlaying()
                }
            }
            if total == 0 {
                Log.write("tts: no audio for \(text.count) chars")
            } else if override == nil, backend.isCloudBackend {
                // This voice's pace, for picking a failed batch up where its
                // audio stopped.
                if text.count >= 40 {
                    cloudSamplesPerChar = 0.7 * cloudSamplesPerChar + 0.3 * Double(total) / Double(text.count)
                }
                // Credits back: a later run-out is news again.
                spentNoticeGiven = false
                // Connection back: said in the log only. This sentence was
                // the first try after the hold, so it is also the first one
                // in the premium voice again — a whole sentence, never half.
                let local = reconnect.sentencesLocal
                if let away = reconnect.succeeded() {
                    Log.write("tts: premium voice back after \(Int(away.rounded())) s — "
                              + "\(local) sentence(s) were spoken locally; resumed at a sentence boundary")
                }
            }
            if underruns > 0 {
                Log.write("tts: \(underruns) underrun(s) — the player ran dry mid-reply")
                underruns = 0
            }
            // Heard once every sample up to here has been played out.
            // Not after a `stop()`: the cancelled render would land its
            // cut-off piece on the cleared list with an end already
            // reached, and the next buffer would mark it heard.
            guard self.generation == gen, !Task.isCancelled else { return }
            if !held.isEmpty {
                heldTail = HeldTail(samples: held, sampleRate: rate,
                                    startsAt: Date().addingTimeInterval(Double(scheduledSamples) / rate))
            }
            if let parts, parts.count > 1 {
                let ends = SpeechBatch.partEnds(start: startQueued, total: samplesQueued - startQueued,
                                                lengths: parts.map(\.text.count))
                for (part, end) in zip(parts, ends) { pieces.append((part.text, end, part.replyEnd)) }
            } else {
                pieces.append((text, samplesQueued, replyEnd))
            }
        } catch {
            guard self.generation == gen, !Task.isCancelled else { return }
            if let stalled = error as? TtsStalled {
                Log.write("tts: premium voice \(stalled) — the socket is dropped and the rest of this reply goes to the Mac's voice")
                Task { await backend.abandonConnection() }
            }
            // Out of credits does not heal between two sentences: stop
            // asking, and say so once (`PremiumVoiceSpent`).
            if override == nil, backend.isCloudBackend, PremiumVoiceSpent.matches(error) {
                if !premiumSpent {
                    Log.write("tts: the premium voice is out of credits — local voice for the rest of this voice")
                }
                premiumSpent = true
                if !spentNoticeGiven {
                    spentNoticeGiven = true
                    onNotice?(PremiumVoiceSpent.notice)
                }
            }
            // The connection dropped: one quiet line for the whole stretch,
            // never one per sentence (`PremiumVoiceReconnect`). Out of
            // credits and every other refusal keep their own handling.
            if override == nil, backend.isCloudBackend,
               case .connection(let notice) = reconnect.failed(error) {
                localForReply = true
                if let notice {
                    Log.write("tts: connection dropped (\(error)) — the Mac's voice until the premium voice answers again")
                    onNotice?(notice)
                }
            }
            // The sentence is not dropped: once, on the local engine. Same
            // sample rate only — the player was set for this one and is
            // mid-reply. Anything already scheduled from the failed stream
            // is repeated, which beats a hole in the sentence.
            if override == nil, let local = localFallback, local.backend.sampleRate == rate {
                // In pieces the local engine accepts: a batch is past what
                // Kokoro will speak at all.
                let whole = parts ?? [SpeechBatch.Piece(text: text, replyEnd: replyEnd)]
                let pieces = SpeechBatch.forLocalEngine(whole)
                // What already reached the player plays out; the local voice
                // takes over at the first piece it does not hold in full,
                // instead of saying the batch again from the top.
                let skip = SpeechResume.partsDelivered(lengths: pieces.map(\.text.count),
                                                       samplesScheduled: total,
                                                       samplesPerChar: cloudSamplesPerChar,
                                                       sampleRate: rate)
                Log.write("tts: cloud render failed on \(text.count) chars after \(total) samples (\(error)); "
                          + "re-rendering locally"
                          + (skip > 0 ? " from piece \(skip + 1) of \(pieces.count) — the first \(skip) already played" : ""))
                var at = startQueued
                for piece in pieces.prefix(skip) {
                    at = min(samplesQueued, at + Int(Double(piece.text.count + 1) * cloudSamplesPerChar))
                    self.pieces.append((piece.text, at, piece.replyEnd))
                }
                for piece in pieces.dropFirst(skip) {
                    guard self.generation == gen, !Task.isCancelled else { return }
                    await render(piece.text, replyEnd: piece.replyEnd, generation: gen, via: local)
                }
                return
            }
            Log.write("TTS FAILED on \(text.count) chars: \(error)")
            onError?("Couldn't speak that: \(error.localizedDescription)")
        }
    }

    /// Audio on the player not yet heard: how long sound goes on if
    /// nothing more arrives (`TtsStallGuard`).
    private func bufferedSeconds(at rate: Double) -> Double {
        Double(scheduledSamples) / rate
    }

    /// The held silence of the generation before, as much of it as is still
    /// owed (`HeldTail.remainder`), taken once.
    private func takeHeldTail(rate: Double) -> [Float] {
        guard let tail = heldTail else { return [] }
        heldTail = nil
        guard tail.sampleRate == rate else { return [] }
        return tail.remainder(now: Date(), playerHasAudio: scheduledSamples > 0)
    }

    /// The first buffer of a reply has reached the player, so sound is
    /// starting now.
    ///
    /// This used to fire from `heard(_:)`, which runs on the player's
    /// completion callback — and that callback is registered
    /// `.dataPlayedBack`, so it arrives when a buffer has *finished*. The
    /// mark was therefore "the first chunk stopped being spoken", late by
    /// however long that chunk was, and `TurnTrace.feltLatencyMs` —
    /// documented as "the gap between the user stopping and the first word
    /// being heard" — was reporting a whole sentence more than the gap.
    /// Measured on this Mac before the fix: 2,412 ms at p50 between queueing
    /// audio and "hearing" it, against `tts: first audio` lines showing the
    /// synthesiser producing its first frame in about 450 ms. The difference
    /// was the sentence, not silence.
    private func startedPlaying() {
        guard firstAudioPending else { return }
        firstAudioPending = false
        onFirstAudio?()
    }

    private func heard(_ frames: Int) {
        scheduledSamples = max(0, scheduledSamples - frames)
        samplesHeard += frames
        // Every piece whose last sample has now played is heard.
        while let first = pieces.first, first.endsAt <= samplesHeard {
            heardText += (heardText.isEmpty ? "" : " ") + first.text
            if let end = first.replyEnd { heardReplyOffset = max(heardReplyOffset, end) }
            pieces.removeFirst()
        }
        wakeWaiters()
    }

    private func waitForHeard() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    private func wakeWaiters() {
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }
}
