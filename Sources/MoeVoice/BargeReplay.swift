import Foundation

/// The barge-in half of the turn bench: a `TurnTape` recorded while Moe was
/// talking, through the real `VoiceMachine` in virtual time, with a host
/// that does what `VoiceEngine` does over a playing reply — and nothing it
/// does not. `PolicyReplay` is the capture half; this is the one it said it
/// did not do ("the replay does not replay barge-ins over a playing reply").
///
/// What is emulated, and where it lives in the engine:
/// - the machine is brought to `.speaking` the way a real turn gets there
///   (`.toggle` → a capture → `.transcribed` → `.speechQueued`), with
///   conversation mode and barge-in on, and `.brainFinished` already in, so
///   the reply running out is `.ttsDrained` at the reply's end;
/// - a VAD edge is fed as it is (`handle(.speechStarted/.speechEnded)`),
///   and so is a rise over speech already on (`.speechRose`), which the
///   engine passes on only over a playing reply;
/// - a partial is `reportWords`: while nothing waits on words the baseline
///   follows the transcript; while the machine waits it gets `.wordsGrew`
///   on any new token and `.wordsHeard(n, urgent:)` from `WordReport`;
/// - `.judgeBargeIn` is the engine's pre-pause check: `BargeInJudge.decide`
///   on the words after the baseline, the name, the stop word, the echo
///   check against the sentence at the playhead (`SpeechOut.textAroundPlayhead`
///   / `wordsAtPlayhead`), and the loudness of the last 0.3 s against the
///   session's reference — answered `judgeSeconds` later. No owner
///   enrolment (a fresh install's case; the owner gate is shadow anyway);
/// - timers are virtual.
///
/// **The recogniser.** The engine's is off while Moe talks and is switched on
/// at an onset, reset, with 0.5 s of pre-roll. `Session` says so
/// (`AsrCommand`), and `Moe --turn-bench --corpus` records a reply *live*:
/// it applies those commands to the real pipeline as the audio is fed, so
/// the tape's partials are what the engine's recogniser would have written
/// under the shipped tuning, and a replay of it reproduces that run exactly.
/// A replay under *another* tuning reads the same partials — which that
/// tuning might have switched differently — so a sweep over these tapes is
/// Tier 0, and its winner must be confirmed live.
///
/// A tape whose recogniser ran throughout (`continuousAsr`) is replayed by
/// re-basing the word count on the transcript as it stood `asrLagSeconds`
/// before the onset. That was the first version of this bench, and it was
/// wrong in a way worth remembering: Parakeet's streaming transcript is a
/// sliding window ("…ound three italian places near…"), so over a long
/// reply the word count stops rising and every word after the first few
/// seconds went uncounted.
///
/// The mix is a fixed timeline: the reply's echo carries on in the file
/// after a pause or a duck the machine asked for. So the replay stops caring
/// at the first pause — what it scores (stop latency, a false stop, a missed
/// one) is all decided by then.
public enum BargeReplay {

    public struct Config: Sendable {
        public var tuning: VoiceMachine.Tuning
        /// How long the engine's judge takes (a pipeline peek; no owner score).
        public var judgeSeconds = 0.05
        /// How far behind the audio the streaming transcript runs, for the
        /// re-base at the onset (the recogniser's 160 ms chunk plus decode).
        public var asrLagSeconds = 0.3
        /// The engine's pre-roll on the recogniser at an onset over the reply.
        public var prerollSeconds = 0.5
        /// What the loudness check divides by; nil = no reference (the judge
        /// then takes the words on their own, as the engine does).
        public var referenceRms: Double?
        /// The tape's recogniser ran throughout (eot-bench style) rather than
        /// being switched and reset by the machine as the engine's is (a
        /// live recording by `Moe --turn-bench --corpus`). See `rebase`.
        public var continuousAsr = false
        public init(tuning: VoiceMachine.Tuning = BargeReplay.shippedTuning()) {
            var t = tuning
            t.conversation = true
            t.bargeIn = true
            t.attendSeconds = max(t.attendSeconds, 3600)
            self.tuning = t
        }
    }

