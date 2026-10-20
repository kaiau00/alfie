import Foundation

/// How long to wait after the turn model has been asked, from the evidence
/// rather than from a yes/no (research-endpointing.md §4.2, PLAN.md Step 1.1).
///
/// Until 2026-09-23 a verdict chose one of three fixed regimes — decide now
/// (p > 0.5), 0.45 s (p > 0.5 but the words dangle), 3 or 6 s (p ≤ 0.5) —
/// and the reply was then held 0.8 s. Two binary votes, and pause length,
/// score margin and turn length never entered it. LiveKit's eot-bench puts
/// that shape in the corner where Smart Turn cuts 35 % of the pauses people
/// go on after; every system that reaches 5 % does it with a *wait*, not a
/// better threshold (Smart Turn's own 5 % point: threshold 0.09, 0.7 s).
///
/// So a verdict now yields two numbers:
/// - **decideIn** — seconds until the turn is decided if nothing more is
///   heard. Deciding starts the brain.
/// - **hold** — seconds the reply is then held back (`.holdReply`). The
///   person going on inside it joins the turn (the continuation window) and
///   nobody hears the half-answer. The brain's first audio lands seconds
///   after the decision anyway, so a hold is nearly free and a wait before
///   deciding is not: the policy prefers to decide early and hold.
///
/// Every number is fitted on eot-bench (`Moe --turn-replay`), not chosen.
public struct EndpointPolicy: Equatable, Sendable {

    /// What the host knew when it asked.
    public struct Evidence: Equatable, Sendable {
        /// Smart Turn's probability that the turn is complete.
        public var p: Double
        /// The words so far.
        public var text: String
        /// Seconds from the last word to the answer.
        public var pauseSoFar: Double
        /// What the on-device model said about the words, when it was asked
        /// and answered inside its deadline (`TurnSemanticJudge`); nil when
        /// it was not asked, is not there, or was late — the rules alone.
        public var model: TurnSemantics.Reading?
        public init(p: Double, text: String, pauseSoFar: Double, model: TurnSemantics.Reading? = nil) {
            self.p = p; self.text = text; self.pauseSoFar = pauseSoFar; self.model = model
        }
        public var words: Int { TurnPolicy.words(text).count }
        /// The words end on something with more coming ("and", "um", "to").
        public var dangling: Bool { TurnPolicy.completeness(of: text) == .incomplete }
        /// What the words mean for the pause: the rules first, the model
        /// only where the rules have no opinion (`TurnSemantics.combine`).
        public var reading: (TurnSemantics.Reading, TurnSemantics.Source) {
            TurnSemantics.combine(rules: TurnSemantics.read(text), model: model)
        }
    }

    public struct Plan: Equatable, Sendable {
        public let decideIn: Double
        public let hold: Double
        /// Why the turn will be decided, when it is — for the trace.
        public let reason: VoiceMachine.EndReason
    }

    // MARK: Parameters (fitted — see voice-turns-impl.md, Slice C)

    /// At or above this, decide now.
    public var decideAt: Double
    /// Between `unsureAt` and `decideAt`: probably finished — decide after
    /// `unsureWait` of silence. Below `unsureAt`, the old ceilings.
    public var unsureAt: Double
    public var unsureWait: Double
    /// A confident "finished" on words that dangle: wait this long first.
    public var danglerWait: Double
    /// Below `unsureAt`: the ceiling; when the words dangle too, the longer one.
    public var midThoughtWait: Double
    public var midClauseWait: Double
    /// The reply's hold: `holdBase + holdPerDoubt·(1−p)` (less `shortLess`
    /// for a short answer).
    public var holdBase: Double
    public var holdPerDoubt: Double
    /// Short answers ("yes", "Friday") are the ones people finish in a word:
    /// this much less hold at or under `shortWords`.
    public var shortWords: Int
    public var shortLess: Double
    /// The waits are silence since the last word — eot-bench's own shape —
    /// so the pause already heard when the answer came, and the wait before
    /// deciding, count towards them. False is the old machine: waits from the
    /// verdict, and a hold only after a plain "finished" (`.turnModel`).
    public var waitsCountThePause: Bool
    /// The longest the reply may be held after a decision; nil, no cap.
    public var maxHold: Double?

    // MARK: The words' meaning (`TurnSemantics`) — all off in `before`/`fitted`

