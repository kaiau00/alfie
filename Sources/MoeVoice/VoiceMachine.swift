import Foundation

/// The one state machine behind everything Moe does with a microphone and a
/// voice. VOICE-PLAN.md §2.1.
///
/// Pure: no clocks, no audio, no timers. Time arrives as events (`.timer`),
/// leaves as actions (`.armTimer`). The host — `VoiceEngine` in the app —
/// runs the audio graph, the recognisers and the synthesiser, feeds what
/// they report in here, and does exactly what the returned actions say.
/// Nothing else decides anything.
///
/// Three ways in, one machine: the held key, the hotkey, and the wake word
/// are inputs, not code paths. What differs between them is only where a
/// turn goes when it ends (`Source`), which is one function (`afterReply`).
public struct VoiceMachine: Equatable, Sendable {

    // MARK: - Vocabulary

    /// How the current session was opened. Decides whether a follow-up
    /// window opens after a reply, and whether an empty turn means "waiting
    /// for the request" or "nothing was said".
    public enum Source: Equatable, Sendable {
        /// The talk key held (right ⌥ unless Settings says otherwise). The key decides when the turn ends.
        case hold
        /// The hotkey or the island button. The endpointer decides.
        case hotkey
        /// "Hey Moe". The endpointer decides.
        case wake
        /// A turn inside the follow-up window: no name, no key.
        case followUp
        /// Something spoken outside a turn — a nudge, a preview. Goes back to
        /// wherever the machine was resting.
        case aside
    }

    public enum State: Equatable, Sendable {
        /// Wake word off and nothing open. The audio graph may come down.
        case off
        /// Wake word on: the microphone is open for the wake spotter only.
        case standby
        /// A session is open and Moe is waiting for you to start speaking.
        case attending(Source)
        /// You are speaking (or the key is down); audio is being kept.
        case capturing(Source)
        /// You stopped; the accurate model is reading the turn back.
        case deciding(Source, turn: Int)
        /// The brain has the text and owes a reply. Also where a reply parks
        /// while its audio has run out but more text is still coming.
        case thinking(Source)
        /// Audio is queued or playing.
        case speaking(Source)
        /// Moe has finished; you can just talk. Closes on silence.
        case followUp
        /// Something else owns the microphone (a dictation, a meeting).
        case suspended
    }

    public enum TimerKind: Equatable, Sendable {
        case attend, followUp
        /// Part-way through the window: offer to close rather than let it
        /// time out in silence.
        case offerToClose
        /// The VAD saw silence but the endpointer said nothing: a fallback
        /// so a cough or the TV can never leave the mic open for good.
        case silence
        /// A turn cannot run longer than this.
        case turnCap
        /// The audio model said "finished" but the words end mid-phrase:
        /// the door is held a moment for the person to go on before the
        /// verdict is taken.
        case verdictHold
        /// The word window. The VAD heard something speech-shaped while a
        /// reply was on its way (Moe thinking, the first half being read
        /// back, or the reply playing — ducked), and the recogniser has
        /// this long to produce words. If it fires first, the sound was the
        /// room: the reply comes back up and nothing else happens.
        case bargeInHold
        /// Words have stopped arriving for `wordStallSeconds` while a turn
        /// is being captured, whatever the VAD says. Steady noise — a fan,
        /// music, a TV — keeps the VAD "in speech" for good, so no pause is
        /// ever reported and the turn model is never asked; this asks it.
        case wordStall
        /// A capture has produced no words at all for `noWordsSeconds`: it
        /// was the room. It ends without a read and without a turn.
        case noWords
        /// Interruptions are off (`Tuning.bargeIn`), and this long has
        /// passed since the turn was decided: a voice that starts from now
        /// is not the person finishing their sentence, and nothing it says
        /// may withdraw or restart the reply (`continuationGraceSeconds`).
        case continuationGrace
    }

    /// Why a turn ended — told to the host (`.decided`) before it is read,
    /// so the trace records the path rather than guessing it from events.
    public enum OnsetRejection: String, Equatable, Sendable {
        case noWords = "rejected-no-words"
        case notForMoe = "rejected-not-for-moe"
        /// Overtaken before anything was decided: a key, the name, a
        /// dictation, the window closing, the reply running out.
        case superseded = "superseded"
    }

    /// How an onset took the floor (`.onsetTaken`).
    public enum OnsetTake: String, Equatable, Sendable {
        /// Words over a playing reply, and the host's judge said "for Moe".
        case judged = "taken-judged"
        /// Words while Moe was thinking: the question in flight is withdrawn.
        case overThinking = "taken-over-thinking"
        /// The person going on with their own turn before any of the reply
        /// was heard (the continuation window).
        case continuation = "taken-continuation"
        /// Words that landed after the reply ran out, into the window.
        case intoWindow = "taken-into-window"
    }

    public enum EndReason: String, Equatable, Sendable {
        /// The key was released or pressed again.
        case key
        /// The endpointer's token, with no turn model loaded.
        case eou
        /// The turn model said "finished" at a pause the VAD or endpointer saw.
        case turnModel = "turn-model"
        /// The words stopped arriving and the turn was ended on that —
        /// the turn model's verdict, or the fallback under it.
        case stall
        /// The VAD reported silence and nothing else spoke up.
        case vad
        /// A "finished, but the words dangle" verdict, held and then taken.
        case verdictHold = "verdict-hold"
        /// "Not finished" was the verdict, and the ceiling on waiting for
        /// the rest of it ran out.
        case ceiling
        /// `turnCapSeconds`.
        case cap
        /// Woken, and nothing followed.
        case noSpeech = "no-speech"
        /// Sound with no words at all: ended without a read.
        case noWords = "no-words"
        /// Words, but clearly not the owner's voice (`OwnerGate`): the TV,
        /// somebody else in the room. Ended without a read, like `noWords`.
        case notOwner = "not-owner"
    }
    public enum Cue: Equatable, Sendable { case wake, close }

    /// What switched mute on or off. Every change carries one.
    public enum MuteCause: String, Equatable, Sendable {
        /// The mute button — the island's pill or the chat's.
        case button
        /// The hotkey: a hands-free "listen to me now". There is no key held
        /// to end a talk-through, so it unmutes (documented, deliberate).
        case hotkey
        /// The conversation is over (closed, stopped, or the muted window's
        /// safety cap). Left on, the wake word would be dead in standby.
        case conversationEnded = "conversation-ended"
        /// Nothing recorded a cause: a bug, logged as one.
        case unrecorded

        /// The log line for a change of mute, with its cause — every one of
        /// them. On 2026-09-24 at 16:57:37 the log said a bare "voice:
        /// unmuted", and which of four routes it was had to be worked out
        /// from what did *not* happen next. `surface` is where a button
        /// press came from ("island", "chat"), when the host knows.
        public func logLine(muted on: Bool, surface: String? = nil) -> String {
            let head = on ? "voice: muted" : "voice: unmuted"
            let why: String
            switch self {
            case .button:
                let at = surface.map { " on the \($0)" } ?? ""
                why = on ? "the mute button\(at); the room is not listened to until it is pressed again"
                         : "the mute button\(at); listening again"
            case .hotkey: why = "the hotkey; listening again"
            case .conversationEnded: why = "the conversation ended; a mute lasts one conversation"
            case .unrecorded: why = "NO CAUSE RECORDED (a route changed mute without saying why: a bug)"
            }
            return "\(head) — \(why)"
        }
    }

    public enum Event: Equatable, Sendable {
        /// The wake-word setting. Standby is allowed only while this is on.
        case setWake(Bool)
        /// The person muted themselves: nothing the microphone hears counts
        /// — not words over the work, not over the reply, not the name.
        ///
        /// **Sticky** (the owner, 2026-09-24: muted six times in half an
        /// hour, and each time the end of the reply switched it off). It
        /// lasts across answers, turns and follow-up windows until they
        /// press it again, press the hotkey, or the conversation ends. The
        /// talk key *talks through* it — heard while held, muted again the
        /// moment it comes up — and never switches it off. A muted window
        /// does not time out under them: it waits, up to
        /// `Tuning.mutedWindowSeconds`. What Moe is doing or saying goes on
        /// untouched.
        case setMuted(Bool)
        /// Pause (true) or resume (false) the reply from a button — the
        /// chat's ⏸, the island's. The key's tap does the same by way of
        /// `.holdDown`/`.holdCancelled`; a button knows it is a pause from
        /// the start, so the sound is held at the sample rather than stopped,
        /// and resuming carries on mid-word.
        case pauseReply(Bool)
        /// A trained wake head is available (Phase 4): standby runs it
        /// on the audio instead of reading a transcript.
        case setWakeHead(Bool)
        /// The turn model finished loading (or failed to).
        case setTurnModel(Bool)
        case holdDown
        case holdUp
        /// The key came up too soon to have been a question (a tap).
        case holdCancelled
        /// The key was never a question at all: another key went down while
        /// it was held, so it is a shortcut (fn+←, right ⌘+Tab). Unlike a
        /// tap this is not the pause button — the reply the press stopped
        /// goes on as if the key had never moved, and a reply a tap had
        /// already paused stays paused.
        case holdAborted
        /// The hotkey or the island button: one key, the obvious thing.
        case toggle
        /// Double tap, ×, Esc: everything stops, now.
        case stopAll
        /// "Thanks Moe": the window closes now, quietly (Phase 5).
        case dismiss
        /// The wake spotter matched.
        case woke
        /// VAD: someone started / stopped speaking.
        case speechStarted
        case speechEnded
        /// The VAD was already in speech and a louder voice joined it
        /// (`NoiseFloorGate.Edge.rose`). Over a playing reply that is an
        /// onset like any other — waited on for words, judged — because
        /// the VAD has been calling Moe's own echo speech since the reply
        /// began and will make no edge of its own for the person. Nowhere
        /// else does it mean anything.
        case speechRose
        /// The streaming recogniser has more words than it had. While an
        /// "unfinished sentence" clock is running, that clock restarts:
        /// it measures silence in the words, and words are still coming.
        case wordsGrew
        /// The streaming recogniser has written this many words that could be
        /// somebody taking the floor (`TurnPolicy.meaningfulWords`) since the
        /// last VAD onset the machine is waiting on, or since the turn began.
        /// Sent each time the count rises. This — not the VAD — is what lets
        /// a voice interrupt a reply or go on with a turn that was sent.
        /// `urgent`: among them is a word that stops a speaker by itself
        /// ("stop", "wait", "no", the name — `TurnPolicy.stopWords`).
        case wordsHeard(Int, urgent: Bool = false)
        /// The voice in the capture is clearly not the owner's (`OwnerGate`,
        /// judged by the host on the speech so far): end it without a read.
        case notTheOwner
        /// The sound the VAD flagged ended too soon to have been words — a
        /// breath, a chair — and no request has been heard yet. Undo what
        /// its `.speechStarted` did: the capture is waiting for the request
        /// again, on the no-speech clock.
        case speechWasNoise
        /// The streaming recogniser called the utterance finished, with its
        /// own (rough) text.
        case endOfUtterance(String)
        /// The turn model looked at the pause: finished, or mid-thought.
        /// `stillMidClause` is the transcript's opinion, alongside the audio
        /// model's: the words end on something with more coming ("and", "um",
        /// "because"). When both say unfinished, the wait before giving up on
        /// them is longer — see `midClauseSilenceSeconds`.
        /// `evidence`: what the host knew when it asked — with
        /// `Tuning.endpoint` set, the wait is planned from it
        /// (`EndpointPolicy`) rather than from the two booleans.
        case turnVerdict(complete: Bool, stillMidClause: Bool = false, evidence: EndpointPolicy.Evidence? = nil)
        /// The host's answer to `.judgeBargeIn`: true stops the reply,
        /// false brings it back up as though nothing had happened.
        case bargeInJudged(Bool)
        /// The accurate model read the turn back. Empty when nothing usable
        /// was said. `turn` matches the `.transcribe` action it answers, so
        /// a result for a turn that was abandoned meanwhile is dropped.
        case transcribed(turn: Int, String)
        /// The host has audio to play for this reply (or an aside).
        case speechQueued
        /// The last scheduled buffer has been heard. Not "rendered": heard.
        case ttsDrained
        /// Fed just before `.ttsDrained`: whether what was said ended with a
        /// question, so the window after it waits longer.
        case replyEndedWithQuestion(Bool)
        /// The brain's reply is over, however it ended.
        case brainFinished
        /// The host sent the brain back into the reply it had just finished
        /// — the stall guard's one continuation (docs/FIXABLE-FAILURES.md
        /// bug 9). The reply is owed again as a spoken turn's is: pending
        /// and live, so the key and a voice over it interrupt it, and it is
        /// never spoken as an aside. For a turn the machine never carried
        /// (typed, or read aloud from rest) it changes nothing.
        case replyContinues
        /// A dictation or a meeting takes the microphone / gives it back.
        case suspend
        case resume
        case timer(TimerKind)
    }

