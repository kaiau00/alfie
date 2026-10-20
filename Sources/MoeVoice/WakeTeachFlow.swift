import Foundation

/// "Teach Moe its name", as a card: what is on screen, what each press
/// does, and what the app has to do about it.
///
/// Pure. The card draws `step`; every button, key and microphone report is
/// an `Event` sent to `send`, which moves the step and returns the
/// `Effect`s the app must carry out — open the microphone, record line 4,
/// throw away line 3's clip, measure. Nothing here touches audio, so every
/// path through the card — a retake, a pause in the middle of a clip, a
/// cancel while the microphone is open, a late report from a take that was
/// already abandoned — is a test, not a hope.
///
/// It replaced one long loop in `VoiceEngine` that showed each line as a
/// sentence under the switch and silently skipped any clip it did not like
/// (2026-09-24): no way to see that the microphone heard you, to redo a
/// clip, or to stop and carry on later.
public struct WakeTeachFlow: Equatable, Sendable {

    /// One thing to say.
    public struct Line: Equatable, Sendable {
        public var say: String
        public var note: String
        /// "Hey Moe" is in it (a positive), rather than a sound-alike.
        public var isName: Bool
        public init(say: String, note: String, isName: Bool) {
            self.say = say; self.note = note; self.isName = isName
        }
    }

    /// What was wrong with a clip, and what to do about it. Every one but
    /// `tooQuiet` means the clip was not kept; a quiet clip is kept, with
    /// the advice shown as a note, because quiet is how the wake word
    /// hears most people in standby (`judge`).
    public enum Problem: Equatable, Sendable {
        /// Nothing that sounded like speech within the wait, or nothing
        /// that rose above the room.
        case nothingHeard
        /// Speech, but quieter than any "Hey Moe" the wake word has woken
        /// to. Kept, with a note.
        case tooQuiet
        /// Shorter than any "Hey Moe" — a click, a cough.
        case tooShort
        /// So loud the microphone ran out of range.
        case clipped

        public var title: String {
            switch self {
            case .nothingHeard: return "Moe didn't hear anything"
            case .tooQuiet: return "Got it — that one was quiet"
            case .tooShort: return "That was too short to be the phrase"
            case .clipped: return "That was too loud — the sound broke up"
            }
        }

        public var advice: String {
            switch self {
            case .nothingHeard: return "Check the microphone is on, then say it when you see it."
            case .tooQuiet: return "It's kept. If it's easy, say the next one a little louder or closer to the Mac."
            case .tooShort: return "Say the whole phrase, at your normal pace."
            case .clipped: return "Say it a little softer, or move back from the microphone."
            }
        }
    }

    /// What one clip measured: the numbers the judge reads, and the ones
    /// the log prints for every clip so a report can be read back.
    ///
    /// Levels are 32 ms frames of the clip as it was recorded — the same
    /// 16 kHz stream, and in standby the same unprocessed microphone, that
    /// the wake word listens to — so "loud enough to teach" and "loud
    /// enough to wake" are one question. The voice is the loudest tenth of
    /// the frames and the room the quietest fifth: the clip carries a
    /// margin of room either side of the phrase, and an average over the
    /// whole window would count that silence against the voice.
    public struct ClipLevel: Equatable, Sendable {
        public var seconds: Double
        /// The voice: the 90th-percentile frame, dBFS.
        public var speechDb: Float
        /// The room: the 20th-percentile frame, dBFS.
        public var floorDb: Float
        /// The single loudest sample, 0…1.
        public var peak: Float
        /// Samples at full scale (`fullScale`).
        public var clippedSamples: Int

        public init(seconds: Double, speechDb: Float, floorDb: Float, peak: Float, clippedSamples: Int) {
            self.seconds = seconds; self.speechDb = speechDb; self.floorDb = floorDb
            self.peak = peak; self.clippedSamples = clippedSamples
        }

