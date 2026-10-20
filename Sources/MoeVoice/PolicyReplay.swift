import Foundation

/// Tier 0 of the turn-taking harness (research-eval-harness.md §3.2): a
/// `TurnTape` through the real `VoiceMachine`, in virtual time, with a host
/// that does what `VoiceEngine` does with the same events — and nothing the
/// engine does not.
///
/// What is emulated, and where it lives in the engine:
/// - a VAD edge bumps the pause serial; an end also asks the turn model
///   (`handle(.speechEnded)` → `askTurnModel()`);
/// - a partial that grew feeds `.wordsGrew` while capturing (`noteWords`),
///   then `.wordsHeard(n)` when the meaningful count rose (`reportWords`);
/// - an end-of-utterance token becomes the transcript (`handle(.endOfUtterance)`);
/// - `.askTurnModel` / `.askTurnModelOnStall` answer after `inferenceSeconds`
///   from the tape's probe, dropped when stale exactly as the engine drops
///   them (the state moved; a VAD edge for a pause question; new words for a
///   stall question), and turned into a verdict by `TurnVerdictRule`;
/// - timers are virtual.
///
/// What is not: the accurate re-read and the brain. A decision is where the
/// replay stops caring about the turn. With `continueAfterDecision` it then
/// does what the continuation window does — the person talking again after
/// a decision starts a fresh capture from the words they say — so every
/// pause of a long turn is scored, not only the first one a policy cuts.
public struct PolicyReplay {

    public struct Config: Sendable {
        public var tuning: VoiceMachine.Tuning
        /// Which probe set (`TurnTape.key(tail:)`) answers the turn model.
        public var probeSet: String
        /// How long Smart Turn takes to answer (measured by `--turn-bench`).
        public var inferenceSeconds: Double
        public var continueAfterDecision: Bool
        /// Hand the machine the verdict's evidence (`EndpointPolicy`); the
        /// policy itself is `tuning.endpoint`.
        public var withEvidence = true
        /// The on-device model's answers, by `TurnSemantics.key(text)`, as
        /// measured (`Moe --turn-semantics`): its reading and how long it
        /// took. Asked only where the rules have no opinion; an answer
        /// slower than `modelBudget` is no answer, and the verdict waits
        /// for the budget instead — what the engine does. Nil: no model.
        public var model: [String: ModelAnswer]?
        public var modelBudget: Double = 0.3
        public init(tuning: VoiceMachine.Tuning = VoiceMachine.Tuning(),
                    probeSet: String = TurnTape.key(tail: TurnAudio.pauseTheModelWasTrainedOn),
                    inferenceSeconds: Double = 0.04,
                    continueAfterDecision: Bool = true) {
            var t = tuning
            // A replay is one long capture: the session clocks that close an
            // idle window have nothing to measure here.
            t.attendSeconds = max(t.attendSeconds, 3600)
            self.tuning = t
            self.probeSet = probeSet
            self.inferenceSeconds = inferenceSeconds
            self.continueAfterDecision = continueAfterDecision
        }
    }

    /// One measured answer of the on-device model.
    public struct ModelAnswer: Codable, Equatable, Sendable {
        public var reading: TurnSemantics.Reading?
        public var ms: Double
        public init(reading: TurnSemantics.Reading?, ms: Double) { self.reading = reading; self.ms = ms }
    }

    /// One turn the machine took.
    public struct Decision: Equatable, Sendable {
        public let t: Double
        public let reason: VoiceMachine.EndReason
        /// How long the reply is held back after the decision
        /// (`VoiceMachine.Action.holdReply`), 0 when nothing holds it.
        public let replyHold: Double
        /// The turn model's last answer in this capture, if it was asked.
        public let p: Double?
        /// The words the machine was deciding on.
        public let text: String
    }

    public struct Result: Sendable {
        public var decisions: [Decision] = []
        /// When the machine noticed the person again after each decision:
        /// the first VAD onset, and the first new word.
        public var onsetsAfter: [Double] = []
        /// Every turn-model answer that reached the machine: (time, p, complete).
        public var verdicts: [(t: Double, p: Double, complete: Bool)] = []
        /// Captures that ended as "sound, no words" (`EndReason.noWords`),
        /// which are not turns: nothing is read and nothing is sent.
        public var wordlessEnds: [Double] = []
        /// The words at every question to the turn model — what the
        /// on-device model would be shown (`Moe --turn-semantics` reads it).
        public var askedTexts: [String] = []
        /// Questions where the model was wanted (the rules had no opinion)
        /// and its answer was missing from the table.
        public var modelMissing = 0
    }