    public enum Action: Equatable, Sendable {
        /// Keep the audio graph up (true) or let it go when idle (false).
        case audio(Bool)
        /// Feed the streaming recogniser.
        case asr(Bool)
        /// Run the wake head on the audio.
        case wake(Bool)
        /// Keep raw audio for the accurate re-read (with pre-roll on start).
        case capture(Bool)
        /// Clear the recogniser between turns so the next utterance does not
        /// arrive with the last one glued to its front.
        case resetAsr
        /// Read the captured turn with the accurate model; answer with
        /// `.transcribed(turn:_:)`.
        case transcribe(turn: Int)
        /// Ask the turn model whether the person has finished; answer with
        /// `.turnVerdict(complete:)`. The endpointer's token proposes an
        /// ending, this is what disposes of it.
        case askTurnModel
        /// The same question, asked because the words stopped arriving
        /// rather than because a pause was heard. The host must drop the
        /// answer if words have grown since — not if the VAD moved, which
        /// in noise it always has.
        case askTurnModelOnStall
        /// The turn is over, and this is why. Always just before the
        /// `.transcribe` it explains — or on its own, for a capture that
        /// ended with nothing to read (`.noWords`).
        case decided(EndReason)
        /// The reply to the turn just decided may not become audible for
        /// this long: the brain starts now, the voice waits. Speech that
        /// resumes inside it joins the turn (the continuation window) and
        /// nobody ever hears the half-answer. Always right after the
        /// `.decided` it belongs to; a decision without one holds nothing.
        case holdReply(seconds: Double)
        /// A VAD onset over a reply was let go without acting on it — the
        /// word window closed with no words, or the words were judged not
        /// the person's. For the trace: every one is a row, because these
        /// are the moments a noise dataset is made of.
        case onsetRejected(OnsetRejection)
        /// …and the other half: the onset's words took the floor. Between
        /// the two, every onset the machine waited on ends in exactly one
        /// row (`handle` guarantees it), so "why did Moe stop — or not?"
        /// always has an answer in the trace.
        case onsetTaken(OnsetTake)
        case submit(String)
        /// The same, for a turn whose first half was already sent to the
        /// brain and withdrawn when the person went on talking: `text` is
        /// the whole request, first half and second, and the host should
        /// tell the brain the fragment it saw was never the request.
        case submitContinuation(String)
        /// Interruptions are off, and a voice started over Moe thinking or
        /// speaking — or the name was said over a reply — and was let be:
        /// nothing stopped, nothing restarted, nothing listened to. For the
        /// log, once per reply (`byName`: it was the wake word).
        case ignoredInterruptionsOff(byName: Bool)
        /// Stop playback and drop everything queued.
        case stopSpeaking
        /// Hold the reply where it is — the sound stops, the place is kept.
        /// A barge-in that turns out to be nothing (`.resumeReply`) picks
        /// up mid-word instead of re-saying the sentence; real words end
        /// it with `.abandonReply`, which stops it outright.
        case pauseSpeech
        /// Held by the person's pause button: the sound stops, the place is
        /// kept, and `.resumeReply` plays on from the same sample. Unlike
        /// `.pauseSpeech` this is not a barge-in and marks nothing as one.
        case holdSpeech
        /// Quieten the reply without stopping it, while it is not yet known
        /// whether the voice that started is talking to Moe. Restoring is
        /// the same action with `false`.
        case duckSpeech(Bool)
        /// Someone is talking over the reply and the hold is up: is it the
        /// person Moe is talking to? Answer with `.bargeInJudged(_:)`.
        /// The endpointer says *that* somebody spoke; this asks *who*.
        case judgeBargeIn
        /// Stop treating the reply in flight as something to say.
        case abandonReply
        /// The interruption was nothing (a cough, "mm-hmm", Moe's own
        /// echo): carry on from the last sentence the person heard.
        case resumeReply
        /// The reply is held by a tap of the key, or has been let go.
        ///
        /// The audio has already stopped (`.pauseSpeech`) — this is for
        /// the person: `.speaking` with nothing coming out looks exactly
        /// like Moe having broken, which is a complaint this repo has
        /// answered more than once. Emitted from the derived diff rather
        /// than beside each transition, so no route into or out of the
        /// hold can be added without carrying it.
        case replyHeld(Bool)
        /// Muted or not, from the diff — what the host shows. One source of
        /// truth: the island's pill and the chat's button both read this.
        case micMuted(Bool)
        /// Why `muted` just changed, emitted beside every `.micMuted` —
        /// for the log. `.unrecorded` is a route that changed it without
        /// saying why, which is a bug, and says so rather than guessing.
        case muteCause(MuteCause)
        /// A muted follow-up window sat untouched for
        /// `Tuning.mutedWindowSeconds` and closed. The conversation's end
        /// (and the unmute that comes with it) follows in the same batch.
        case mutedWindowExpired
        case cue(Cue)
        case armTimer(TimerKind, seconds: Double)
        case cancelTimer(TimerKind)
        case clearPartial
        /// A session that was open is over (the island hides).
        case conversationEnded
        /// The window has been open a while with nothing said: ask whether
        /// there is anything else, however the person has asked to be asked.
        /// The window stays open; an answer is an ordinary turn, and saying
        /// nothing lets it close as it would have.
        case offerToClose
    }

    /// Everything a user can configure, in one place.
    public struct Tuning: Equatable, Sendable {
        /// A follow-up window opens after every reply (no name, no key).
        public var conversation = false
        /// The same, after a turn that was held on the key.
        public var holdOpensConversation = false
        /// Seconds Moe waits for you to start speaking after it wakes.
        public var attendSeconds: Double = 8
        /// Seconds the follow-up window stays open after Moe stops speaking.
        public var followUpSeconds: Double = 8
        /// After a capture in the window that came to nothing — noise, a
        /// voice not for Moe — the window gets this much more, not a fresh
        /// `followUpSeconds`; and after `followUpNothingLimit` of them in a
        /// row it closes. Every such capture used to re-arm the full 8 s, so
        /// a TV or a room of voices kept the microphone open: 18 windows from
        /// 09-23 to 09-29 stayed open a median 13.5 s and up to 60 s, and the
        /// owner reached for the key in 7 of them (`audit-mic-open.md`).
        public var followUpAfterNothingSeconds: Double = 4
        public var followUpNothingLimit = 2
        /// …while muted, instead: the window is not timed out under a
        /// person who has muted themselves (they may be about to unmute and
        /// answer), but a forgotten muted window does not sit open forever.
        public var mutedWindowSeconds: Double = 600
        /// Your voice interrupts Moe. Needs echo cancellation (Phase 3).
        public var bargeIn = false
        /// A voice rising over the reply's echo (`.speechRose`) opens an
        /// onset, as a VAD edge does. Off, only edges do — main before
        /// 2026-09-24, where 56% of real interruptions on the turn bench
        /// were missed, three in four for want of an edge.
        public var onsetOnRise = true
        /// An onset opened by a rise ducks the reply on its first word, as
        /// an edge's does. Off, it goes from words to the judge without a
        /// duck: echo rises that the recogniser makes a word of cannot
        /// pump the volume.
        public var duckOnRise = false
        /// How long a voice over a reply — or over Moe thinking, or over the
        /// first half being read back — is waited on for words before it is
        /// written off as the room. The reply is ducked meanwhile, never
        /// stopped.
        ///
        /// It used to be 0.35 s of VAD, with a 300 ms host gate in front of
        /// it that could never fail (the VAD's earliest possible end is two
        /// 256 ms chunks after its onset). Any noise lasting half a second
        /// reached the loudness judge and then paused the reply. Now the
        /// recogniser must produce words inside this window: 1 s covers its
        /// latency on a one-word "stop" (the onset itself lands ~256 ms in).
        ///
        /// The whole of the problem is here. Cutting on the VAD's first
        /// frame means a room with people in it stops Moe over and over,
        /// because at that instant nothing is known except that *a* sound
        /// was speech-shaped. Waiting for the words means the reply is
        /// already dead by the time we learn it should not have been.
        /// Ducking buys the time to know, and costs nothing if we were
        /// wrong — Moe simply gets a little quieter for a third of a
        /// second, the way a person does when they think they have been
        /// interrupted.
        public var bargeInHoldSeconds: Double = 1.0
        /// How many words (`TurnPolicy.meaningfulWords`) take the floor.
        public var interruptionWords = 1
        /// …over Moe's own voice, unless one of them is a stop word or the
        /// name: then one is enough. Pipecat's min-words shape (≥2 while the
        /// bot speaks); a lone word is the likeliest thing for the
        /// recogniser to make out of the TV or Moe's own residue, and "stop"
        /// is the likeliest real one-word interruption
        /// (research-interruptions.md §5). Thinking and the continuation
        /// window keep `interruptionWords`: nothing is playing there.
        public var interruptionWordsWhileSpeaking = 2
        /// Silence after speech, with no word from the endpointer, that
        /// ends the turn anyway.
        public var silenceFallbackSeconds: Double = 1.5
        /// The longest a single turn may run.
        public var turnCapSeconds: Double = 90
        /// Silence after the turn model said "not finished" — longer, so a
        /// mid-thought pause is not cut, but not forever.
        public var incompleteSilenceSeconds: Double = 3.0
        /// Silence after *both* the turn model and the words said "not
        /// finished". Longer, because there is nothing else left to ask: this
        /// is the pause of somebody thinking mid-sentence, and the only way to
        /// be wrong here is to take their turn away from them.
        ///
        /// It costs almost nothing to be patient in this state — it is the
        /// path 21 of 359 turns took at all, and only 2 of those ended
        /// mid-clause — so the ceiling buys back the ones he notices without
        /// slowing the ones he does not.
        public var midClauseSilenceSeconds: Double = 6.0
        /// How long a "finished" verdict waits when the words disagree —
        /// the transcript ends on a dangler ("go to those", "and then").
        /// Speech resuming inside it keeps the turn open. Measured
        /// 2026-09-07 01:29:59Z: "Actually, I want you to actually go to
        /// those" — p=0.96, taken at once, cut mid-request. LiveKit's agent
        /// waits 0.5 s after its own model for the same reason.
        public var verdictHoldSeconds: Double = 0.45
        /// After the turn model ends a turn, the reply may not become
        /// audible before this much time has passed (`.holdReply`). A floor,
        /// not a delay: the brain runs from the decision and its first word
        /// lands 1.9–2.6 s later, so this changes nothing until a faster
        /// brain arrives — and then it keeps the door open long enough for
        /// the person to go on (LiveKit waits 0.3–0.5 s after its model for
        /// the same reason; a spontaneous mid-sentence pause runs 0.4–0.6 s
        /// at its mode). It was `VoiceEngine.replyFloorSeconds` until the
        /// replay needed to see it.
        public var replyFloorSeconds: Double = 0.8
        /// With interruptions off (`bargeIn` false), how long after a turn
        /// is decided a voice may still start and be joined to it as the
        /// rest of the same sentence (the continuation window). After it,
        /// speech over Moe thinking or speaking is ignored entirely — the
        /// owner, 2026-09-25: with Interrupt off, nothing said over Moe
        /// should stop or restart it. With interruptions on, the window
        /// runs to the first audible word as before.
        ///
        /// Measured on the owner's turn traces (`continuedAfterMs`, 15
        /// continuations 2026-09-24 → 09-25): ten resumed 0.97–2.32 s after
        /// the last word, then a gap, then five at 3.3–15.1 s. The decision
        /// lands ~0.93 s (0.91–1.54) after the last word, so the ten are
        /// 0.06–1.4 s after the decision; the five include 14:58:25, 4.2 s
        /// after it — "Oh, do you hear me?" — which abandoned the reply.
        ///
        /// 1.5 → 3.0 on 2026-10-06, from 09-16 → 10-06: of 35 measured
        /// continuations the median came 1.6 s after the decision and ten at
        /// 2.0–2.8 s, and 25 voices within 3 s of a decision were thrown away
        /// as "interruptions are off" — cut-offs ran at 13–19%. Three seconds
        /// takes those and still lets the 14:58 one (4.2 s) go by.
        public var continuationGraceSeconds: Double = 3.0
        /// The follow-up window after a reply that ended with a question.
        /// 13% of windows that timed out at 8 s were followed by the owner
        /// speaking again within 10 s, 22% within 30 s.
        public var followUpAfterQuestionSeconds: Double = 12
        /// Plan the wait after a verdict from its evidence (`EndpointPolicy`):
        /// decide early, hold the reply long. Nil is the old three regimes
        /// and the fixed floor above.
        public var endpoint: EndpointPolicy?
        /// Woken or barged in, and then nothing at all (no VAD, no words):
        /// give up on the turn after this.
        public var noSpeechSeconds: Double = 4.0
        /// Words stopped arriving this long ago, and the turn has not ended:
        /// ask the turn model, whatever the VAD says. AssemblyAI's
        /// `max_turn_silence` is 1.28 s; the audit of the owner's log found
        /// a 53 s capture over noise with eleven "mid-thought" verdicts and
        /// no VAD end, which is what this bounds.
        public var wordStallSeconds: Double = 1.3
        /// A capture with sound but no words at all ends — silently, with no
        /// read — after this. The streaming recogniser writes its first word
        /// well under a second into speech; 34.7 s of wordless noise held a
        /// capture open on 2026-09-07.
        public var noWordsSeconds: Double = 3.5
        /// An ending clock that fires while a fresh VAD onset still waits on
        /// its words is put off this long, once: the person may have just
        /// started again, and the recogniser is a beat behind the VAD.
        public var onsetGraceSeconds: Double = 0.8
        /// A capture that produced no words is read by the accurate model
        /// rather than dropped. For languages the streaming recogniser (an
        /// English model) cannot write down: there, "no words" says nothing
        /// about whether anybody spoke (review M5).
        public var readWordlessCaptures = false
        /// Seconds of quiet in the window before Moe offers to close it.
        /// Zero never offers: the window just times out. Always less than
        /// `followUpSeconds`, or the offer never comes.
        public var offerToCloseAfter: Double = 0
        /// The turn model is loaded, so the endpointer's token is a
        /// proposal to be checked rather than a decision. Without it the
        /// token ends turns on its own, as it used to.
        public var turnModel = false
        /// A trained wake head is loaded. Standby then runs it alone —
        /// no transcript of the room. Without one, standby falls back
        /// to the Phase 1 spotter on the streaming recogniser.
        public var wakeHead = false