    /// Conversation mode as it ships on main: barge-in on, the evidence
    /// endpoint (`Config.turnEvidence` defaults on, English).
    public static func shippedTuning() -> VoiceMachine.Tuning {
        var t = VoiceMachine.Tuning()
        t.conversation = true
        t.bargeIn = true
        t.endpoint = .shipped
        return t
    }

    public struct Judged: Equatable, Sendable {
        public var t: Double
        public var decision: BargeInDecision
    }

    public struct Result: Equatable, Sendable {
        /// When the reply was ducked (`.duckSpeech(true)`).
        public var ducks: [Double] = []
        /// When the reply was paused or stopped — Moe going quiet for somebody.
        public var pauses: [Double] = []
        /// VAD onsets while the reply played.
        public var onsets: [Double] = []
        /// Rises over speech already on (`.speechRose`) while it played.
        public var rises: [Double] = []
        public var judged: [Judged] = []
        /// Every onset that ended in a refusal, with the reason.
        public var refused: [String] = []
        /// Where the replay stopped reading: the first pause, or the reply's end.
        public var until: Double = 0
    }

    /// A tape through the machine: every event in order, then the reply's end.
    public static func run(_ tape: TurnTape, reply: TurnCorpus.Reply, levels: [Double]? = nil,
                           levelHop: Double = 0.02, _ config: Config) -> Result {
        var session = Session(reply: reply, levels: levels, levelHop: levelHop, config)
        for e in tape.events {
            session.handle(e)
            if session.done { break }
        }
        session.advance(to: reply.end)
        var r = session.result
        if r.until == 0 { r.until = min(session.now, reply.end) }
        return r
    }