    public static func run(_ tape: TurnTape, _ config: Config) -> Result {
        var host = Host(tape: tape, config: config)
        host.run()
        return host.result
    }

    // MARK: - The emulated host

    private struct Host {
        let tape: TurnTape
        let config: Config
        var result = Result()

        var machine = VoiceMachine()
        var now = 0.0
        var timers: [VoiceMachine.TimerKind: Double] = [:]
        struct Pending { let at: Double; let p: Double; let onStall: Bool
                         let state: VoiceMachine.State; let serial: Int; let words: Int
                         var model: TurnSemantics.Reading? = nil }
        var pending: [Pending] = []

        // The engine's own view.
        var lastText = ""
        var lastGrewAt = 0.0
        var wordBaseline = 0
        var wordsReported = 0
        var pauseSerial = 0
        var vadInSpeech = false
        var lastP: Double?
        var holdAfterDecision = 0.0
        var decidedReason: VoiceMachine.EndReason?

        /// Decided, and waiting for the person to go on.
        var awaitingResume = false
        var onsetSinceDecision = false

        init(tape: TurnTape, config: Config) {
            self.tape = tape
            self.config = config
        }

        mutating func run() {
            startCapture()
            var i = 0
            while true {
                let nextEvent = i < tape.events.count ? tape.events[i].t : Double.infinity
                let nextTimer = timers.values.min() ?? .infinity
                let nextVerdict = pending.map(\.at).min() ?? .infinity
                let next = min(nextEvent, nextTimer, nextVerdict)
                guard next.isFinite, next <= tape.duration + 1e-9 else { break }
                now = next
                if nextEvent <= next {
                    event(tape.events[i]); i += 1
                } else if nextVerdict <= next {
                    let idx = pending.firstIndex { $0.at == nextVerdict }!
                    verdict(pending.remove(at: idx))
                } else {
                    let kind = timers.first { $0.value == nextTimer }!.key
                    timers[kind] = nil
                    feed(.timer(kind))
                }
            }
        }

        mutating func startCapture() {
            machine = VoiceMachine()
            machine.tuning = config.tuning
            machine.tuning.turnModel = tape.probes[config.probeSet]?.isEmpty == false
            timers.removeAll()
            pending.removeAll()
            lastP = nil
            feed(.toggle)                 // the island button: attending(hotkey)
        }

        mutating func event(_ e: TurnTape.Event) {
            switch e.kind {
            case .speechStarted:
                vadInSpeech = true
                pauseSerial &+= 1
                if awaitingResume { onsetSinceDecision = true; return }
                feed(.speechStarted)
            case .speechEnded:
                vadInSpeech = false
                pauseSerial &+= 1
                if awaitingResume { return }
                feed(.speechEnded)
                ask(onStall: false)
            case .partial:
                let text = e.text ?? ""
                if awaitingResume {
                    // The continuation window: any new token after an onset
                    // is the person going on (review H3).
                    let raw = TurnPolicy.words(text).count - wordBaseline
                    if raw > 0, onsetSinceDecision || vadInSpeech {
                        result.onsetsAfter.append(now)
                        resume(with: text)
                    }
                    lastText = text
                    return
                }
                partial(text)
            case .speechRose:
                // Means something only over a playing reply (`BargeReplay`);
                // the engine does not pass it on while Moe listens.
                break
            case .endOfUtterance:
                if awaitingResume { return }
                let text = e.text ?? ""
                lastText = text.isEmpty ? lastText : text
                feed(.endOfUtterance(text))
            }
        }

        mutating func partial(_ text: String) {
            if text.count > lastText.count { lastGrewAt = now }
            if case .capturing(let s) = machine.state, s != .hold, text.count > lastText.count {
                lastText = text
                feed(.wordsGrew)
            }
            lastText = text
            switch machine.state {
            case .attending, .capturing, .followUp: break
            default: return
            }
            let n = TurnPolicy.meaningfulWords(in: text, after: wordBaseline,
                                               countNods: machine.wordsCountNods)
            guard n > wordsReported else { return }
            wordsReported = n
            feed(.wordsHeard(n))
        }