    /// Words that cannot stand as a turn (`Reading.unfinished`) count as
    /// dangling: a confident "finished" on them waits `danglerWait`, a weak
    /// one the mid-clause ceiling. False: only the old dangler list does.
    public var semanticDangles: Bool
    /// The same for words the model (not the rules) called unfinished.
    public var modelDangles: Bool
    /// Seconds off the hold for words that are a whole turn by themselves
    /// ("yes", "not yet", "go ahead") by the rules, and for words the model
    /// called finished.
    public var finishedLess: Double
    public var modelFinishedLess: Double
    /// Seconds on the hold for any words that are not a whole turn by
    /// themselves: a clause that could end here or go on (`Reading.unknown`
    /// — the "complete clause, more coming" pause is one of these, and so is
    /// every plain request) and words that plainly cannot end there
    /// (`.unfinished`, which must never wait *less* than an open clause).
    public var unknownMore: Double
    /// The owner's own pauses (`OwnerPauses`): the hold never releases the
    /// reply sooner than this much quiet. Nil — the default — until enough
    /// of their turns have been logged and it is switched on.
    public var ownerQuietFloor: Double?
    /// Whether a score under `TurnVerdictRule.stronglyUnfinished` on words
    /// that do not dangle waits the mid-clause ceiling, as the machine did
    /// before policies (`before` keeps it, so it stays that machine). The
    /// shipped policy does not: see `plan`.
    public var lowScoreIsMidClause = true

    public init(decideAt: Double = 0.5, unsureAt: Double = 0.5, unsureWait: Double = 3.0,
                danglerWait: Double = 0.45, midThoughtWait: Double = 3.0, midClauseWait: Double = 6.0,
                holdBase: Double = 0.8, holdPerDoubt: Double = 0, shortWords: Int = 0, shortLess: Double = 0,
                waitsCountThePause: Bool = false, maxHold: Double? = nil,
                semanticDangles: Bool = false, modelDangles: Bool = false, finishedLess: Double = 0, modelFinishedLess: Double = 0,
                unknownMore: Double = 0, ownerQuietFloor: Double? = nil) {
        self.decideAt = decideAt; self.unsureAt = unsureAt; self.unsureWait = unsureWait
        self.danglerWait = danglerWait; self.midThoughtWait = midThoughtWait; self.midClauseWait = midClauseWait
        self.holdBase = holdBase; self.holdPerDoubt = holdPerDoubt
        self.shortWords = shortWords; self.shortLess = shortLess
        self.waitsCountThePause = waitsCountThePause
        self.maxHold = maxHold
        self.semanticDangles = semanticDangles; self.modelDangles = modelDangles
        self.finishedLess = finishedLess
        self.modelFinishedLess = modelFinishedLess; self.unknownMore = unknownMore
        self.ownerQuietFloor = ownerQuietFloor
    }

    /// What shipped until 2026-09-23, in this shape: the same decisions the
    /// machine made from `(complete, stillMidClause)`, and the 0.8 s floor.
    public static let before = EndpointPolicy()

    /// Fitted on LiveKit's eot-bench (English, 400 real turns) split **by
    /// conversation** into fit / validation / test thirds (no speaker on two
    /// sides; review H4): the grid was run on the fit third, the setting
    /// chosen on the validation third as the fastest under 5 % reply
    /// cut-offs on both, and the test third scored once
    /// (voice-turns-impl.md, Fix round). Two constraints were fixed before
    /// fitting, not fitted: the brain may run at most 0.8 s ahead of the
    /// reply — main's own floor — because a started turn can act before the
    /// reply is heard (review M1); and the mid-clause ceiling stays 6 s from
    /// the verdict, set from a measured cut-off that no pause in eot-bench is
    /// long enough to test (review H5). In words: a "finished" of 0.2 or more
    /// on words that do not dangle is decided so that the reply is released
    /// at 1.4 + 1.0·(1−p) s of quiet, the brain starting at most 0.8 s
    /// before; below 0.2, 3 s of quiet; dangling, 6 s from the verdict.
    public static let fitted: EndpointPolicy = {
        var p = EndpointPolicy(decideAt: 0.5, unsureAt: 0.2, unsureWait: 0,
                               danglerWait: 0.45, midThoughtWait: 3.0, midClauseWait: 6.0,
                               holdBase: 1.4, holdPerDoubt: 1.0, waitsCountThePause: true,
                               maxHold: 0.8)
        // "Below 0.2, 3 s of quiet", as written above — which the code did
        // not do until 2026-09-29.
        p.lowScoreIsMidClause = false
        return p
    }()