    /// What `SpeechOut.textAroundPlayhead` (80 characters heard + the piece
    /// playing) and `wordsAtPlayhead` (30 + the piece) would say at `t`.
    public static func playhead(_ reply: TurnCorpus.Reply, at t: Double) -> (around: String, at: String) {
        var heard: [String] = []
        var piece: [String] = []
        let w = reply.words
        var i = 0
        // Pieces are sentences. One counts as heard once it has finished; the
        // first that has not is the one playing (or queued next).
        while i < w.count {
            var j = i
            while j < w.count - 1, w[j].sentenceEnd != true { j += 1 }
            let words = w[i...j].map(\.word)
            if w[j].end <= t + 1e-9 {
                heard += words
            } else {
                piece = words
                break
            }
            i = j + 1
        }
        let heardText = heard.joined(separator: " ")
        let playing = piece.joined(separator: " ")
        func join(_ tail: Int) -> String {
            [String(heardText.suffix(tail)), playing].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return (join(80), join(30))
    }

    /// What the host should do to the recogniser, in order: the engine's
    /// `.resetAsr` and `.asr(on)` with its pre-roll. A live recording applies
    /// these to the real pipeline (`Moe --turn-bench --corpus`); a replay
    /// from a tape reads them only for the word count.
    public enum AsrCommand: Equatable, Sendable {
        case reset
        case on(primeSeconds: Double)
        case off
    }

    /// The emulated host over one reply, driven event by event in time
    /// order — by `run` from a tape, or live while the audio is fed.
    public struct Session: Sendable {
        public let reply: TurnCorpus.Reply
        let levels: [Double]?
        let hop: Double
        let config: Config
        public private(set) var result = Result()
        /// True once the reply was paused (or ran out): nothing after it is scored.
        public private(set) var done = false
        public private(set) var started = false
        /// Recogniser commands not yet taken by the host (`takeAsrCommands`).
        var asrCommands: [AsrCommand] = []

        var machine = VoiceMachine()
        public private(set) var now = 0.0
        var timers: [VoiceMachine.TimerKind: Double] = [:]
        var pendingJudge: (at: Double, taken: Bool)?

        // The engine's view.
        var lastPartial = ""
        var partials: [(t: Double, text: String)] = []
        var wordBaseline = 0
        var wordReport = WordReport()
        var rawWordsReported = 0
        var lastOnset = 0.0
        var vadInSpeech = false

        public init(reply: TurnCorpus.Reply, levels: [Double]? = nil, levelHop: Double = 0.02, _ config: Config) {
            self.reply = reply; self.levels = levels; self.hop = levelHop; self.config = config
        }

        public mutating func takeAsrCommands() -> [AsrCommand] {
            defer { asrCommands.removeAll() }
            return asrCommands
        }

        /// An event from the pipeline or the tape, in time order. Before the
        /// reply starts only the transcript and the VAD's state are kept.
        public mutating func handle(_ e: TurnTape.Event) {
            if !started, e.t < reply.start - 1e-9 {
                switch e.kind {
                case .partial: note(e)
                case .speechStarted: vadInSpeech = true
                case .speechEnded: vadInSpeech = false
                case .endOfUtterance, .speechRose: break
                }
                return
            }
            advance(to: e.t)
            guard !done else { return }
            now = max(now, e.t)
            switch e.kind {
            case .speechStarted:
                vadInSpeech = true
                speechStarted()
            case .speechEnded:
                vadInSpeech = false
                feed(.speechEnded)
            case .speechRose:
                // The engine passes a rise on only over a playing reply,
                // which is the only place this session is.
                result.rises.append(now)
                let waiting = machine.awaitingWords
                feed(.speechRose)
                if !waiting, machine.awaitingWords { lastOnset = now }
            case .partial:
                note(e)
                reportWords(e.text ?? "")
            case .endOfUtterance:
                // Ignored over a reply by the machine; a capture after a
                // pause is past the point this scores.
                break
            }
        }

        /// Run every clock due by `t` (timers, the judge's answer, the reply
        /// running out).
        public mutating func advance(to t: Double) {
            if !started {
                guard t >= reply.start - 1e-9 else { return }
                begin()
            }
            while !done {
                let nextTimer = timers.values.min() ?? .infinity
                let nextJudge = pendingJudge?.at ?? .infinity
                let next = min(nextTimer, nextJudge, reply.end)
                guard next <= t + 1e-9 else { break }
                now = max(now, next)
                if nextJudge <= next, let j = pendingJudge {
                    pendingJudge = nil
                    feed(.bargeInJudged(j.taken))
                } else if nextTimer <= next {
                    let kind = timers.first { $0.value == nextTimer }!.key
                    timers[kind] = nil
                    feed(.timer(kind))
                } else {
                    // The reply ran out: nothing more of it to interrupt.
                    result.until = reply.end
                    done = true
                }
            }
            if !done { now = max(now, t) }
        }

        /// The machine brought to `.speaking` the way a real turn gets there.
        mutating func begin() {
            guard !started else { return }
            started = true
            machine.tuning = config.tuning
            machine.tuning.turnModel = false
            _ = machine.handle(.setWake(false))
            _ = machine.handle(.toggle)
            _ = machine.handle(.speechStarted)
            _ = machine.handle(.speechEnded)
            _ = machine.handle(.endOfUtterance("what's on today"))
            guard case .deciding(_, let turn) = machine.state else { done = true; result.until = reply.start; return }
            _ = machine.handle(.transcribed(turn: turn, "what's on today"))
            now = reply.start
            wordBaseline = TurnPolicy.words(lastPartial).count
            feed(.speechQueued)
            feed(.brainFinished)
            // Already in speech as the reply began: the engine would have
            // seen that onset while Moe thought; here it is the reply's first.
            if vadInSpeech { speechStarted() }
        }

        mutating func note(_ e: TurnTape.Event) {
            let text = e.text ?? ""
            partials.append((e.t, text))
            lastPartial = text
        }

        mutating func speechStarted() {
            result.onsets.append(now)
            lastOnset = now
            feed(.speechStarted)
        }

        /// `VoiceEngine.reportWords`.
        mutating func reportWords(_ text: String) {
            switch machine.state {
            case .off, .standby, .suspended:
                return
            case .thinking, .deciding, .speaking:
                guard machine.awaitingWords else {
                    wordBaseline = TurnPolicy.words(text).count
                    wordReport.reset(); rawWordsReported = 0
                    return
                }
            case .attending, .capturing, .followUp:
                break
            }
            if machine.awaitingWords {
                let raw = max(0, TurnPolicy.words(text).count - wordBaseline)
                if raw > rawWordsReported {
                    rawWordsReported = raw
                    feed(.wordsGrew)
                }
            }
            guard let (n, urgent) = wordReport.update(text: text, baseline: wordBaseline,
                                                      countNods: machine.wordsCountNods) else { return }
            feed(.wordsHeard(n, urgent: urgent))
        }

        /// The recogniser reset at an onset. With a recogniser that followed
        /// the machine (a live recording), what comes next is fresh text: the
        /// count starts at zero, as the engine's does. With one that ran
        /// throughout (`continuousAsr`), the words that count are the ones
        /// from the pre-roll on — see the approximation above.
        mutating func rebase() {
            if config.continuousAsr {
                let asOf = now - config.asrLagSeconds
                let text = partials.last { $0.t <= asOf + 1e-9 }?.text ?? ""
                wordBaseline = TurnPolicy.words(text).count
            } else {
                wordBaseline = 0
                lastPartial = ""
            }
            wordReport.reset(); rawWordsReported = 0
        }

        mutating func judge() {
            let heard = TurnPolicy.words(lastPartial).dropFirst(wordBaseline).joined(separator: " ")
            let (around, atPlayhead) = BargeReplay.playhead(reply, at: now)
            var signals = BargeInJudge.Signals(
                window: "speaking", words: wordReport.count,
                named: NameMatch.namesMoe(heard), urgent: wordReport.urgent,
                ownerScore: nil, ownerSeconds: max(0, now - lastOnset),
                echoSimilarity: around.isEmpty || heard.isEmpty ? nil : EchoFilter.windowSimilarity(heard, around),
                heard: heard, levelRatio: levelRatio())
            signals.urgentEchoesPlayhead = BargeInJudge.echoesThePlayhead(heard: heard, playing: atPlayhead)
            let decision = BargeInJudge.decide(signals)
            result.judged.append(Judged(t: now, decision: decision))
            pendingJudge = (now + config.judgeSeconds, decision.taken)
        }

        /// `VoiceEngine.bargeInLevel`: the last 0.3 s of the capture against
        /// the reference.
        func levelRatio() -> Double? {
            guard let levels, let reference = config.referenceRms, reference > 1e-6 else { return nil }
            let from = max(lastOnset - config.prerollSeconds, now - 0.3)
            guard now - from > 0.1 else { return nil }
            let a = max(0, Int((from / hop).rounded(.down)))
            let b = min(levels.count, Int((now / hop).rounded(.up)))
            guard b > a else { return nil }
            let power = levels[a..<b].reduce(0) { $0 + $1 * $1 } / Double(b - a)
            return power.squareRoot() / reference
        }

        mutating func feed(_ event: VoiceMachine.Event) {
            guard !done else { return }
            let awaiting = machine.awaitingWords
            for a in machine.handle(event) { perform(a, awaitingBefore: awaiting) }
        }

        mutating func perform(_ a: VoiceMachine.Action, awaitingBefore: Bool) {
            switch a {
            case .armTimer(let kind, let seconds): timers[kind] = now + seconds
            case .cancelTimer(let kind): timers[kind] = nil
            case .resetAsr:
                rebase()
                asrCommands.append(.reset)
            case .asr(let on):
                // `VoiceEngine`'s `.asr`: switched on under an onset over the
                // reply, with the moment before it as pre-roll.
                if on {
                    let prime: Double
                    switch machine.state {
                    case .speaking, .thinking: prime = machine.awaitingWords ? config.prerollSeconds : 0
                    default: prime = 0
                    }
                    asrCommands.append(.on(primeSeconds: prime))
                } else {
                    asrCommands.append(.off)
                }
            case .duckSpeech(true): result.ducks.append(now)
            case .judgeBargeIn: judge()
            case .pauseSpeech, .stopSpeaking:
                guard !done else { return }
                result.pauses.append(now)
                result.until = now
                done = true
            case .onsetRejected(let why): result.refused.append(why.rawValue)
            default: break
            }
        }
    }
}