        /// The person went on after a decision: a fresh capture, as the
        /// continuation window makes one (`enterCapturing(wordsHeard: true)`).
        mutating func resume(with text: String) {
            awaitingResume = false
            onsetSinceDecision = false
            startCapture()
            feed(.speechStarted)
            partial(text)
        }

        mutating func ask(onStall: Bool) {
            guard case .capturing(let s) = machine.state, s != .hold else { return }
            guard let p = tape.probe(at: now, set: config.probeSet) else { return }
            result.askedTexts.append(lastText)
            var wait = config.inferenceSeconds
            var model: TurnSemantics.Reading?
            if let table = config.model, TurnSemantics.read(lastText) == .unknown,
               !TurnPolicy.words(lastText).isEmpty {
                // Asked beside Smart Turn; the verdict waits for both, and
                // for the model no longer than its budget.
                if let answer = table[TurnSemantics.key(lastText)] {
                    if answer.ms / 1000 <= config.modelBudget {
                        model = answer.reading
                        wait = max(wait, answer.ms / 1000)
                    } else {
                        wait = max(wait, config.modelBudget)
                    }
                } else {
                    result.modelMissing += 1
                }
            }
            pending.append(Pending(at: now + wait, p: p, onStall: onStall,
                                   state: machine.state, serial: pauseSerial, words: wordsReported,
                                   model: model))
        }

        mutating func verdict(_ v: Pending) {
            lastP = v.p
            guard machine.state == v.state else { return }
            if v.onStall {
                guard wordsReported == v.words else { return }
            } else {
                guard pauseSerial == v.serial else { return }
            }
            let rule = TurnVerdictRule.verdict(p: v.p, text: lastText)
            result.verdicts.append((now, v.p, rule.complete))
            // The pause since the words last grew — the engine measures from
            // the later of that and the last confident VAD chunk, which is
            // never earlier, so the replay's pause is the longer: it plans
            // the shorter waits, and errs toward cutting in.
            let evidence = config.withEvidence
                ? EndpointPolicy.Evidence(p: v.p, text: lastText, pauseSoFar: now - lastGrewAt, model: v.model) : nil
            feed(.turnVerdict(complete: rule.complete, stillMidClause: rule.stillMidClause, evidence: evidence))
        }

        mutating func feed(_ event: VoiceMachine.Event) {
            let actions = machine.handle(event)
            for a in actions { perform(a) }
            // Ended as "sound, no words" and nothing was sent to be read: the
            // room, not a turn. Judged by what the machine did, not by the
            // reason it gave — a machine that read the noise is a machine
            // that took a turn.
            if actions.contains(.decided(.noWords)),
               !actions.contains(where: { if case .transcribe = $0 { return true }; return false }) {
                result.wordlessEnds.append(now)
                decidedReason = nil
            }
        }

        mutating func perform(_ a: VoiceMachine.Action) {
            switch a {
            case .armTimer(let kind, let seconds):
                timers[kind] = now + seconds
            case .cancelTimer(let kind):
                timers[kind] = nil
            case .askTurnModel:
                ask(onStall: false)
            case .askTurnModelOnStall:
                ask(onStall: true)
            case .resetAsr:
                lastText = ""
                wordBaseline = 0
                wordsReported = 0
            case .decided(let reason):
                decidedReason = reason
                holdAfterDecision = 0
            case .holdReply(let seconds):
                holdAfterDecision = seconds
            case .transcribe:
                guard let reason = decidedReason else { return }
                decidedReason = nil
                result.decisions.append(Decision(t: now, reason: reason, replyHold: holdAfterDecision,
                                                 p: lastP, text: lastText))
                // The machine now waits on a read that never comes: the turn
                // is over as far as the policy is concerned.
                timers.removeAll()
                pending.removeAll()
                if config.continueAfterDecision {
                    awaitingResume = true
                    onsetSinceDecision = false
                    wordBaseline = TurnPolicy.words(lastText).count
                    wordsReported = 0
                } else {
                    awaitingResume = true
                    wordBaseline = Int.max / 2
                }
            default:
                break
            }
        }
    }
}