        public static func measure(_ samples: [Float], rate: Double = 16_000, frame: Int = 512) -> ClipLevel {
            let seconds = Double(samples.count) / rate
            var frames: [Float] = []
            var i = 0
            while i < samples.count {
                let end = min(samples.count, i + frame)
                var sum: Float = 0
                for v in samples[i..<end] { sum += v * v }
                frames.append(db(rms: (sum / Float(end - i)).squareRoot()))
                i = end
            }
            frames.sort()
            func at(_ q: Double) -> Float {
                frames.isEmpty ? -120 : frames[min(frames.count - 1, Int(Double(frames.count) * q))]
            }
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            return ClipLevel(seconds: seconds, speechDb: at(0.9), floorDb: at(0.2), peak: peak,
                             clippedSamples: WakeTeachFlow.clippedSamples(samples))
        }

        static func db(rms: Float) -> Float { 20 * log10(max(rms, 1e-6)) }

        /// "voice -54.3 dBFS, room -85.2 dBFS, peak 0.021 (-33.6 dBFS), 1.42 s"
        public var description: String {
            String(format: "voice %.1f dBFS, room %.1f dBFS, peak %.3f (%.1f dBFS), %.2f s%@",
                   speechDb, floorDb, peak, Self.db(rms: peak), seconds,
                   clippedSamples > 0 ? ", \(clippedSamples) sample(s) at full scale" : "")
        }
    }

    /// What to do with one clip.
    public enum Verdict: Equatable, Sendable {
        case keep
        /// Kept, with the `tooQuiet` note.
        case keepQuiet
        case reject(Problem)

        /// For the log: "kept", "kept, quiet", "not kept: clipped".
        public var words: String {
            switch self {
            case .keep: return "kept"
            case .keepQuiet: return "kept, quiet"
            case .reject(let p): return "not kept: \(p)"
            }
        }
    }

    /// The judge for one clip. Only a clip that would teach the wrong
    /// thing is refused: too short to be the phrase, distorted, or nothing
    /// in it above the room. Quiet is kept, with a note.
    ///
    /// The bars are measured, not chosen. Until 2026-09-25 a clip whose
    /// loudest sample was under 0.02 (−34 dBFS) was refused as "too
    /// quiet" — a bar from 2026-09-03, set on clips recorded with Apple's
    /// voice processing on (the owner's 65 "Hey Moe"s of 2026-09-04: voice
    /// −18.6 dBFS median, peak 0.38). But the card records in standby,
    /// where voice processing is bypassed and its automatic gain with it,
    /// and there the owner's normal voice is 30 dB lower: across 31 "Hey
    /// Moe"s that woke the live wake word in standby (2026-09-23…25, read
    /// from the wake turns' debug clips), voice −54.3 dBFS median, −60.6
    /// at the 10th percentile, −48.3 at the loudest, the room −85 dBFS,
    /// and a peak under 0.02 in 15 of the 31. Half of the phrases Moe
    /// actually woke to were being refused as too quiet to learn from.
    public static func judge(_ l: ClipLevel) -> Verdict {
        if l.seconds <= minSeconds { return .reject(.tooShort) }
        if l.clippedSamples >= clippedRun { return .reject(.clipped) }
        if l.speechDb < silentDb || l.speechDb - l.floorDb < minOverRoomDb { return .reject(.nothingHeard) }
        if l.speechDb < quietDb { return .keepQuiet }
        return .keep
    }

    /// Shorter than this is not the phrase (the recorder's rule since 2026-09-03).
    public static let minSeconds = 0.3
    /// A voice under this is no voice: 10 dB over the median standby room
    /// (−85 dBFS), and 20 dB under the quietest real "Hey Moe" measured.
    public static let silentDb: Float = -75
    /// A voice must clear the clip's own room by this much. The pipeline's
    /// gate already asks 5 dB of an onset (`NoiseFloorGate`); the quietest
    /// real "Hey Moe" measured cleared its room by 17 dB.
    public static let minOverRoomDb: Float = 6
    /// Under this the clip is kept with a note: below every real "Hey Moe"
    /// the wake word woke to but two (−60.6 dBFS is the 10th percentile).
    public static let quietDb: Float = -62

    /// How many full-scale samples make a clip "clipped". One or two is a
    /// plosive grazing the top; a handful is the converter giving up.
    public static let clippedRun = 8
    /// What counts as full scale.
    public static let fullScale: Float = 0.99

    public static func clippedSamples(_ samples: [Float]) -> Int {
        samples.reduce(0) { $0 + (abs($1) >= fullScale ? 1 : 0) }
    }

