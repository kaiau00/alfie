import Foundation

/// Whether the call-audio tap is carrying sound, and what to do when it is
/// not.
///
/// On 2026-09-08 two of three meetings recorded a `system.wav` that was
/// digitally silent for its whole length — 59,153,310 frames of exact zeros
/// on the 61-minute one — while `mic.wav` beside it held the entire call at
/// −27 dBFS. Every word anyone said arrived through the microphone and was
/// written down as `you`. The transcript said 551 lines, none of them
/// `them`, and the notes, the speaker labels and the to-do list were all
/// wrong downstream of that.
///
/// Three recordings from that day:
///
/// | meeting | echo cancellation | system stream carried |
/// |---|---|---|
/// | 10:20, 35:25 | on throughout    | 1.2 s of 2,126 s |
/// | 14:00, 80:40 | off from 0:10    | 4,094.5 s of 4,841 s |
/// | 16:10, 61:40 | on throughout    | 0.0 s of 3,701 s |
///
/// The two that failed had echo cancellation on and the one that worked had
/// it dropped ten seconds in, which is a tidy story and **it is not the
/// cause**. Running the A/B directly on the same Mac — `MeetingTap record`
/// with `MEETINGTAP_AEC` on and off, over a tone playing from another
/// process — the tap carried the tone *both* times, at −40 dBFS with voice
/// processing on and −32 with it off. Voice processing costs the system
/// stream about eight decibels here. It does not kill it.
///
/// So the cause of those two meetings is **not known**, and this type does
/// not claim to know it. What it does is notice, repair what can be
/// repaired, and say so when nothing can — none of which needs the cause.
/// The one hard clue on the record is in the 16:10 log, where
/// `audio: device configuration changed` lands in the same second the tap
/// was created: an aggregate device built on a default output device that
/// moved underneath it. Dropping echo cancellation is still tried first
/// because it is cheap, reversible, and the one difference between the
/// meeting that worked and the two that did not.
///
/// Nothing in the app could see any of it. `MeetingRecorder.tapIsDelivering`
/// counts buffers, and a dead tap keeps delivering them — full of zeros —
/// so the eight-second check built on it reported a healthy tap through an
/// hour of silence. It is a check that cannot fail.
///
/// # What counts as evidence
///
/// Silence on the system stream is not, by itself, a fault: nobody on the
/// far end may be talking, and an in-person meeting has no call audio at
/// all. The falsifier has to be positive — **something else is playing
/// audio and the call stream is not carrying it**. Core Audio answers the
/// first half (`kAudioProcessPropertyIsRunningOutput`, already read every
/// 1.2 s by `ProcessList.Signals`); `ChannelHealth` answers the second. An
/// in-person meeting never trips it, because nothing is playing.
///
/// Two grades of evidence, because they deserve different answers:
///
///   * **Quiet for a while** (`systemQuiet`) is enough to try the repairs.
///     They cost a rebuilt microphone and two ~100 ms gaps that are padded
///     back, so doing them for nothing is close to free — and this is the
///     grade the 10:20 meeting was, with 1.2 s of sound in 2,126.
///   * **Never carried one non-zero sample** (`systemEverSounded` false) is
///     the only grade that may interrupt the user. A live tap on a Mac with
///     something playing produces *some* value, always; 59 million exact
///     zeros is not a quiet call, and it cannot be confused with one. That
///     is the 16:10 meeting.
///
/// The split matters. A webinar where the user talks for a minute while the
/// far end says nothing looks exactly like the first grade and nothing like
/// the second, so it gets the free repairs and never the notice.
///
/// # What to do about it
///
/// In order, each given `deadSeconds` to prove itself before the next:
///
///  1. **Drop echo cancellation.** The measured cause, and the cheapest
///     fix — it costs the mic hearing the speakers, which the timeline
///     already tolerates and which `Timeline.withoutEcho` exists for. Only
///     offered while voice processing is actually on.
///  2. **Rebuild the tap.** For the other documented death: a tap that has
///     delivered real audio and then goes to all-zeros mid-session. Both
///     the process tap *and* the aggregate device have to be destroyed and
///     recreated — recreating either alone does not restore it.
///  3. **Say so.** Two failures to recover is not a transient, and an hour
///     of recording one side of a conversation without saying anything is
///     how this cost a whole meeting. `MeetingSession` logged "no meeting
///     audio at 00:20" and then recorded for another sixty-one minutes.
public struct TapWatch: Equatable, Sendable {

    /// What the caller should do now.
    public enum Action: Equatable, Sendable {
        case none
        /// Restart the microphone with voice processing off.
        case dropEchoCancellation
        /// Destroy and recreate the tap and its aggregate device.
        case rebuildTap
        /// Both were tried and the stream is still silent: tell the user.
        case reportDead
    }

    /// How long something must be playing with nothing captured before the
    /// stream is judged dead.
    ///
    /// Long enough that a far end which happens to be muted across a poll
    /// or two is not a fault, short enough that the fix lands inside the
    /// first minute of a call rather than after it. The one real instance
    /// was diagnosable at twenty seconds.
    public var deadSeconds: Double = 15

    /// How many times the tap may be rebuilt in one meeting. A rebuild that
    /// did not work twice will not work a third time, and each one is a gap
    /// in the recording.
    public var maxRebuilds = 2