    /// `fitted`, with the words read for meaning (`TurnSemantics`), chosen on
    /// the turn bench's **dev** voices and eot-bench's validation third
    /// (turn-semantics.md). What was measured, and what it means:
    ///
    /// - The meaning of the words does **not** separate "a complete clause,
    ///   more coming" from a finished request — both read as an open clause
    ///   (`Reading.unknown`), to the rules and, in principle, to anyone who
    ///   has not heard the rest. Fusing the rules' reading into Smart Turn's
    ///   score left eot-bench's frontier where it was (test third 40.3 / 12.6 %
    ///   cut-offs at 0.3 / 0.6 s, fused 40.8 / 12.6 %), and making unfinished
    ///   words dangle changed no turn on either bench.
    /// - What the reading *can* do is keep the open clause's longer wait off
    ///   the words that are a whole turn by themselves ("yes", "not yet", "go
    ///   ahead"): an open clause waits `unknownMore` longer before the reply
    ///   is released, a whole answer `finishedLess` less.
    /// - 0.3 s was chosen as the most on dev that adds no more than 0.3 s to
    ///   the median reply (dev: cut-offs 26.1 → 21.8 %, p50 1452 → 1715 ms);
    ///   the next 0.6 s buys another 8 points at +0.6 s. That trade is the
    ///   owner's to move (`ep.unknownMore` on the bench).
    /// The mid-clause ceiling (6 s from the verdict), the brain's 0.8 s lead
    /// and the continuation window are `fitted`'s, unchanged.
    public static let semantic: EndpointPolicy = {
        var p = fitted
        p.semanticDangles = true
        p.unknownMore = 0.3
        p.finishedLess = 0.3
        return p
    }()

    /// What the engine runs (`Config.turnEvidence`).
    public static let shipped = semantic

    public func plan(_ e: Evidence, onStall: Bool) -> Plan {
        let p = min(1, max(0, e.p))
        let heard = waitsCountThePause ? max(0, e.pauseSoFar) : 0
        var target = holdBase + holdPerDoubt * (1 - p)
        if shortWords > 0, e.words <= shortWords { target -= shortLess }
        let (reading, source) = e.reading
        switch reading {
        case .finished: target -= source == .model ? modelFinishedLess : finishedLess
        case .unknown, .unfinished: target += unknownMore
        }
        if let floor = ownerQuietFloor { target = max(target, floor) }
        let dangling = e.dangling
            || (reading == .unfinished && (source == .rules ? semanticDangles : modelDangles))
        /// - Parameter fromVerdict: the wait runs from the answer, not from
        ///   the last word — the mid-clause ceiling, which was set from a
        ///   measured cut-off (review H5) and which no bench here can see past.
        func plan(_ wait: Double, _ reason: VoiceMachine.EndReason, fromVerdict: Bool = false) -> Plan {
            var decideIn = max(0, wait - (fromVerdict ? 0 : heard))
            var hold: Double
            if waitsCountThePause {
                hold = max(0, target - heard - decideIn)
                // A decision starts the brain, and the brain can act — run a
                // tool — before the held reply is ever heard (review M1). So
                // the time between the two is capped: past it, the decision
                // itself waits instead.
                if let cap = maxHold, hold > cap {
                    decideIn += hold - cap
                    hold = cap
                }
            } else {
                hold = reason == .turnModel ? max(0, target) : 0
            }
            return Plan(decideIn: decideIn, hold: hold, reason: reason)
        }
        let finished: VoiceMachine.EndReason = onStall ? .stall : .turnModel
        // A confident "finished" — over the model's own line, or over a lower
        // one this policy was fitted to.
        let confident = p >= decideAt && (p > TurnVerdictRule.threshold || decideAt < TurnVerdictRule.threshold)
        if confident {
            // Weak and dangling: the words overrule it (`TurnVerdictRule`).
            if dangling, p < TurnVerdictRule.weakFinished { return plan(midClauseWait, .ceiling, fromVerdict: true) }
            if dangling { return plan(danglerWait, .verdictHold) }
            return plan(0, finished)
        }
        if p >= unsureAt {
            if dangling { return plan(midClauseWait, .ceiling, fromVerdict: true) }
            // Probably finished: the turn model's decision, after its wait —
            // labelled as one, not as a ceiling (review M8). Where the fit's
            // line is the model's own (0.5), this is the old "mid-thought".
            let reason = unsureAt < TurnVerdictRule.threshold ? finished : .ceiling
            return plan(unsureWait, reason)
        }
        // Only words that trail off earn the 6 s mid-clause ceiling. A low
        // score on words that do not dangle used to earn it too — every
        // p < 0.2 is also under `stronglyUnfinished`, so the 3 s branch below
        // could never run — and "…how many different places are we doing
        // this" (p=0.16) held the microphone 6 s after a finished question.
        // 12 of 264 decided turns from 09-23 to 09-29 waited 6.4–8.6 s this
        // way, over silence (`audit-mic-open.md`). A pause that really was
        // mid-thought and runs past 3 s is caught by the continuation window.
        let midClause = dangling || (lowScoreIsMidClause && p < TurnVerdictRule.stronglyUnfinished)
        return midClause ? plan(midClauseWait, .ceiling, fromVerdict: true) : plan(midThoughtWait, .ceiling)
    }
}