    /// How one recording went.
    public enum ClipResult: Equatable, Sendable {
        case kept
        /// Kept, and the card says it was quiet (`Problem.tooQuiet`).
        case keptQuiet
        case rejected(Problem)
    }

    /// Why the card could not finish.
    public enum Failure: Error, Equatable, Sendable {
        /// The microphone is taken — a conversation, dictation, a test.
        case busy
        /// No usable "Hey Moe" among the clips, so nothing to measure.
        case heardNothing
        /// The microphone or a model is missing; the sentence says which.
        case unavailable(String)

        public var text: String {
            switch self {
            case .busy: return "Moe is using the microphone for something else. Try again in a moment."
            case .heardNothing: return "Moe didn't hear a “Hey Moe” it could use. Try again, a little closer to the Mac."
            case .unavailable(let why): return why
            }
        }
    }

    /// The measurement, as the card shows it.
    public struct Outcome: Equatable, Sendable {
        public var pick: WakeCalibration.Pick
        public var changed: Bool
        public init(pick: WakeCalibration.Pick, changed: Bool) { self.pick = pick; self.changed = changed }

        public var names: Int { pick.after.positives }
        public var caughtNow: Int { pick.after.caught }
        public var caughtBefore: Int { pick.before.caught }
        public var soundAlikes: Int { pick.after.confusables }
        public var letThroughNow: Int { pick.after.falseAccepts }
        public var letThroughBefore: Int { pick.before.falseAccepts }

        /// The card's title.
        public var title: String {
            changed ? "Moe hears you better now" : "Moe already hears you well"
        }

        /// One line, the numbers only: "Catches 11 of your 12 “Hey Moe”s
        /// (was 8) · lets through 1 of 8 sound-alikes (was 2)". A "was"
        /// only where the number moved — "(was 8)" beside an 8 is noise.
        public var headline: String {
            var line = "Catches \(caughtNow) of your \(names) “Hey Moe”\(names == 1 ? "" : "s")"
            if caughtBefore != caughtNow { line += " (was \(caughtBefore))" }
            guard soundAlikes > 0 else { return line }
            line += " · lets through \(letThroughNow) of \(soundAlikes) sound-alike\(soundAlikes == 1 ? "" : "s")"
            if letThroughBefore != letThroughNow { line += " (was \(letThroughBefore))" }
            return line
        }

        /// The same result in a sentence — `WakeCalibration.summary`, the
        /// words Settings has always used.
        public var summary: String { WakeCalibration.summary(pick, changed: changed) }
    }

    /// Where the card is.
    public enum Step: Equatable, Sendable {
        /// Why, how long, and what happens to the clips. Nothing is open.
        case intro
        /// The microphone is being opened.
        case starting
        /// Line `index` is on screen and Moe is waiting for it.
        case listening(Int)
        /// Moe hears speech: "Recording…".
        case hearing(Int)
        /// Kept: the "Got it ✓" beat, then the next line by itself.
        case gotIt(Int)
        /// Not kept, and why. Waits for the person: whatever went wrong
        /// usually needs them to change something first.
        case retake(Int, Problem)
        /// Stopped on line `index`, microphone closed; that line again on resume.
        case paused(Int)
        /// Scoring the clips, `done` of `total` so far (0 of 0 until the
        /// first report).
        case measuring(done: Int, total: Int)
        case result(Outcome)
        case failed(Failure)
        /// The card is gone.
        case closed
    }

    public enum Event: Equatable, Sendable {
        case start
        case micReady
        case micFailed(Failure)
        /// Speech began during take `take`.
        case speechBegan(take: Int)
        /// Take `take` is over.
        case clip(take: Int, ClipResult)
        /// The "Got it" beat has been shown.
        case advance
        case retake
        /// Leave this line out and go on.
        case skip
        /// Throw away the last kept clip and say it again.
        case redoPrevious
        case pause
        case resume
        /// Measure what has been recorded so far, from a pause.
        case finishEarly
        case measuring(done: Int, total: Int)
        case measured(WakeCalibration.Pick, changed: Bool)
        case measureFailed(Failure)
        case teachAgain
        case cancel
    }