    private var silentSince: Double?
    private var triedEchoCancellation = false
    private var rebuilds = 0
    private var reported = false
    /// Set once the stream has carried sound at all, so a call that goes
    /// quiet after ten good minutes is never mistaken for a dead tap.
    private(set) public var everHeardSomething = false

    public init() {}

    /// One poll.
    ///
    /// - `systemQuiet`: the system stream has not carried sound above the
    ///   floor recently (`ChannelHealth.systemSilent`).
    /// - `systemEverSounded`: it has carried one non-zero sample at some
    ///   point since the tap was built. Not "buffers arrived" — a dead tap
    ///   delivers those too.
    /// - `somethingIsPlaying`: some process other than Moe has an output
    ///   stream running right now.
    /// - `echoCancelling`: voice processing is on in this process.
    /// - `micHasSpeech`: the microphone has carried speech in this meeting.
    ///   Gates only the notice: a room where nobody has said anything yet
    ///   has nothing to misattribute, so there is nothing to warn about.
    /// - `t`: meeting seconds.
    public mutating func observe(systemQuiet: Bool, systemEverSounded: Bool,
                                 somethingIsPlaying: Bool, echoCancelling: Bool,
                                 micHasSpeech: Bool = true, at t: Double) -> Action {
        if systemEverSounded { everHeardSomething = true }
        if !systemQuiet {
            silentSince = nil
            return .none
        }
        // Nothing is playing, so nothing is missing. This is the in-person
        // meeting, and the pause between two people talking.
        guard somethingIsPlaying else {
            silentSince = nil
            return .none
        }
        guard let since = silentSince else {
            silentSince = t
            return .none
        }
        guard t - since >= deadSeconds else { return .none }
        // Each action gets its own window to prove itself.
        silentSince = t
        if echoCancelling, !triedEchoCancellation {
            triedEchoCancellation = true
            return .dropEchoCancellation
        }
        if rebuilds < maxRebuilds {
            rebuilds += 1
            return .rebuildTap
        }
        // Only the hard grade may interrupt. A stream that has carried
        // sound at some point is a call that has gone quiet, however long
        // for — and telling someone their meeting is being mis-recorded
        // when it is not is worse than saying nothing.
        guard !reported, micHasSpeech, !systemEverSounded else { return .none }
        reported = true
        return .reportDead
    }

    /// The tap was rebuilt: the "has it carried sound" flag starts again
    /// from the new tap, so the caller resets its meter too.
    public var rebuildCount: Int { rebuilds }
    /// Whether the user has already been told. For the tests and the panel.
    public var hasReported: Bool { reported }

    // MARK: - What the user is told

    /// The line the island shows when nothing could bring the stream back.
    ///
    /// Three things it has to be, and the old health line — "no meeting
    /// audio", grey, in a row shared with four other messages — was none of
    /// them.
    ///
    /// **True in both cases it can fire in.** This cannot always know
    /// whether there is a call at all: an in-person meeting has no call
    /// audio, correctly, and reads from here exactly like a tap that has
    /// died. So the sentence states what was measured — no call audio has
    /// arrived — and puts the consequence behind an "if".
    ///
    /// **About the consequence, not the mechanism.** Which aggregate device
    /// failed is not the user's problem; every voice in the room being
    /// filed under their name is.
    ///
    /// **Worth interrupting for.** It costs a meeting, and it is still
    /// fixable while the meeting is running.
    public static let deadNotice =
        "No call audio is reaching Alfie. If you are on a call, only your microphone "
        + "is being recorded — everyone on it will be written down as you."

    /// What to do about it, for the notice's second line.
    public static let deadRemedy =
        "Alfie may need System Audio Recording in Privacy & Security."
}

// MARK: - Is anything playing at all?

/// Whether some process other than Moe has an output stream running.
///
/// The other half of `TapWatch`'s evidence, and the half that keeps it
/// honest: a silent system stream is only suspicious when there is
/// something for it to have missed. Read from the same cached Core Audio
/// signals the call detector already polls (`ProcessList.Signals`), so it
/// costs nothing extra.
///
/// It answers "has an output IO running", not "is making a sound" — Core
/// Audio has no property for the second — so a process holding an idle
/// output stream reads as playing. That is why the two repairs it gates are
/// both cheap and safe to do for nothing, and why the notice needs a second
/// condition on top of it.
public enum OutputActivity {

    /// Pure form. `mine` is ignored **exactly**, and only exactly — not
    /// with its helpers folded in the way `CallApps.match` folds Chrome's.
    ///
    /// The exclusion here has one job: mirror the tap's. The tap excludes
    /// one process object, this process, so anything else Moe ships that
    /// plays audio in a process of its own *is* captured by it and its
    /// silence is as much evidence as anyone else's. Folding helpers in
    /// would also swallow Moe Dev, whose bundle id is `com.memoe.app`
    /// plus a suffix and which is a different application entirely.
    public static func othersPlaying(_ signals: [CallSignal], mine: String) -> Bool {
        signals.contains { $0.output && ($0.bundleID != mine || mine.isEmpty) }
    }

    /// The same against Core Audio right now. False when the process list
    /// cannot be read, which is the safe answer: it can only ever suppress
    /// a repair, never cause one.
    public static func othersPlaying(mine: String = Bundle.main.bundleIdentifier ?? "") -> Bool {
        othersPlaying(ProcessList.Signals.current(), mine: mine)
    }
}