        public init() {}
    }

    // MARK: - State

    public private(set) var state: State = .off
    public var tuning = Tuning()

    private var wakeEnabled = false
    /// The brain owes a reply for the turn in flight.
    private var replyPending = false
    /// Where the last reply the machine carried came from, for
    /// `.replyContinues`. Nil once that reply is dropped or a key press
    /// starts something else — a continuation for a reply that is over
    /// changes nothing.
    private var lastReplySource: Source?
    /// A reply (not an aside) is in flight: submitted and not yet heard
    /// to its end. Outlives `replyPending`, which is only the brain's
    /// half — the audio is usually still playing when the text is done,
    /// and an interruption then still has to cut the transcript and
    /// tell the brain.
    private var replyLive = false
    /// Counts `.transcribe` requests so a late answer can be told apart.
    private var turnCounter = 0
    /// The brain finished while a dictation held the microphone; the reply
    /// it left is still owed a "thinking" to come back to.
    private var sourceBeforeSuspend: Source?
    /// A follow-up window has opened in this session. Once it has, every
    /// turn in the session — even one held on the key — comes back to it.
    private var windowOpen = false
    /// A session was open when the microphone was taken away; its ending
    /// is reported when the machine gets it back.
    private var sessionOpenBeforeSuspend = false
    /// A turn was being read back when the microphone was taken away.
    private struct Ticket: Equatable, Sendable { let source: Source; let turn: Int }
    private var decidingBeforeSuspend: Ticket?

    /// Whether a transcript for `turn` would still be taken — the same test
    /// `.transcribed` applies. False once the turn was stopped, dismissed or
    /// superseded: a read that comes back then is nobody's, and the engine
    /// drops it before spending a judge on it or logging it "submitted"
    /// (2026-10-02 00:33:58: a read finished 14 s after a double-tap had
    /// stopped everything, and the log said "→ submitted").
    public func awaitsTranscript(turn: Int) -> Bool {
        if state == .suspended, let ticket = decidingBeforeSuspend { return ticket.turn == turn }
        if case .deciding(_, let expected) = state { return expected == turn }
        return false
    }
    /// …and its transcript arrived while the microphone was still away.
    private struct Held: Equatable, Sendable { let source: Source; let text: String }
    private var transcriptDuringSuspend: Held?
    /// Where an aside spoken mid-session goes back to when it is done.
    private var asideReturn: State?
    /// You spoke over a reply: it is stopped but not yet abandoned. Set
    /// until the interrupting words are read back — real words abandon
    /// it, nothing resumes it. The brain keeps working meanwhile, because
    /// it cannot be paused and starting over costs a session.
    private var interruptedSource: Source? {
        didSet {
            // The latch cannot outlive the thing it latches. Written as a
            // `didSet` rather than a line beside each of the fourteen
            // places this is cleared, because a fifteenth is what would
            // leave a reply held with nothing able to let it go —
            // "a guard that enumerates names is walked past by a new name".
            if interruptedSource == nil { replyHeldByKey = false }
        }
    }
    /// A tap of the key while Moe was talking: the reply is paused and
    /// stays paused until the next tap.
    ///
    /// A tap has always paused the reply — the sound stops the instant the
    /// key goes down, before anything knows whether a press is a brush, a
    /// tap or a hold. What it did next was resume half a second later, so
    /// the whole gesture read as a stutter with no way to make it stick.
    /// The owner, 2026-09-08: "when you press the option key it does a
    /// pausing thing, I don't know what it does with it — that should just
    /// be a straight pause when it talks, then you press it again and it
    /// can resume its talking."
    ///
    /// So a tap over a reply now holds it there, and the next tap lets it
    /// go on from the same sample. A *hold* is unchanged: it is somebody
    /// speaking, and their words decide whether the reply is resumed or
    /// replaced, exactly as before.
    private var replyHeldByKey = false
    /// Muted by the person (`.setMuted`). Public so the host can read it.
    /// Sticky: see `Event.setMuted`.
    public private(set) var muted = false
    /// Why `muted` last changed inside this `handle` — read at the diff.
    private var muteCauseThisEvent: MuteCause?
    /// The follow-up clock running now was armed while muted (the safety
    /// cap), not the ordinary window. A stale ordinary clock firing into a
    /// muted window must not close it.
    private var windowClockMuted = false
    /// Captures in this follow-up window that came to nothing, in a row.
    private var windowNothings = 0
    /// The word count a verdict's ceiling clock was armed on: a repeat
    /// verdict over the same words does not start that clock again.
    private var ceilingArmedOnWords: Int?

    /// The talk key is down: it talks through a mute without lifting it.
    private var talkingThrough: Bool {
        if case .capturing(.hold) = state { return true }
        return false
    }
    /// The room is not listened to right now.
    private var deaf: Bool { muted && !talkingThrough }

    /// What the microphone reports, as opposed to what the person does with
    /// a key or a button. While muted these are dropped at the door.
    private static func isHeard(_ e: Event) -> Bool {
        switch e {
        case .woke, .speechStarted, .speechEnded, .speechRose, .wordsGrew, .wordsHeard,
             .speechWasNoise, .endOfUtterance:
            return true
        default:
            return false
        }
    }
    /// A false interruption already paused this reply once: the VAD does
    /// not get a second go at it. Cleared with the next turn.
    private var bargeInSpent = false
    /// A VAD onset landed while a reply was on its way — Moe thinking, the
    /// first half of a turn being read back, or the reply playing (then it
    /// is ducked) — and the machine is waiting on the recogniser for words.
    /// Nothing has been stopped and nothing decided. Words (`.wordsHeard`)
    /// take the floor; the word window (`.timer(.bargeInHold)`) running out
    /// first means it was the room, and everything carries on.
    private var onsetPending = false
    /// The pending onset set `interruptedSource` (it was over a playing
    /// reply), so letting it go must clear it.
    private var onsetMarkedReply = false
    /// Words arrived over a playing reply and the host is judging whose
    /// voice it is. The word window no longer applies.
    private var onsetJudging = false
    /// The pending onset is the person perhaps *going on with their own
    /// turn* — the continuation window, before any of the reply is heard —
    /// not somebody interrupting Moe. Different rules (review H3, 2026-09-22):
    /// any token the recogniser writes, filler included, takes it, and the
    /// word window does not close while the VAD still hears them. "…remind
    /// me tomorrow. — uhh… and also call Dan" must still join, however long
    /// the "uhh"; that window is what recovered 64 of 108 cut-offs.
    private var onsetContinuation = false
    /// The word window was started again for a first word over the reply.
    private var onsetExtended = false
    /// The pending onset over a reply has produced a word: only now is the
    /// reply ducked (`Derived.ducked`).
    private var onsetHeardWord = false
    /// The pending onset was a voice rising over the echo (`.speechRose`),
    /// not a VAD edge: its first word does not duck unless `duckOnRise`.
    private var onsetFromRise = false
    /// The interruption landed while Moe was still thinking: nothing was
    /// playing, so nothing was stopped, so a false one must not spend the
    /// person's one pause per reply (`bargeInSpent`).
    private var interruptedWhileThinking = false
    /// The key went down while nothing of the reply was playing — Moe
    /// thinking, between two sentences while a tool runs, or over a reply a
    /// barge-in had already found silent. If the press turns out to be a
    /// tap there is nothing to pause, and it changes nothing
    /// (`.holdCancelled`); it used to withdraw the turn.
    private var keyFoundReplySilent = false
    /// Between a turn's decision and the first audible word of its reply,
    /// the microphone stays open and a voice that starts is *the same turn
    /// going on*, not an interruption and not a new one.
    ///
    /// Measured across ten days of the owner's log (2026-08-28 → 09-07):
    /// of 108 turns cut short, 64 were the turn model saying "finished"
    /// (p ≥ 0.94) at a breath after a clause that parses as complete —
    /// "…I'm right now sitting in my balcony in my backyard" — and the
    /// person resuming one to three seconds later. Confidence does not
    /// separate a breath from an ending (74 % of the cuts were at p ≥ 0.95
    /// against a 68 % base rate), and no vendor's model does better: their
    /// answer is to let the brain start and take the answer back if the
    /// person goes on before hearing it (LiveKit's preemptive generation,
    /// Deepgram's EagerEndOfTurn / TurnResumed, Cartesia's eager_end /
    /// resume). Moe's first word lands 1.9–2.6 s after the person stops,
    /// so that window covers the resumes it measured, at no cost to the
    /// turns that really were over.
    private var continuationOpen = false
    /// Interruptions are off and the grace after the decision has run out
    /// (`.timer(.continuationGrace)`): the window takes no new voice, and
    /// closes as soon as no onset that began inside the grace is pending.
    private var continuationGraceOver = false
    /// The reply being finished ended with a question to the person
    /// (`.replyEndedWithQuestion`); read once, by the window it opens.
    private var replyAskedQuestion = false
    /// This reply has already said in the log that a voice was ignored.
    private var ignoredLoggedThisReply = false
    /// The person started again while the accurate model was still reading
    /// the first half back. When the read lands it becomes the prefix of
    /// the turn, not a turn of its own.
    private var resumedWhileDeciding = false
    /// The first half of the turn being captured now, to be joined to the
    /// second at the next decision. `sentToBrain`: the first half was
    /// submitted and withdrawn, so the host must say so to the brain.
    private struct Prefix: Equatable, Sendable { let text: String; let sentToBrain: Bool }
    private var continuationPrefix: Prefix?
    /// The last text submitted, so a continuation can be joined to it.
    private var lastSubmitted = ""
    /// Since this capture opened on the name, has the VAD heard the person
    /// start again? Until it has, a speech *end* is the end of "Hey Moe"
    /// and an empty endpoint is the endpointer hearing nothing — neither is
    /// the request, and neither may end the turn. Only the no-speech timer
    /// may, and it transcribes what little there is rather than deciding
    /// on a verdict about the name.
    ///
    /// Measured before this existed (2026-09-06): the endpointer's empty
    /// utterance re-armed a 1.5 s silence timer and asked the turn model
    /// about "Hey Moe." — p 0.92–0.99, finished — so 36 of 40 wake turns
    /// that day were decided about a second after the name, before the
    /// person had said anything, and what reached the brain was whatever
    /// the recogniser made of room tone: "Il m'a", "Hey no, no".
    private var requestHeard = true
    /// The endpointer proposed an ending on an unfinished sentence and the
    /// `incompleteSilenceSeconds` clock is running. Only `.wordsGrew` reads
    /// it: the clock must restart while the person is still talking.
    ///
    /// Measured 2026-09-06 21:57Z: a 27 s dictation, spoken fast with no
    /// pause the VAD could see, got an endpoint on "…stuff like that". That
    /// armed 3 s and returned without asking the turn model; nothing but a
    /// VAD edge or another endpoint could cancel it, neither came, and it
    /// fired thirteen words later with the person mid-sentence.
    private var incompleteClockRunning = false
    /// The recogniser has written at least one word in this capture.
    private var wordsInCapture = false
    /// The VAD's view, for the rules below: an onset and no end yet.
    private var vadInSpeech = false
    /// Why `.silence` is armed, when it is an ending clock (not the
    /// no-speech wait after the name). An ending clock is *not* cancelled
    /// by a VAD onset any more — only by words — so steady or flapping
    /// noise can no longer hold a turn open by re-starting the VAD.
    private var silenceReason: EndReason?
    private var verdictHoldArmed = false
    /// A VAD onset arrived while an ending clock ran, and no words have
    /// followed it yet.
    private var onsetInCapture = false
    /// The running ending clock has already been put off once for an onset.
    private var clockDeferred = false
    /// The last turn-model question was asked because the words stalled.
    private var askedOnStall = false
    /// The reply's hold the last plan asked for (`EndpointPolicy`), for the
    /// decision its clock ends in. Words that cancel the clock cancel it.
    private var plannedHold: Double?