    public enum Effect: Equatable, Sendable {
        /// Open the microphone, then send `.micReady` or `.micFailed`.
        case openMic
        /// Record `line` as take `take`; report `.speechBegan` and `.clip`
        /// with that take.
        case record(line: Int, take: Int)
        /// Abandon the take in flight; it must report nothing that is kept.
        case stopRecording
        /// Delete the clip kept for `line` from disk.
        case discard(line: Int)
        /// Show the "Got it" beat, then send `.advance`.
        case beat
        case closeMic
        /// Score every clip; report `.measuring` and then `.measured` or `.measureFailed`.
        case measure
        case dismiss
    }

    public let lines: [Line]
    public private(set) var step: Step = .intro
    /// Per line: was a clip kept for it.
    public private(set) var kept: [Bool]
    /// Per line: left out on purpose.
    public private(set) var skipped: [Bool]
    /// The take in flight. A report carrying any other number is from an
    /// abandoned take — one that was paused, redone or cancelled while it
    /// was still listening — and is ignored.
    public private(set) var take = 0
    /// The clip on the "Got it" beat was kept but quiet: the beat shows
    /// the `tooQuiet` note, and stays up long enough to read it.
    public private(set) var lastKeptQuiet = false

    public init(lines: [Line]) {
        self.lines = lines
        kept = Array(repeating: false, count: lines.count)
        skipped = Array(repeating: false, count: lines.count)
    }

    // MARK: - Reading the state

    /// The line on screen, while there is one.
    public var index: Int? {
        switch step {
        case .listening(let i), .hearing(let i), .gotIt(let i), .retake(let i, _), .paused(let i): return i
        default: return nil
        }
    }

    public var line: Line? { index.map { lines[$0] } }

    /// Whether a take is recording now.
    public var recording: Bool {
        switch step {
        case .listening, .hearing: return true
        default: return false
        }
    }

    /// Whether the microphone is open (the card holds it from `.starting`
    /// until measuring, and gives it up while paused).
    public var micOpen: Bool {
        switch step {
        case .starting, .listening, .hearing, .gotIt, .retake: return true
        default: return false
        }
    }

    public var keptCount: Int { kept.filter { $0 }.count }
    public var keptNames: Int { zip(kept, lines).filter { $0.0 && $0.1.isName }.count }

    /// One dot per line, for the progress row.
    public enum Dot: Equatable, Sendable { case done, skipped, current, pending }
    public var dots: [Dot] {
        (0..<lines.count).map { i in
            if i == index, !kept[i] { return .current }
            if kept[i] { return .done }
            if skipped[i] { return .skipped }
            return .pending
        }
    }

    /// The earliest line that has a clip to redo: the one just before the
    /// line on screen, if it was kept.
    public var canRedoPrevious: Bool {
        guard let i = index, i > 0, kept[i - 1] else { return false }
        switch step {
        case .listening, .hearing, .retake, .paused: return true
        default: return false
        }
    }

    public var canFinishEarly: Bool {
        if case .paused = step { return keptNames > 0 }
        return false
    }

    /// What Space does here, and the words on the button it presses.
    public var primary: (event: Event, title: String)? {
        switch step {
        case .intro: return (.start, "Start")
        case .listening, .hearing: return (.pause, "Pause")
        case .paused: return (.resume, "Carry on")
        case .retake: return (.retake, "Try again")
        case .result: return (.cancel, "Done")
        case .failed: return (.teachAgain, "Try again")
        case .starting, .gotIt, .measuring, .closed: return nil
        }
    }

    /// What VoiceOver says when the step changes: the card moves on by
    /// itself, so a person who cannot see it must hear each prompt.
    public var announcement: String? {
        switch step {
        case .listening(let i):
            return "\(i + 1) of \(lines.count). Say: \(lines[i].say)"
        case .gotIt:
            return lastKeptQuiet ? "\(Problem.tooQuiet.title). \(Problem.tooQuiet.advice)" : "Got it"
        case .retake(_, let problem): return "\(problem.title). \(problem.advice)"
        case .paused: return "Paused"
        case .measuring(0, 0): return "Measuring how Moe hears you"
        case .result(let o): return "\(o.title). \(o.headline)"
        case .failed(let why): return why.text
        default: return nil
        }
    }

    // MARK: - Moving