    public init() {}

    /// True while a session is open — the island shows it.
    public var inConversation: Bool { inSession(state) }

    /// Capturing the second half of a turn whose first half was already
    /// decided — the person went on after a pause (the continuation window).
    public var capturingTheRestOfATurn: Bool {
        if case .capturing = state { return continuationPrefix != nil }
        return false
    }

    /// The turn being read back is the second half of one the session
    /// already took (`continuationPrefix`): whatever is decided about the
    /// voice, the first half was the person's (review H3).
    public var decidingTheRestOfATurn: Bool {
        if case .deciding = state { return continuationPrefix != nil || resumedWhileDeciding }
        return false
    }

    /// The pending onset is perhaps the person going on with their own turn
    /// (the continuation window) — the only onset the host holds the reply
    /// back for (review M5: a cough over a held-key turn's wait must not).
    public var awaitingContinuationWords: Bool { onsetPending && onsetContinuation }

    /// A VAD onset is waiting on words. The host counts the recogniser's
    /// words from the moment this turns true, not from before it.
    public var awaitingWords: Bool { onsetPending }

    /// Whether "yes", "okay", "sure", "right" count as words right now
    /// (`TurnPolicy.meaningfulWords(countNods:)`). Over Moe's own voice — a
    /// reply playing, or an interruption of the thinking — they are a nod,
    /// said *to* a speaker. Anywhere the person has the floor, or is going
    /// on with their turn, they are an answer (review M3: "Shall I send
    /// it?" — "Yes." was dropped as no words in noise).
    public var wordsCountNods: Bool {
        switch state {
        case .speaking: return false
        case .thinking: return continuationOpen
        default: return true
        }
    }

    // MARK: - Reduce

    public mutating func handle(_ event: Event) -> [Action] {
        // Muted: the room is not listened to. Checked before anything else
        // so no state, however it was reached, can hear through it.
        if deaf, Self.isHeard(event) { return [] }
        var out: [Action] = []
        let mutedBefore = muted
        muteCauseThisEvent = nil
        let derivedBefore = Derived(state, tuning: tuning, wakeEnabled: wakeEnabled,
                                    onsetPending: onsetPending, onsetHeardWord: onsetHeardWord,
                                    continuationOpen: continuationOpen,
                                    replyHeldByKey: replyHeldByKey, muted: deaf)
        // Read before `reduce`: it may clear `asideReturn`, which this reads.
        let wasInSession = inSession(state)
        let onsetBefore = onsetPending

        reduce(event, &out)
        settleOnset(&out)
        settleContinuation()
        // An onset that ended without saying how is reported as overtaken:
        // derived, so no route out of the word window can forget the row.
        if onsetBefore, !onsetPending, !out.contains(where: Self.endsAnOnset) {
            out.append(.onsetRejected(.superseded))
        }

        // Whatever the transition, the things that must follow the state do.
        // A mute lasts the conversation, and no longer. Left on past it,
        // the wake word would be dead with nothing on screen to say why.
        if wasInSession, !inSession(state), state != .suspended, muted {
            muted = false
            muteCauseThisEvent = .conversationEnded
        }
        let derivedAfter = Derived(state, tuning: tuning, wakeEnabled: wakeEnabled,
                                   onsetPending: onsetPending, onsetHeardWord: onsetHeardWord,
                                   continuationOpen: continuationOpen,
                                   replyHeldByKey: replyHeldByKey, muted: deaf)
        if mutedBefore != muted {
            out.append(.muteCause(muteCauseThisEvent ?? .unrecorded))
            out.append(.micMuted(muted))
        }
        if derivedBefore.held != derivedAfter.held { out.append(.replyHeld(derivedAfter.held)) }
        if derivedBefore.ducked != derivedAfter.ducked { out.append(.duckSpeech(derivedAfter.ducked)) }
        if derivedBefore.audio != derivedAfter.audio { out.append(.audio(derivedAfter.audio)) }
        if derivedBefore.asr != derivedAfter.asr { out.append(.asr(derivedAfter.asr)) }
        if derivedBefore.wake != derivedAfter.wake { out.append(.wake(derivedAfter.wake)) }
        if derivedBefore.capture != derivedAfter.capture { out.append(.capture(derivedAfter.capture)) }
        if wasInSession, !inSession(state), state != .suspended {
            out.append(.conversationEnded)
        }
        return out
    }

    private static func endsAnOnset(_ a: Action) -> Bool {
        switch a {
        case .onsetRejected, .onsetTaken: return true
        default: return false
        }
    }

    /// What follows from being in a state, rather than from how it was
    /// entered. Computed on both sides of every event so no transition can
    /// forget to switch something off — the class of bug the old engine's
    /// nine booleans kept producing.
    private struct Derived: Equatable {
        let audio: Bool
        let asr: Bool
        let capture: Bool
        let wake: Bool
        /// The reply is quietened while it is not yet known whose voice
        /// started over it. Derived rather than appended by hand: a duck
        /// left on by a transition that forgot to undo it would make every
        /// reply after it quiet, and that is precisely the class of bug
        /// this struct exists to make impossible.
        let ducked: Bool
        /// A tap of the key is holding the reply. Only ever true over a
        /// reply: anywhere else the latch is stale by definition, and
        /// deriving it here rather than reading the flag means a route out
        /// of the hold that forgot to clear it still reports "let go".
        let held: Bool

        init(_ s: State, tuning: Tuning, wakeEnabled: Bool, onsetPending: Bool, onsetHeardWord: Bool,
             continuationOpen: Bool, replyHeldByKey: Bool, muted: Bool) {
            self.init(s, tuning: tuning, wakeEnabled: wakeEnabled, onsetPending: onsetPending,
                      onsetHeardWord: onsetHeardWord,
                      continuationOpen: continuationOpen, replyHeldByKey: replyHeldByKey)
            // Muted: no name, no transcript, nothing kept. The graph stays up
            // — the reply plays through it.
            if muted { self = Derived(copy: self, silenced: true) }
        }

        private init(copy d: Derived, silenced: Bool) {
            audio = d.audio; ducked = d.ducked; held = d.held
            asr = false; capture = false; wake = false
        }

        private init(_ s: State, tuning: Tuning, wakeEnabled: Bool, onsetPending: Bool, onsetHeardWord: Bool,
                     continuationOpen: Bool, replyHeldByKey: Bool) {
            // Only a reply can be ducked; anywhere else the flag is stale.
            // And only once a word has been heard over it: a bare VAD onset
            // over Moe's own voice is, most of the time, Moe's own voice —
            // measured on the owner's Mac 2026-09-23, 40 onsets over replies
            // let go with no words in one day, 36 of 54 such clips under
            // −46 dBFS (the canceller's residue), and each dipped the reply
            // to −14 dB for a second: the volume pumped through every long
            // answer. The recogniser still listens from the onset; the duck
            // waits for its first word.
            if case .speaking = s { ducked = onsetPending && onsetHeardWord } else { ducked = false }
            switch s {
            case .speaking, .thinking: held = replyHeldByKey
            default: held = false
            }
            // The head listens for the name in standby, and while Moe
            // speaks — saying its name interrupts it whatever `bargeIn`
            // says. Inside a session the recogniser is on and the
            // spotter reads the name off the transcript instead.
            switch s {
            case .standby: wake = wakeEnabled && tuning.wakeHead
            case .speaking: wake = wakeEnabled && tuning.wakeHead
            default: wake = false
            }
            switch s {
            case .off, .suspended:
                audio = (s == .suspended)   // a dictation is using the graph
                asr = false; capture = false
            case .standby:
                // With a wake head, standby transcribes nothing: the
                // room is not written down. Without one, the Phase 1
                // spotter reads the streaming transcript.
                audio = true; asr = !tuning.wakeHead; capture = false
            case .attending, .followUp, .capturing:
                // Capture runs from the moment Moe is waiting, not from the
                // moment the VAD notices: the first syllable is never lost.
                audio = true; asr = true; capture = true
            case .deciding:
                // Until the reply is heard the turn may still be going on:
                // the microphone stays open for its second half.
                audio = true; asr = continuationOpen; capture = continuationOpen
            case .thinking:
                // …and a sound over the wait is listened to for words.
                audio = true
                asr = continuationOpen || onsetPending
                capture = continuationOpen || onsetPending
            case .speaking:
                // Something speech-shaped started over the reply: the
                // recogniser listens for words, and the audio is kept, or
                // there would be nothing to judge them by. Not ducked yet.
                audio = true; asr = onsetPending; capture = onsetPending
            }
        }
    }

    private func inSession(_ s: State) -> Bool {
        switch s {
        case .off, .standby, .suspended: return false
        case .speaking(.aside): return asideReturn != nil
        default: return true
        }
    }