    @discardableResult
    public mutating func send(_ event: Event) -> [Effect] {
        switch (step, event) {

        case (.closed, _):
            return []

        case (_, .cancel):
            // A run that did not reach a result leaves nothing behind: the
            // clips it kept are deleted and the setting is untouched. Once
            // measuring has begun, closing the card does not stop it — the
            // result is applied as it would have been, just not shown.
            var out: [Effect] = []
            if recording { out.append(.stopRecording) }
            if micOpen { out.append(.closeMic) }
            switch step {
            case .measuring, .result: break
            default: out += kept.indices.filter { kept[$0] }.map { Effect.discard(line: $0) }
            }
            step = .closed
            return out + [.dismiss]

        case (.intro, .start):
            step = .starting
            return [.openMic]

        case (.result, .teachAgain), (.failed, .teachAgain):
            kept = Array(repeating: false, count: lines.count)
            skipped = Array(repeating: false, count: lines.count)
            step = .starting
            return [.openMic]

        case (.starting, .micReady):
            return begin(0)

        case (.starting, .micFailed(let why)):
            step = .failed(why)
            return []

        case (_, .micFailed(let why)) where recording:
            // Carrying on after a pause, and the microphone would not open.
            step = .failed(why)
            return [.stopRecording]

        case (.listening(let i), .speechBegan(let t)) where t == take:
            step = .hearing(i)
            return []

        case (.listening(let i), .clip(let t, let result)) where t == take,
             (.hearing(let i), .clip(let t, let result)) where t == take:
            switch result {
            case .kept, .keptQuiet:
                kept[i] = true
                lastKeptQuiet = result == .keptQuiet
                skipped[i] = false
                step = .gotIt(i)
                return [.beat]
            case .rejected(let problem):
                step = .retake(i, problem)
                return []
            }

        case (.gotIt(let i), .advance):
            return next(after: i)

        case (.retake(let i, _), .retake):
            return begin(i)

        case (.retake(let i, _), .skip):
            skipped[i] = true
            return next(after: i)

        case (.listening(let i), .pause), (.hearing(let i), .pause):
            step = .paused(i)
            return [.stopRecording, .closeMic]

        case (.retake(let i, _), .pause):
            step = .paused(i)
            return [.closeMic]

        case (.paused(let i), .resume):
            // The microphone was given up for the pause; `.micReady` from
            // `.starting` would restart at line 0, so resume carries its
            // own line back.
            step = .listening(i)
            take += 1
            return [.openMic, .record(line: i, take: take)]

        case (.paused, .finishEarly) where keptNames > 0:
            step = .measuring(done: 0, total: 0)
            return [.measure]

        case (_, .redoPrevious) where canRedoPrevious:
            let i = index! - 1
            let wasRecording = recording
            var wasPaused = false
            if case .paused = step { wasPaused = true }
            kept[i] = false
            step = .listening(i)
            take += 1
            var out: [Effect] = []
            if wasRecording { out.append(.stopRecording) }
            out.append(.discard(line: i))
            if wasPaused { out.append(.openMic) }
            out.append(.record(line: i, take: take))
            return out

        case (.measuring, .measuring(let done, let total)):
            step = .measuring(done: done, total: total)
            return []

        case (.measuring, .measured(let pick, let changed)):
            step = .result(Outcome(pick: pick, changed: changed))
            return []

        case (.measuring, .measureFailed(let why)):
            step = .failed(why)
            return []

        default:
            // Anything else is a press or a report that does not apply
            // here — a late clip from an abandoned take, Space during the
            // "Got it" beat. Ignored, and nothing changes.
            return []
        }
    }

    private mutating func begin(_ i: Int) -> [Effect] {
        lastKeptQuiet = false
        step = .listening(i)
        take += 1
        return [.record(line: i, take: take)]
    }

    /// The next line, or — after the last — measure. With no "Hey Moe"
    /// kept at all there is nothing to measure, and saying so beats a
    /// measurement of nothing.
    private mutating func next(after i: Int) -> [Effect] {
        if i + 1 < lines.count { return begin(i + 1) }
        guard keptNames > 0 else {
            step = .failed(.heardNothing)
            return [.closeMic]
        }
        step = .measuring(done: 0, total: 0)
        return [.closeMic, .measure]
    }
}