    private mutating func reduce(_ event: Event, _ out: inout [Action]) {
        switch event {

        case .setWakeHead(let loaded):
            tuning.wakeHead = loaded

        case .setTurnModel(let loaded):
            tuning.turnModel = loaded

        case .setWake(let on):
            wakeEnabled = on
            if on, state == .off { state = .standby }
            if !on, state == .standby { state = .off }

        case .setMuted(let on):
            guard on != muted else { return }
            muted = on
            muteCauseThisEvent = .button
            // The window's clock follows: muted it waits (the safety cap),
            // unmuted it listens its full length from now.
            if state == .followUp { enterFollowUp(&out) }
            // The key is down: it talks through the mute until it comes up.
            guard on, !talkingThrough else { return }
            // Something was being listened to. It is not any more.
            if onsetPending, onsetMarkedReply { interruptedSource = nil }
            clearOnset(&out)
            switch state {
            case .capturing, .attending:
                out.append(.resetAsr)
                out.append(.clearPartial)
                continuationPrefix = nil
                if let i = interruptedSource {
                    // Muted over an interruption: it was not one. The reply
                    // (or the work) goes on exactly as a false alarm would.
                    interruptedSource = nil
                    interruptedWhileThinking = false
                    out.append(.resumeReply)
                    state = replyPending ? .thinking(i) : .speaking(i)
                } else if windowOpen || tuning.conversation {
                    // Muted mid-turn in a conversation: the conversation
                    // stays, waiting — closing it would end the mute too,
                    // which is the mute flipping back on its own.
                    cancelSessionTimers(&out)
                    enterFollowUp(&out)
                } else {
                    close(&out)
                }
            default:
                break
            }

        case .pauseReply(let pause):
            if pause {
                guard !replyHeldByKey, interruptedSource == nil,
                      case .speaking(let s) = state else { return }
                clearOnset(&out)
                out.append(.holdSpeech)
                if s == .aside { asideReturn = nil }
                interruptedSource = s
                replyHeldByKey = true
            } else {
                guard replyHeldByKey, let s = interruptedSource else { return }
                interruptedSource = nil          // clears the latch (didSet)
                out.append(.resumeReply)
                // The held audio is still queued, and plays on from here:
                // speaking, whether or not the brain is still writing —
                // `.ttsDrained` parks it in `.thinking` if more is to come.
                state = .speaking(s)
            }

        case .holdDown:
            guard state != .suspended else { return }
            // The key talks *through* a mute (`talkingThrough`): heard while
            // it is down, muted again when it comes up. It does not unmute —
            // a tap is also the reply's pause button, and a pause must not
            // quietly open the room.
            if replyHeldByKey {
                // The key is down over a reply this key already paused.
                // Either it is the tap that lets it go on, or it is a hold
                // and the person is about to speak over it. The release
                // says which, so capture — but leave the reply exactly
                // where it is rather than dropping it the way
                // `interruptForNewTurn` would.
                out.append(.resetAsr)
                out.append(.clearPartial)
                enterCapturing(.hold, &out)
                return
            }
            interruptForNewTurn(&out, deferrable: true)
            out.append(.resetAsr)
            out.append(.clearPartial)
            enterCapturing(.hold, &out)

        case .holdUp:
            guard case .capturing(.hold) = state else { return }
            startDeciding(.hold, .key, &out)

        case .holdCancelled:
            guard case .capturing(.hold) = state else { return }
            out.append(.resetAsr)
            out.append(.clearPartial)
            // The key was tapped, not held: nothing was recorded, so there is
            // no new turn and the reply it stopped was never replaced.
            //
            // The tap is the person's pause button (`replyHeldByKey`). The
            // first one leaves the reply stopped where it is; the second
            // lets it go on from the same sample. Either way the reply is
            // never lost — the old behaviour, resuming on every tap, is
            // the second of these two with no way to reach the first.
            if let s = interruptedSource {
                if replyHeldByKey {
                    interruptedSource = nil      // clears the latch (didSet)
                    out.append(.resumeReply)
                    state = replyPending ? .thinking(s) : .speaking(s)
                    return
                }
                if keyFoundReplySilent {
                    // A tap over the wait: nothing was playing, so there is
                    // nothing to pause and nothing to lose. Put the turn back
                    // as it was — it used to be withdrawn here, and the
                    // answer the person was waiting for never came. Anything
                    // the brain said meanwhile waited in the host and plays
                    // now; if the brain finished meanwhile, the reply is
                    // queued again from what was heard of it.
                    keyFoundReplySilent = false
                    interruptedSource = nil
                    interruptedWhileThinking = false
                    continuationOpen = continuationPrefix != nil
                    continuationPrefix = nil
                    if replyPending {
                        state = .thinking(s)
                    } else {
                        out.append(.resumeReply)
                        state = .speaking(s)
                    }
                    return
                }
                replyHeldByKey = true
                // `.pauseSpeech` already stopped the sound when the key went
                // down; nothing more to do but stay here. The state is the
                // reply's own, so the island shows a held reply rather than
                // an open microphone.
                state = replyPending ? .thinking(s) : .speaking(s)
                return
            }
            if windowOpen { enterFollowUp(&out) } else { close(&out) }

        case .holdAborted:
            guard case .capturing(.hold) = state else { return }
            out.append(.resetAsr)
            out.append(.clearPartial)
            if let s = interruptedSource {
                // `.holdDown` kept the reply it stopped (deferrable). Put
                // things back exactly: a reply that was playing plays on
                // from the same sample; one a tap had already held stays
                // held, for the tap that lets it go.
                if !replyHeldByKey {
                    interruptedSource = nil
                    out.append(.resumeReply)
                }
                state = replyPending ? .thinking(s) : .speaking(s)
                return
            }
            if windowOpen { enterFollowUp(&out) } else { close(&out) }

        case .toggle:
            // The hotkey is hands-free: no key stays down to end a
            // talk-through, so "listen to me now" has to mean unmuted.
            if muted {
                muted = false
                muteCauseThisEvent = .hotkey
            }
            switch state {
            case .off, .standby:
                out.append(.clearPartial)
                out.append(.resetAsr)
                enterAttending(.hotkey, &out)
            case .attending:
                // Pressed again while waiting: you changed your mind.
                close(&out)
            case .capturing(let s):
                // Pressed again while speaking: that is the end of the turn.
                startDeciding(s, .key, &out)
            case .thinking(let s):
                // Pressed while Moe is working on the last question: that
                // question is withdrawn and this is a new one. Waiting for
                // an answer you no longer want, unable to say so, is the
                // thing that makes an assistant feel like a machine.
                dropReply(&out)
                out.append(.clearPartial)
                out.append(.resetAsr)
                enterAttending(s == .aside ? .hotkey : s, &out)
            case .deciding(let s, _):
                // Its words are still being read back; that read is stale.
                replyPending = false
                replyLive = false
                out.append(.clearPartial)
                out.append(.resetAsr)
                enterAttending(s == .aside ? .hotkey : s, &out)
            case .speaking(.aside):
                // Pressed to talk over a nudge: the nudge stops, you get
                // the floor.
                out.append(.stopSpeaking)
                out.append(.clearPartial)
                out.append(.resetAsr)
                enterAttending(.hotkey, &out)
            case .speaking(let s):
                out.append(.stopSpeaking)
                dropReply(&out)
                enterAttending(s, &out)
            case .followUp:
                // "I'm about to say something": hold the window open.
                out.append(.cancelTimer(.followUp))
                out.append(.cancelTimer(.offerToClose))
                enterAttending(.followUp, &out)
            case .suspended:
                break
            }

        case .stopAll:
            guard state != .suspended else { return }
            out.append(.stopSpeaking)
            dropReply(&out)
            out.append(.resetAsr)
            out.append(.clearPartial)
            close(&out)

        case .dismiss:
            // Only the window and its turns: a held turn is not a window.
            switch state {
            case .followUp, .attending(.followUp), .capturing(.followUp), .deciding(.followUp, _):
                // Said over a paused reply: that reply is over too, and
                // the audio must not come back after the goodbye.
                if interruptedSource != nil {
                    interruptedSource = nil
                    out.append(.stopSpeaking)
                    dropReply(&out)
                }
                out.append(.cue(.close))
                out.append(.resetAsr)
                out.append(.clearPartial)
                close(&out)
            default:
                return
            }

        case .woke:
            switch state {
            case .capturing(.followUp) where interruptedSource == nil:
                // Said inside the window, mid-capture: it is this turn's
                // name — the re-read is cut at it, and the cue says so.
                state = .capturing(.wake)
                out.append(.cue(.wake))
                return
            case .capturing where interruptedSource != nil:
                // The VAD paused Moe first (barge-in), and the head
                // has now heard that the interruption was its name:
                // not a false interruption to resume from, a turn.
                interruptedSource = nil
                dropReply(&out)
                out.append(.cancelTimer(.silence))
                out.append(.cancelTimer(.turnCap))
            case .off, .suspended, .deciding, .thinking, .capturing:
                return
            case .speaking(.aside):
                out.append(.stopSpeaking)
            case .speaking:
                // Saying its name interrupts it, interruptions on or off.
                // Off used to mean the name too (the owner, 2026-09-25);
                // five wakes over a reply were then ignored 09-29 → 09-30,
                // two ending on the hotkey, and the owner reversed it on
                // 2026-10-06. A voice that is not the name still does not
                // stop it. The host only feeds a sure wake here
                // (`WakeOwnerCheck.stopsReplyAtHead`).
                // Reachable once the wake head runs while Moe speaks
                // (Phase 4); the Phase 1 spotter reads a transcript that
                // is off during speech.
                out.append(.stopSpeaking)
                dropReply(&out)
            case .standby, .attending, .followUp:
                break
            }
            let fromStandby = state == .standby
            cancelSessionTimers(&out)
            out.append(.cue(.wake))
            out.append(.clearPartial)
            // With the head, the recogniser was off in standby: it holds
            // the last session's tail, not this request. (The capture's
            // pre-roll has the request from its first syllable; the
            // spotter strips the name from the re-read.) Without the
            // head no reset: the recogniser has the rest of the breath.
            if fromStandby, tuning.wakeHead { out.append(.resetAsr) }
            enterCapturing(.wake, awaitingSpeech: true, &out)

        case .speechStarted:
            vadInSpeech = true
            switch state {
            case .attending(let s):
                out.append(.cancelTimer(.attend))
                enterCapturing(s, &out)
            case .followUp:
                out.append(.cancelTimer(.followUp))
                out.append(.cancelTimer(.offerToClose))
                enterCapturing(.followUp, &out)
            case .capturing(let s) where s != .hold:
                if !requestHeard {
                    // The request starting after the name: the no-speech
                    // wait is over, and the no-words clock starts now.
                    requestHeard = true
                    out.append(.cancelTimer(.silence))
                    silenceReason = nil
                    if !wordsInCapture {
                        out.append(.armTimer(.noWords, seconds: tuning.noWordsSeconds))
                    }
                } else if silenceReason != nil || verdictHoldArmed {
                    // A clock is running on this turn's ending. This used
                    // to cancel it outright — and in a room where the VAD
                    // flaps, every flap cancelled every clock (H6 in the
                    // audit: eleven verdicts in 53 s, none survived). Now
                    // the clock stands until *words* say the person went
                    // on; the onset only earns it one short reprieve.
                    onsetInCapture = true
                }
            case .deciding(let s, _) where continuationTakesOnset && s != .hold:
                // Perhaps the person going on while the first half is read
                // back — or perhaps the room. Words decide (`confirmOnset`).
                beginOnset(resetRecogniser: false, &out)
                onsetContinuation = true
            case .thinking(let s) where continuationTakesOnset && s != .aside && s != .hold && !replyHeldByKey:
                // Nothing of the reply has been heard yet: if this is words,
                // it is the same turn going on. The recogniser already holds
                // the first half, so it is not reset — the host counts from
                // here.
                beginOnset(resetRecogniser: false, &out)
                onsetContinuation = true
            case .thinking(let s) where s != .aside && tuning.bargeIn && !bargeInSpent && !replyHeldByKey:
                // Nothing to stop yet — the answer has not been spoken. Words
                // will abandon the question in flight; a cough, a fan, a dish
                // leave it exactly where it was, and nothing is held.
                beginOnset(resetRecogniser: true, &out)
            case .speaking(let s) where s != .aside && tuning.bargeIn
                && !bargeInSpent && !onsetPending && !replyHeldByKey:
                // Do not stop. At this instant the only thing known is
                // that something speech-shaped began — not whose voice,
                // not whether it holds, not whether it is Moe's own reply
                // coming back through the microphone. Stopping here is
                // what makes a room with other people in it interrupt Moe
                // over and over.
                //
                // So: duck, keep the audio, and start the clock. The reply
                // carries on underneath. If the voice turns out to be the
                // person Moe is talking to, the stop is a third of a
                // second late and nobody notices; if it does not, nothing
                // was interrupted at all.
                //
                // And the thing that decides is words, not sound: the
                // recogniser is switched on under the duck (it is off while
                // Moe speaks) and the reply is paused only once it writes
                // one down. A VAD edge ending proves nothing either way —
                // "stop" is over before its word is decoded — so the word
                // window, not `.speechEnded`, is what lets it go.
                onsetOverTheReply(s, &out)
            default:
                noteIgnoredWithInterruptionsOff(byName: false, &out)
            }

        case .speechRose:
            // A voice joining speech the VAD was already in. Over a reply
            // that is the person talking over Moe's echo — the edge they
            // never got — and it goes the same way an edge does: words,
            // then the judge. Anywhere else the VAD's own edges are enough.
            guard tuning.onsetOnRise, case .speaking(let s) = state, s != .aside, tuning.bargeIn,
                  !bargeInSpent, !onsetPending, !replyHeldByKey else { break }
            onsetOverTheReply(s, &out)
            onsetFromRise = true

        case .speechEnded:
            // The endpointer ends a turn. This is the net under it: a VAD
            // start with no words behind it (a cough, a door, the TV) would
            // otherwise leave the microphone open for good.
            //
            // Not on the name's own ending: a wake capture opens with "Hey
            // Moe" still in the air, and the first speech end after it is
            // the end of the name, not of a request nobody has made yet.
            // The no-speech timer is already waiting for that request.
            vadInSpeech = false
            askedOnStall = false     // the host asks the turn model at this pause
            // Only when no clock is already running on this turn's end: a
            // VAD that flaps in noise used to re-arm this on every flap, and
            // a pause ending a cough mid-thought must not shorten the
            // six-second wait a "still going" verdict asked for.
            if case .capturing(let s) = state, s != .hold, requestHeard,
               silenceReason == nil, !verdictHoldArmed {
                armEnding(.silence, seconds: tuning.silenceFallbackSeconds, .vad, &out)
            }

        case .wordsHeard(let n, let urgent):
            if onsetPending, n >= 1, case .speaking = state, !onsetFromRise || tuning.duckOnRise {
                onsetHeardWord = true
            }
            if onsetPending, n >= wordsToTakeTheFloor(urgent: urgent) {
                confirmOnset(&out)
                return
            }
            if onsetPending, n >= 1, !onsetJudging, !onsetExtended,
               case .speaking = state, onsetMarkedReply {
                // One word over the reply, and two are needed: "Actually… what
                // about Tuesday" has a beat in it. The window starts again from
                // this word, once (review M3).
                onsetExtended = true
                out.append(.armTimer(.bargeInHold, seconds: tuning.bargeInHoldSeconds))
                return
            }
            guard n > 0, case .capturing(let s) = state, s != .hold else { return }
            // Words are arriving: this capture is somebody talking.
            if !wordsInCapture {
                wordsInCapture = true
                out.append(.cancelTimer(.noWords))
            }
            // A person who is still talking cancels any clock on their
            // turn's end, whatever the VAD says. It used to take an onset or
            // the VAD "in speech" as well — and the noise-floor gate ends
            // speech over a TV without Silero ending it, then refuses an
            // onset for a voice no louder than the room, so the words kept
            // coming and the clock cut the turn mid-sentence (review H4). A
            // partial landing late for the last word before a pause costs a
            // stall check (1.3 s) at worst, and the turn model asked at that
            // pause still decides it.
            cancelEnding(&out)
            incompleteClockRunning = false
            onsetInCapture = false
            // The clock that does not care what the VAD thinks.
            out.append(.armTimer(.wordStall, seconds: tuning.wordStallSeconds))

        case .wordsGrew:
            // The person going on with their turn: any token counts, a
            // filler included — the accurate read decides what it was.
            if onsetPending, onsetContinuation {
                confirmOnset(&out)
                return
            }
            guard case .capturing(let s) = state, s != .hold else { return }
            // "ummm… uhhh": still talking, so the stall is not yet a stall.
            if wordsInCapture { out.append(.armTimer(.wordStall, seconds: tuning.wordStallSeconds)) }
            // Words are still arriving: the unfinished-sentence clock, if it
            // is running, starts again from now. Nothing else changes — a
            // pause the VAD sees still ends the turn the ordinary way.
            guard incompleteClockRunning else { return }
            armEnding(.silence, seconds: tuning.incompleteSilenceSeconds, .ceiling, &out)

        case .notTheOwner:
            // The host scored the voice of a hands-free capture and it is
            // clearly somebody else's. Nothing is read and nothing is sent;
            // whatever the capture interrupted — a reply, the window — picks
            // up as though it had not happened. Never for the key: whoever
            // holds it is the person asking.
            guard case .capturing(let s) = state, s != .hold else { return }
            cancelCaptureClocks(&out)
            out.append(.decided(.notOwner))
            out.append(.resetAsr)
            deliverTranscript("", from: s, &out)

        case .speechWasNoise:
            guard case .capturing(.wake) = state, requestHeard else { return }
            requestHeard = false
            out.append(.cancelTimer(.noWords))
            silenceReason = nil
            out.append(.armTimer(.silence, seconds: tuning.noSpeechSeconds))

        case .endOfUtterance(let text):
            switch state {
            case .capturing(.hold):
                break   // the key decides
            case .capturing where !requestHeard && text.trimmingCharacters(in: .whitespaces).isEmpty:
                // Nothing has been said since the name and the endpointer
                // heard nothing: there is no utterance here to have ended.
                // Asking the turn model now would be asking it about "Hey
                // Moe." — which it calls finished — and the recogniser
                // would then be asked to read a request out of room tone.
                out.append(.resetAsr)
            case .capturing(let s):
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    requestHeard = true
                    if !wordsInCapture { wordsInCapture = true; out.append(.cancelTimer(.noWords)) }
                }
                askedOnStall = false
                // The endpointer says "that sounded like the end of an
                // utterance" — an English model trained on read speech,
                // and it fires on a breath. It used to end the turn by
                // itself, which is why Moe cut people off mid-thought:
                // "…and say that we have to" ended a turn, and a long
                // answer that paused at a comma ended another.
                //
                // So the token proposes and the turn model — whose whole
                // job is "has this person finished?" — disposes. The
                // silence timer bounds the wait, so a verdict that never
                // comes cannot leave the microphone open.
                if TurnPolicy.completeness(of: text) == .incomplete {
                    incompleteClockRunning = true
                    armEnding(.silence, seconds: tuning.incompleteSilenceSeconds, .ceiling, &out)
                    return
                }
                incompleteClockRunning = false
                if tuning.turnModel {
                    out.append(.askTurnModel)
                    armEnding(.silence, seconds: tuning.silenceFallbackSeconds, .vad, &out)
                    return
                }
                startDeciding(s, .eou, &out)
            case .attending(let s) where !text.trimmingCharacters(in: .whitespaces).isEmpty:
                // Speech the VAD never flagged — still a turn. But not one
                // to end on the endpointer's word alone: it gets the same
                // gates as any capture — the dangler check, the turn model
                // — by becoming a capture and being asked again. Measured
                // 2026-09-07 01:49:59Z: "…so ready to prompt. I wanna" was
                // ended here, at once, mid-request.
                out.append(.cancelTimer(.attend))
                enterCapturing(s, &out)
                out += handle(.endOfUtterance(text))
            case .followUp where !text.trimmingCharacters(in: .whitespaces).isEmpty:
                // The same as `.attending` above: words the VAD never
                // flagged still get the dangler check and the turn model,
                // not an ending on the endpointer's word alone.
                out.append(.cancelTimer(.followUp))
                out.append(.cancelTimer(.offerToClose))
                enterCapturing(.followUp, &out)
                out += handle(.endOfUtterance(text))
            default:
                break
            }

        case .turnVerdict(let complete, let stillMidClause, let evidence):
            guard case .capturing(let s) = state, s != .hold else { return }
            if let policy = tuning.endpoint, let evidence {
                // The wait, planned from the evidence; the reply's hold with it.
                let plan = policy.plan(evidence, onStall: askedOnStall)
                // A second "still going" over the same words is not news: the
                // ceiling the first one armed keeps running. Re-arming it
                // stretched 16 of the 105 six-second waits from 09-23 to
                // 09-29 with nothing new said (`audit-mic-open.md`).
                if plan.reason == .ceiling, silenceReason == .ceiling,
                   let armed = ceilingArmedOnWords, evidence.words <= armed {
                    return
                }
                ceilingArmedOnWords = plan.reason == .ceiling ? evidence.words : nil
                plannedHold = plan.hold
                if plan.decideIn <= 0 {
                    startDeciding(s, plan.reason, &out)
                } else if plan.reason == .verdictHold {
                    armEnding(.verdictHold, seconds: plan.decideIn, .verdictHold, &out)
                } else {
                    armEnding(.silence, seconds: plan.decideIn, plan.reason, &out)
                }
                return
            }
            if complete {
                if stillMidClause {
                    // The audio says done, the words say mid-phrase. Hold
                    // the door briefly: if speech resumes the hold is
                    // cancelled and the turn goes on; if not, the verdict
                    // stands a moment late.
                    armEnding(.verdictHold, seconds: tuning.verdictHoldSeconds, .verdictHold, &out)
                    return
                }
                startDeciding(s, askedOnStall ? .stall : .turnModel, &out)
            } else {
                // Mid-thought: hold the door, but not forever — and hold it
                // longer when the words agree with the audio. Measured on the
                // owner's log, 21 of 359 turns ended on this timer rather than
                // on a verdict, and two of those cut him off mid-clause:
                //
                //     p=0.01  "…let me think about this a second. Yeah, can you um"
                //     p=0.49  "…I want you to just spin off and"
                //
                // The first is the case for this: the model was as certain as
                // it gets that he was still going, he had just said out loud
                // that he was thinking, and a timer took the turn two seconds
                // later. Two signals saying "not finished" should not be
                // overruled on the same schedule as one.
                //
                // The ceiling is measured from the verdict and, unlike before,
                // a VAD onset does not cancel it — only words do.
                armEnding(.silence, seconds: stillMidClause
                          ? tuning.midClauseSilenceSeconds
                          : tuning.incompleteSilenceSeconds, .ceiling, &out)
            }

        case .transcribed(let turn, let text):
            if state == .suspended, let ticket = decidingBeforeSuspend, turn == ticket.turn {
                // Read back while a dictation had the microphone: kept for
                // when it comes back.
                decidingBeforeSuspend = nil
                transcriptDuringSuspend = Held(source: ticket.source, text: text)
                return
            }
            guard case .deciding(let s, let expected) = state, turn == expected else { return }
            deliverTranscript(text, from: s, &out)

        case .speechQueued:
            switch state {
            case .thinking(let s):
                // The reply is about to be heard: from here a voice over
                // it is an interruption, judged as one.
                continuationOpen = false
                state = .speaking(s)
            case .speaking:
                break
            case .off, .standby:
                asideReturn = nil
                state = .speaking(.aside)
            case .attending(let s):
                // A nudge while Moe waits for you: said, then back to waiting.
                out.append(.cancelTimer(.attend))
                asideReturn = .attending(s)
                state = .speaking(.aside)
            case .followUp:
                out.append(.cancelTimer(.followUp))
                out.append(.cancelTimer(.offerToClose))
                asideReturn = .followUp
                state = .speaking(.aside)
            case .capturing, .deciding, .suspended:
                // Nothing may talk over you. The host holds the audio.
                break
            }

        case .replyEndedWithQuestion(let asked):
            replyAskedQuestion = asked

        case .ttsDrained:
            guard case .speaking(let s) = state else { return }
            if s == .aside {
                switch asideReturn {
                case .attending(let back)?: asideReturn = nil; enterAttending(back, &out)
                case .followUp?: asideReturn = nil; enterFollowUp(&out)
                default: asideReturn = nil; close(&out)
                }
            } else if replyPending {
                state = .thinking(s)     // parked: more of the reply is coming
            } else {
                afterReply(s, &out)
            }

        case .replyContinues:
            guard let s = lastReplySource else { return }
            switch state {
            case .speaking(let playing) where playing != .aside:
                // The promise is still being said: carry on saying it, and
                // park in thinking when it runs out, as a reply mid-stream does.
                replyPending = true
                replyLive = true
            case .thinking:
                replyPending = true
                replyLive = true
            case .followUp:
                cancelSessionTimers(&out)
                replyPending = true
                replyLive = true
                bargeInSpent = false
                state = .thinking(.followUp)
            case .off, .standby:
                // The reply had been heard to its end and the session closed.
                replyPending = true
                replyLive = true
                bargeInSpent = false
                state = .thinking(s)
            default:
                // The person is already talking (attending, capturing,
                // deciding) or the microphone is away: theirs wins.
                break
            }

        case .brainFinished:
            guard replyPending else { return }
            replyPending = false
            switch state {
            case .thinking(let s):
                afterReply(s, &out)
            case .speaking:
                break                    // `.ttsDrained` closes it out
            case .suspended:
                sourceBeforeSuspend = nil
            default:
                break
            }

        case .suspend:
            guard state != .suspended else { return }
            out.append(.stopSpeaking)
            cancelSessionTimers(&out)
            out.append(.clearPartial)
            sessionOpenBeforeSuspend = inSession(state)
            asideReturn = nil
            transcriptDuringSuspend = nil
            forgetContinuation()
            // A dictation over an interrupted reply is as deliberate as the
            // key: that reply is over.
            let interrupted = interruptedSource
            if interruptedSource != nil {
                interruptedSource = nil
                dropReply(&out)
            }
            if case .deciding(let s, let turn) = state {
                // The turn is still being read back; keep its ticket —
                // for the session it interrupted, if it did: the reply
                // is gone now, so its words are a plain turn there.
                let owner: Source
                switch interrupted {
                case .aside?: owner = .hotkey
                case let i?: owner = i
                case nil: owner = s
                }
                decidingBeforeSuspend = Ticket(source: owner, turn: turn)
                replyPending = false
            } else {
                decidingBeforeSuspend = nil
            }
            sourceBeforeSuspend = replyPending ? currentSource : nil
            state = .suspended

        case .resume:
            guard state == .suspended else { return }
            let wasOpen = sessionOpenBeforeSuspend
            sessionOpenBeforeSuspend = false
            if replyPending, let s = sourceBeforeSuspend {
                sourceBeforeSuspend = nil
                state = .thinking(s)
            } else if let ticket = decidingBeforeSuspend {
                // Its transcript has not arrived yet: wait for it as before.
                decidingBeforeSuspend = nil
                state = .deciding(ticket.source, turn: ticket.turn)
            } else if let held = transcriptDuringSuspend {
                transcriptDuringSuspend = nil
                deliverTranscript(held.text, from: held.source, &out)
            } else {
                replyPending = false
                close(&out)
                if wasOpen { out.append(.conversationEnded) }
            }

        case .bargeInJudged(let forMoe):
            guard onsetPending, onsetJudging else { break }
            let marked = onsetMarkedReply
            clearOnset(&out)
            guard forMoe else {
                // Somebody else's conversation, or the room. The reply was
                // never stopped and the person Moe is talking to has not
                // noticed anything.
                if marked { interruptedSource = nil }
                out.append(.onsetRejected(.notForMoe))
                break
            }
            out.append(.onsetTaken(.judged))
            if case .thinking(let s) = state, s != .aside {
                // The audio ran out while the voice was being judged, and the
                // brain is still writing: nothing to pause, but the words are
                // an interruption of that reply all the same (review M6 —
                // they used to be dropped and the reply carried on).
                interruptedSource = s
                interruptedWhileThinking = true
                out.append(.clearPartial)
                enterCapturing(.followUp, wordsHeard: true, &out)
                break
            }
            guard case .speaking(let s) = state else {
                // The reply ran out while the voice was being judged: there
                // is nothing to pause, and the person is talking — into the
                // window, if there is one.
                if marked { interruptedSource = nil }
                if state == .followUp {
                    out.append(.cancelTimer(.followUp))
                    out.append(.cancelTimer(.offerToClose))
                    enterCapturing(.followUp, wordsHeard: true, &out)
                }
                break
            }
            // It is them. Pause — not stop — and let the words decide what
            // happens to the reply (`deliverTranscript`). Measured on
            // 2026-09-06: 7 of 11 barge-ins Moe took came back with no
            // words ("", "Yeah", not for Moe), and each one stopped the
            // reply and then re-said its sentence from the start. A pause
            // that turns out to be nothing resumes mid-word, which is what
            // a person does when somebody coughs.
            out.append(.pauseSpeech)
            interruptedSource = s
            // Not reset: the recogniser has been listening since the onset,
            // and what it has is the start of what they are saying.
            out.append(.clearPartial)
            enterCapturing(.followUp, wordsHeard: true, &out)

        case .timer(.bargeInHold):
            // The word window closed with no words: a fan, a dish, a cough,
            // the canceller's residue. Nothing was stopped, so nothing is
            // resumed — the reply comes back up (the duck is derived) and
            // the capture kept for it is let go.
            //
            // Deliberately *not* `bargeInSpent`: that flag exists so one
            // false interruption cannot become a loop, and there was no
            // interruption here. A room that blips all evening would
            // otherwise use up the person's ability to interrupt without
            // ever having interrupted anything.
            guard onsetPending, !onsetJudging else { break }
            if onsetContinuation, vadInSpeech {
                // Somebody may be going on with their own turn and has not
                // got to a word yet ("uhh…"). Nothing is held by waiting —
                // the brain keeps working, the reply plays when it comes —
                // so keep listening while the sound lasts.
                out.append(.armTimer(.bargeInHold, seconds: tuning.bargeInHoldSeconds))
                break
            }
            let marked = onsetMarkedReply
            out.append(.onsetRejected(.noWords))
            clearOnset(&out)
            if marked { interruptedSource = nil }

        case .timer(.continuationGrace):
            // Interruptions are off and the person has not gone on inside
            // the grace: from here the window takes no new voice. An onset
            // that began inside it still gets its words (`settleContinuation`
            // closes the window once it is decided).
            guard !tuning.bargeIn, continuationOpen else { return }
            switch state {
            case .deciding, .thinking: continuationGraceOver = true
            default: return
            }

        case .timer(.attend):
            guard case .attending = state else { return }
            close(&out)

        case .timer(.offerToClose):
            // Only in an untouched window: a turn in flight will re-arm it.
            // Never while muted: they cannot answer the offer.
            guard state == .followUp, !muted else { return }
            out.append(.offerToClose)

        case .timer(.followUp):
            guard state == .followUp else { return }
            if muted {
                // Muted, only the safety cap closes the window. An ordinary
                // clock armed before the mute is stale: ignore it.
                guard windowClockMuted else { return }
                out.append(.mutedWindowExpired)
            }
            out.append(.cue(.close))
            close(&out)

        case .timer(.verdictHold):
            guard case .capturing(let s) = state, s != .hold, verdictHoldArmed else { return }
            if deferForOnset(.verdictHold, &out) { return }
            startDeciding(s, .verdictHold, &out)

        case .timer(.silence):
            guard case .capturing(let s) = state, s != .hold else { return }
            // Armed either as an ending clock (with its reason) or as the
            // wait for the request after the name. Neither, and it is a
            // clock that words already cancelled.
            if silenceReason == nil, requestHeard { return }
            if silenceReason != nil, deferForOnset(.silence, &out) { return }
            startDeciding(s, silenceReason ?? .noSpeech, &out)

        case .timer(.turnCap):
            guard case .capturing(let s) = state, s != .hold else { return }
            startDeciding(s, .cap, &out)

        case .timer(.wordStall):
            // The words stopped a while ago and the turn is still open —
            // the VAD, in noise, may never report the pause. Ask the turn
            // model anyway, with the fallback under it. Not while an ending
            // clock already runs: that clock is the answer to this question
            // and a VAD onset can no longer cancel it.
            guard case .capturing(let s) = state, s != .hold, requestHeard, wordsInCapture,
                  silenceReason == nil, !verdictHoldArmed else { return }
            askedOnStall = true
            if tuning.turnModel { out.append(.askTurnModelOnStall) }
            armEnding(.silence, seconds: tuning.silenceFallbackSeconds, .stall, &out)

        case .timer(.noWords):
            // Sound, and not one word, for the whole of it: the room. No
            // read — reading noise is how "Acum z iszym" reached the brain —
            // and nothing submitted. Whatever the capture interrupted picks
            // up as though it had not happened.
            guard case .capturing(let s) = state, s != .hold, !wordsInCapture else { return }
            if tuning.readWordlessCaptures {
                // The streaming recogniser cannot write this language down,
                // so its silence proves nothing: let the accurate model read.
                startDeciding(s, .noWords, &out)
                return
            }
            cancelCaptureClocks(&out)
            out.append(.decided(.noWords))
            out.append(.resetAsr)
            deliverTranscript("", from: s, &out)
        }
    }

    // MARK: - Helpers

    private var currentSource: Source? {
        switch state {
        case .attending(let s), .capturing(let s), .thinking(let s), .speaking(let s): return s
        case .deciding(let s, _): return s
        case .followUp: return .followUp
        case .off, .standby, .suspended: return nil
        }
    }

    /// The reply in flight is over, whether or not the brain is still
    /// writing it. The host cuts the transcript where it was heard and
    /// tells the brain; it resets the brain only if it was still busy.
    private mutating func dropReply(_ out: inout [Action]) {
        lastReplySource = nil
        if replyLive { out.append(.abandonReply) }
        replyLive = false
        replyPending = false
    }

    /// The key went down: whatever was happening is over, this is a turn.
    /// `deferrable`: the press might turn out to be a tap, so the reply it
    /// stops is kept until what follows says whether it was a turn.
    private mutating func interruptForNewTurn(_ out: inout [Action], deferrable: Bool = false) {
        cancelSessionTimers(&out)
        // A reply that was only ducked for a sound nobody has put a word to
        // yet was never interrupted: the key meets it as a playing reply, so
        // a tap pauses it rather than destroying it (review M2).
        if onsetPending, onsetMarkedReply {
            interruptedSource = nil
            clearOnset(&out)
        }
        // A reply that was only paused by a barge-in is kept the same way a
        // playing one is: the key might be a tap, and a tap is the pause
        // button, never "throw the answer away". Real words on the release
        // drop it (`deliverTranscript`); a tap holds it (`.holdCancelled`).
        // From anything but the key (the hotkey, the name) the press is the
        // intent, and the reply is over at once, as it always was.
        keyFoundReplySilent = false
        if interruptedSource != nil {
            if deferrable {
                keyFoundReplySilent = interruptedWhileThinking
            } else {
                interruptedSource = nil
                dropReply(&out)
            }
        }
        switch state {
        case .speaking(.aside):
            out.append(.stopSpeaking)
            asideReturn = nil
            // A reply read out from rest — a typed turn's answer, or one
            // played again from its ▶ — is still something the person may
            // want to pause, and a tap is how they say so (2026-09-23: "in
            // the middle of talking back to you, you can pause it and then
            // resume it"). Kept like a reply's: a tap holds it, the next
            // tap lets it go on; real words drop it, as they always did.
            if deferrable { interruptedSource = .aside }
        case .speaking(let s):
            out.append(.stopSpeaking)
            // A held key is the one press that can turn out not to have been
            // one. A 29 ms brush against it cut a reply 139 characters in on
            // 2026-09-04, and the release then logged "a tap — nothing
            // recorded": Moe knew it was not speech only after it had already
            // destroyed the answer. So the sound stops at once — being talked
            // over is the complaint — but the reply is only marked, the same
            // shape as a barge-in: a real hold delivers words and
            // `deliverTranscript` drops it, a tap arrives as
            // `.holdCancelled` and puts it back.
            //
            // Not the hotkey and not the name. Neither can be a brush: a
            // toggle *is* the intent, and the wake head has already decided
            // it heard the name. Those still cut immediately.
            if deferrable {
                interruptedSource = s
            } else {
                dropReply(&out)
            }
        case .thinking(let s):
            // Deferred like a reply being spoken, for the same reason: the
            // press may be a tap. A hold that says something replaces the
            // turn; a tap leaves it — or, once some of it has been heard,
            // pauses it (`.holdCancelled`).
            if deferrable, s != .aside {
                if interruptedSource == nil { interruptedSource = s }
                keyFoundReplySilent = true
            } else {
                dropReply(&out)
            }
        case .deciding:
            replyPending = false     // its answer will arrive with a stale turn id
            replyLive = false
        default:
            break
        }
    }

    /// - Parameter awaitingSpeech: the capture began on something other
    ///   than the VAD hearing speech (a wake match): arm the no-speech
    ///   timeout, which the first `.speechStarted` cancels. Never on a
    ///   capture that *is* the speech starting — that timer would cut any
    ///   sentence longer than it.
    /// - Parameter wordsHeard: the capture opens on words the recogniser
    ///   has already written (a confirmed interruption, the turn going on):
    ///   no no-words clock, and the stall clock starts at once.
    private mutating func enterCapturing(_ s: Source, awaitingSpeech: Bool = false,
                                         wordsHeard: Bool = false, _ out: inout [Action]) {
        state = .capturing(s)
        ceilingArmedOnWords = nil
        continuationOpen = false
        resumedWhileDeciding = false
        requestHeard = !awaitingSpeech
        incompleteClockRunning = false
        wordsInCapture = wordsHeard
        silenceReason = nil
        verdictHoldArmed = false
        onsetInCapture = false
        clockDeferred = false
        askedOnStall = false
        plannedHold = nil
        if s != .hold {
            out.append(.armTimer(.turnCap, seconds: tuning.turnCapSeconds))
            if awaitingSpeech {
                out.append(.armTimer(.silence, seconds: tuning.noSpeechSeconds))
            } else if wordsHeard {
                out.append(.armTimer(.wordStall, seconds: tuning.wordStallSeconds))
            } else {
                out.append(.armTimer(.noWords, seconds: tuning.noWordsSeconds))
            }
        }
    }

    /// Arm a clock on the end of the turn, remembering why.
    private mutating func armEnding(_ kind: TimerKind, seconds: Double, _ reason: EndReason,
                                    _ out: inout [Action]) {
        switch kind {
        case .silence: silenceReason = reason
        case .verdictHold: verdictHoldArmed = true
        default: break
        }
        clockDeferred = false
        out.append(.armTimer(kind, seconds: seconds))
    }

    /// Words say the person went on: every clock on the turn's end stops.
    private mutating func cancelEnding(_ out: inout [Action]) {
        plannedHold = nil
        ceilingArmedOnWords = nil
        if silenceReason != nil { out.append(.cancelTimer(.silence)); silenceReason = nil }
        if verdictHoldArmed { out.append(.cancelTimer(.verdictHold)); verdictHoldArmed = false }
        clockDeferred = false
    }

    /// An ending clock fired just after a VAD onset whose words have not
    /// arrived: give the recogniser one short beat to catch up. Once per
    /// clock, so a room that keeps flapping cannot keep a turn open.
    private mutating func deferForOnset(_ kind: TimerKind, _ out: inout [Action]) -> Bool {
        guard onsetInCapture, !clockDeferred else { return false }
        clockDeferred = true
        onsetInCapture = false
        out.append(.armTimer(kind, seconds: tuning.onsetGraceSeconds))
        return true
    }

    private mutating func cancelCaptureClocks(_ out: inout [Action]) {
        out.append(.cancelTimer(.silence))
        out.append(.cancelTimer(.turnCap))
        out.append(.cancelTimer(.verdictHold))
        out.append(.cancelTimer(.wordStall))
        out.append(.cancelTimer(.noWords))
        silenceReason = nil
        verdictHoldArmed = false
        onsetInCapture = false
    }

    private mutating func startDeciding(_ s: Source, _ reason: EndReason, _ out: inout [Action]) {
        ceilingArmedOnWords = nil
        if s != .hold {
            cancelCaptureClocks(&out)
        }
        out.append(.decided(reason))
        if let hold = plannedHold {
            if hold > 0 { out.append(.holdReply(seconds: hold)) }
        } else if reason == .turnModel, tuning.replyFloorSeconds > 0 {
            out.append(.holdReply(seconds: tuning.replyFloorSeconds))
        }
        plannedHold = nil
        turnCounter += 1
        state = .deciding(s, turn: turnCounter)
        // The key's release says "done"; a pause only says "paused".
        continuationOpen = s != .hold
        continuationGraceOver = false
        ignoredLoggedThisReply = false
        if continuationOpen, !tuning.bargeIn {
            // Interruptions off: only the rest of this sentence may join it.
            out.append(.armTimer(.continuationGrace, seconds: tuning.continuationGraceSeconds))
        }
        out.append(.transcribe(turn: turnCounter))
    }

    /// Whether a voice starting now may be the turn going on. Always, while
    /// the window is open and interruptions are on; with them off, only
    /// inside the grace after the decision (`continuationGraceSeconds`).
    private var continuationTakesOnset: Bool {
        continuationOpen && (tuning.bargeIn || !continuationGraceOver)
    }

    /// With interruptions off, the window is shut once its grace is over
    /// and no onset that began inside it is still waiting on words, and no
    /// second half is being captured into a read still out. Derived after
    /// every event, like `settleOnset`, so no route can leave it open.
    private mutating func settleContinuation() {
        guard continuationGraceOver, continuationOpen, !tuning.bargeIn,
              !onsetPending, !resumedWhileDeciding else { return }
        continuationOpen = false
    }

    /// A voice (or the name) over Moe thinking or speaking, with
    /// interruptions off, was let be. Said once per reply.
    private mutating func noteIgnoredWithInterruptionsOff(byName: Bool, _ out: inout [Action]) {
        guard !tuning.bargeIn, !ignoredLoggedThisReply else { return }
        switch state {
        case .thinking(let s) where s != .aside: break
        case .speaking(let s) where s != .aside: break
        case .deciding(let s, _) where s != .hold && continuationGraceOver: break
        default: return
        }
        ignoredLoggedThisReply = true
        out.append(.ignoredInterruptionsOff(byName: byName))
    }

    private mutating func forgetContinuation() {
        continuationOpen = false
        resumedWhileDeciding = false
        continuationPrefix = nil
    }

    /// The accurate model has read the turn back.
    private mutating func deliverTranscript(_ text: String, from s: Source, _ out: inout [Action]) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(.clearPartial)
        if resumedWhileDeciding {
            // The person went on while this was being read. Nothing went to
            // the brain, so there is nothing to withdraw: keep the words as
            // the front of the turn and carry on capturing the rest.
            resumedWhileDeciding = false
            if let prefix = continuationPrefix { trimmed = Self.joined(prefix.text, trimmed) }
            continuationPrefix = trimmed.isEmpty ? nil : Prefix(text: trimmed, sentToBrain: false)
            enterCapturing(s, wordsHeard: true, &out)
            return
        }
        var s = s
        var continuing = false
        if let interrupted = interruptedSource {
            interruptedSource = nil
            if trimmed.isEmpty {
                // A false interruption: pick the reply up where it was
                // heard. Once per reply — a room that keeps tripping the
                // VAD must not keep stopping Moe. The key still can.
                //
                // Only when something *was* stopped. Over a thinking pause
                // nothing was playing and nothing paused, and spending the
                // flag there meant a cough during the wait cost the person
                // their real interruption of the reply that followed.
                if !interruptedWhileThinking { bargeInSpent = true }
                interruptedWhileThinking = false
                out.append(.resumeReply)
                state = replyPending ? .thinking(interrupted) : .speaking(interrupted)
                // A cough before the reply was heard: the reply goes on,
                // still unheard, so the turn may still go on too. A cough
                // over a reply that *was* playing reopens nothing.
                continuationOpen = continuationPrefix != nil
                continuationPrefix = nil
                return
            }
            // Real words: the old reply is over, this is the new turn —
            // in the session it interrupted, with that session's rules.
            dropReply(&out)
            // An aside has no session of its own. The key's hold keeps its
            // own rules (it was the only way over an aside before the tap
            // could pause one); anything else talks as the hotkey does.
            s = interrupted == .aside ? (s == .hold ? .hold : .hotkey) : interrupted
            continuing = continuationPrefix?.sentToBrain == true
        }
        if let prefix = continuationPrefix {
            // One turn, spoken in two halves.
            continuationPrefix = nil
            trimmed = Self.joined(prefix.text, trimmed)
        }
        if trimmed.isEmpty {
            switch s {
            case .hold:
                if windowOpen { enterFollowUp(&out) } else { close(&out) }
            case .followUp:
                enterFollowUp(afterNothing: true, &out)
            case .wake, .hotkey, .aside:
                // "Hey Moe" and then nothing yet: keep waiting for it.
                //
                // Reset the recogniser on the way. Every other route out of
                // a turn does, and this one did not — so the abandoned
                // attempt stayed in the streaming decoder's caches and the
                // next utterance arrived with it glued to the front, which
                // is what `.resetAsr` exists to prevent. `.asr(false)` on
                // the way through is not a reset: it stops frames being
                // fed, and keeps every one already accumulated.
                out.append(.resetAsr)
                enterAttending(s, &out)
            }
            return
        }
        replyPending = true
        replyLive = true
        bargeInSpent = false
        state = .thinking(s)
        lastReplySource = s
        lastSubmitted = trimmed
        out.append(continuing ? .submitContinuation(trimmed) : .submit(trimmed))
    }

    /// Two halves of one turn, one space between them.
    private static func joined(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Words it takes for the pending onset to take the floor.
    private func wordsToTakeTheFloor(urgent: Bool) -> Int {
        if case .speaking = state, onsetMarkedReply, !onsetContinuation, !urgent {
            return max(1, tuning.interruptionWordsWhileSpeaking)
        }

        return max(1, tuning.interruptionWords)
    }

    /// Something speech-shaped began over the playing reply — a VAD edge,
    /// or a voice rising over the echo: mark the reply and wait on words.
    private mutating func onsetOverTheReply(_ s: Source, _ out: inout [Action]) {
        interruptedSource = s
        interruptedWhileThinking = false
        beginOnset(resetRecogniser: true, &out)
        onsetMarkedReply = true
    }

    /// A VAD onset over a reply on its way: wait on words for it.
    private mutating func beginOnset(resetRecogniser: Bool, _ out: inout [Action]) {
        // A second onset inside the window does not extend it: a room that
        // flaps must not be able to hold the reply open by flapping.
        guard !onsetPending else { return }
        onsetPending = true
        onsetMarkedReply = false
        onsetJudging = false
        onsetContinuation = false
        onsetExtended = false
        onsetHeardWord = false
        onsetFromRise = false
        if resetRecogniser {
            // The recogniser was off, or holds the last turn: the words that
            // count are the ones from now.
            out.append(.resetAsr)
        }
        out.append(.armTimer(.bargeInHold, seconds: tuning.bargeInHoldSeconds))
    }

    private mutating func clearOnset(_ out: inout [Action]) {
        guard onsetPending else { return }
        onsetPending = false
        onsetJudging = false
        onsetMarkedReply = false
        onsetContinuation = false
        onsetHeardWord = false
        onsetFromRise = false
        out.append(.cancelTimer(.bargeInHold))
    }

    /// Words arrived inside the word window: somebody is talking. What that
    /// means depends on where the reply is *now* — it may have started
    /// playing, or finished, since the onset.
    private mutating func confirmOnset(_ out: inout [Action]) {
        switch state {
        case .speaking(let s) where s != .aside && tuning.bargeIn && !bargeInSpent:
            // Words over the reply. Still ducked, not stopped: everything
            // cheap that could say whose voice it is — how loud against the
            // room, whether it is Moe's own reply coming back — is on the
            // host side, so ask it. The machine does not guess.
            guard !onsetJudging else { return }
            onsetJudging = true
            if interruptedSource == nil { interruptedSource = s; onsetMarkedReply = true }
            out.append(.cancelTimer(.bargeInHold))
            out.append(.judgeBargeIn)
        case .thinking(let s) where continuationOpen && s != .aside && s != .hold:
            // Nothing of the reply has been heard, so these words are not a
            // reaction to it: the person paused and went on. They are
            // *joined* to what was sent and the brain's half-answer is
            // withdrawn, rather than becoming a new turn that amends it.
            clearOnset(&out)
            out.append(.onsetTaken(.continuation))
            interruptedSource = s
            interruptedWhileThinking = true
            continuationPrefix = Prefix(text: lastSubmitted, sentToBrain: true)
            enterCapturing(s, wordsHeard: true, &out)
        case .thinking(let s) where s != .aside && tuning.bargeIn && !bargeInSpent:
            // Real words while Moe works on the last question: they will
            // abandon it, once the read says what they were.
            clearOnset(&out)
            out.append(.onsetTaken(.overThinking))
            if interruptedSource == nil { interruptedSource = s }
            interruptedWhileThinking = true
            out.append(.clearPartial)
            enterCapturing(.followUp, wordsHeard: true, &out)
        case .deciding(let s, _) where continuationOpen && s != .hold:
            // The read of the first half is still out. When it lands it is
            // kept as the front of this turn, and the capture — which never
            // closed — goes on with the second half.
            clearOnset(&out)
            out.append(.onsetTaken(.continuation))
            resumedWhileDeciding = true
        case .followUp:
            // The reply finished while the words were arriving: they are a
            // turn in the window.
            clearOnset(&out)
            out.append(.onsetTaken(.intoWindow))
            out.append(.cancelTimer(.followUp))
            out.append(.cancelTimer(.offerToClose))
            enterCapturing(.followUp, wordsHeard: true, &out)
        default:
            clearOnset(&out)
        }
    }

    /// A pending onset cannot outlive the places it can be pending in.
    /// Run after every event, so no transition — a key, the name, a
    /// dictation, the reply finishing — can leave the reply ducked or the
    /// recogniser listening for a question nobody is waiting on.
    private mutating func settleOnset(_ out: inout [Action]) {
        guard onsetPending else { return }
        switch state {
        case .speaking(let s) where s != .aside && tuning.bargeIn && !bargeInSpent:
            return
        case .thinking, .deciding, .followUp:
            // Over the reply's own states, and the window it finished into.
            // A mark on a reply that is no longer playing is stale.
            if onsetMarkedReply, state == .followUp {
                onsetMarkedReply = false
                interruptedSource = nil
            }
            return
        default:
            // Anywhere else — a key, the name, a dictation, a close, or a
            // reply that started playing with barge-in off.
            let marked = onsetMarkedReply
            clearOnset(&out)
            guard marked else { return }
            switch state {
            case .capturing(.hold):
                // The key: `interruptForNewTurn` has already decided what
                // the reply is now (held for a possible tap). Leave it.
                break
            default:
                interruptedSource = nil
            }
        }
    }

    private mutating func enterAttending(_ s: Source, _ out: inout [Action]) {
        forgetContinuation()
        state = .attending(s)
        out.append(.armTimer(.attend, seconds: tuning.attendSeconds))
    }

    /// - Parameter afterNothing: the window is being re-entered after a
    ///   capture in it came to nothing — it gets a short extension, and
    ///   closes after `Tuning.followUpNothingLimit` of those in a row.
    private mutating func enterFollowUp(afterNothing: Bool = false, _ out: inout [Action]) {
        forgetContinuation()
        windowNothings = afterNothing ? windowNothings + 1 : 0
        if afterNothing, !muted, windowNothings > tuning.followUpNothingLimit {
            windowNothings = 0
            out.append(.cue(.close))
            close(&out)
            return
        }
        windowOpen = true
        state = .followUp
        out.append(.resetAsr)
        windowClockMuted = muted
        if muted {
            // Muted: the window waits for them — it does not time out under
            // somebody who cannot be heard (`Tuning.mutedWindowSeconds`).
            out.append(.armTimer(.followUp, seconds: tuning.mutedWindowSeconds))
            out.append(.cancelTimer(.offerToClose))
            return
        }
        let asked = replyAskedQuestion
        replyAskedQuestion = false
        let seconds = afterNothing ? min(tuning.followUpAfterNothingSeconds, tuning.followUpSeconds)
                    : asked ? max(tuning.followUpSeconds, tuning.followUpAfterQuestionSeconds)
                    : tuning.followUpSeconds
        out.append(.armTimer(.followUp, seconds: seconds))
        if afterNothing { return }
        if tuning.offerToCloseAfter > 0, tuning.offerToCloseAfter < seconds {
            out.append(.armTimer(.offerToClose, seconds: tuning.offerToCloseAfter))
        }
    }

    /// The reply has been heard to its end. This is the moment the 8 s
    /// clock starts — not when the text finished arriving.
    private mutating func afterReply(_ s: Source, _ out: inout [Action]) {
        replyLive = false
        let opensWindow: Bool
        switch s {
        case .followUp: opensWindow = true
        case .hold: opensWindow = tuning.holdOpensConversation
        case .hotkey, .wake: opensWindow = tuning.conversation
        case .aside: opensWindow = false
        }
        if opensWindow || windowOpen {
            // A mute stays on (the owner, 2026-09-24 — it used to end here,
            // and was switched off under them six times in half an hour).
            // What the 2026-09-23 fix protected still holds another way: a
            // muted window does not time out under them (`enterFollowUp`).
            enterFollowUp(&out)
        } else {
            close(&out)
        }
    }

    private mutating func cancelSessionTimers(_ out: inout [Action]) {
        switch state {
        case .attending: out.append(.cancelTimer(.attend))
        case .followUp:
            out.append(.cancelTimer(.followUp))
            out.append(.cancelTimer(.offerToClose))
        case .capturing(let s) where s != .hold:
            cancelCaptureClocks(&out)
        default: break
        }
    }

    private mutating func close(_ out: inout [Action]) {
        cancelSessionTimers(&out)
        forgetContinuation()
        windowOpen = false
        asideReturn = nil
        interruptedSource = nil
        bargeInSpent = false
        onsetPending = false
        replyLive = false
        state = wakeEnabled ? .standby : .off
    }
}
