import Foundation

// What a meeting knows about itself while it runs, and what it must keep
// when the result does not look like a meeting. All pure — the levels
// arrive as numbers, the rule takes a line count and a duration — so the
// parts that decide whether evidence survives are unit-tested.

// MARK: - Levels, in numbers

/// The periodic "here is what the two channels actually measured" line.
///
/// `ChannelHealth` answers a boolean — "mic silent" — and the first real
/// meeting proved that is not enough: the log said the microphone was
/// silent and the transcript had one line in 95 seconds, and nothing said
/// whether the mic was at -52 dBFS (quiet speech the speech gate threw
/// away) or at -200 (a device delivering nothing). Those are different
/// bugs with different fixes. The number is the diagnosis.
///
/// The loudest reading in each interval is what is reported, not the mean:
/// a channel that carried speech at any point in fifteen seconds did carry
/// speech, and an average over mostly-silence hides it.
public struct LevelLog: Equatable, Sendable {
    public var interval: Double
    private var windowStart: Double = 0
    private var micLoudest: Float = -.infinity
    private var systemLoudest: Float = -.infinity
    private var started = false

    public init(interval: Double = 15) { self.interval = interval }

    /// Feed one reading (dBFS rms since the last one). Returns the line to
    /// log when the interval is up, else nil.
    public mutating func observe(micDb: Float, systemDb: Float, at t: Double) -> String? {
        if !started { started = true; windowStart = t }
        if micDb.isFinite { micLoudest = Swift.max(micLoudest, micDb) }
        if systemDb.isFinite { systemLoudest = Swift.max(systemLoudest, systemDb) }
        guard t - windowStart >= interval else { return nil }
        let line = Self.line(micDb: micLoudest, systemDb: systemLoudest, at: t)
        windowStart = t
        micLoudest = -.infinity
        systemLoudest = -.infinity
        return line
    }

    /// `levels mic -52 dBFS, system -∞ at 00:15 (loudest in 15 s)`
    public static func line(micDb: Float, systemDb: Float, at t: Double, interval: Double = 15) -> String {
        "levels mic \(dbfs(micDb)), system \(dbfs(systemDb)) at \(Timeline.clock(t))"
            + " (loudest in \(Int(interval.rounded())) s)"
    }

    /// A reading rounded to whole decibels. The meter says -200 dBFS when
    /// nothing at all was written to it, which is not a level — it is the
    /// absence of one, and it must not read like a quiet room.
    public static func dbfs(_ db: Float) -> String {
        guard db.isFinite, db > -199 else { return "-∞" }
        return "\(Int(db.rounded())) dBFS"
    }
}

// MARK: - Is the channel we are recording the microphone?

/// Turns the per-channel measurement into at most two log lines per meeting:
/// the table, once the echo canceller has settled, and a verdict, late
/// enough to be worth reading.
///
/// The verdict is deliberately hard to trigger. A room where nobody is
/// speaking puts every channel near the floor together, and a warning there
/// would be crying wolf at the commonest case there is — the measured quiet
/// room in `2026-08-30-1611` sat at -65 dBFS for thirty-seven seconds and
/// was, as far as anything can tell, correctly captured. So the warning
/// needs *positive* evidence: either another channel carrying real audio
/// while this one carries none (`ChannelReport.warning`), or a level below
/// anything a live microphone produces at all (`liveMicFloorDb`, -80 dBFS,
/// fifteen decibels under that quiet room). Silence on its own says nothing
/// and is left to `ChannelHealth`.
public struct MicChannelWatch: Sendable {
    /// When the table is logged. After the canceller has converged — the
    /// mic's first second carries the far end at full level until it does.
    public var tableAt: Double
    /// When the verdict is logged. Twenty seconds: long enough that a pause
    /// between sentences cannot be read as a dead channel.
    public var verdictAt: Double
    private var loggedTable = false
    private var loggedVerdict = false

    public init(tableAt: Double = 3, verdictAt: Double = 20) {
        self.tableAt = tableAt
        self.verdictAt = verdictAt
    }

    public mutating func observe(_ report: ChannelReport?, at t: Double) -> [String] {
        guard let report else { return [] }
        var out: [String] = []
        if !loggedTable, t >= tableAt {
            loggedTable = true
            out.append(report.line)
        }
        if !loggedVerdict, t >= verdictAt {
            loggedVerdict = true
            if let warning = report.warning {
                out.append("WARNING \(warning)")
            } else if report.implausiblyQuiet, let chosen = report.chosen, chosen < report.db.count {
                out.append("WARNING channel \(chosen) has averaged "
                           + "\(LevelLog.dbfs(report.db[chosen])) for \(Int(t.rounded())) s, below "
                           + "anything a live microphone produces even in a silent room "
                           + "(\(LevelLog.dbfs(ChannelReport.liveMicFloorDb))) — this is a device "
                           + "delivering nothing, not a quiet room")
            }
        }
        return out
    }
}

// MARK: - What the levels say once the meeting is over

/// What the meters saw of each stream across a whole meeting: how long each
/// one spent above the noise floor. It answers one question — **did this
/// stream carry audio?** — and it stores the seconds rather than the answer,
/// because the bar those seconds are judged against depends on how long the
/// meeting was (`carriedAudioSeconds`).
///
/// It exists because line counts cannot answer it. A meeting where one side
/// transcribed and the other produced nothing is the shape a dead or
/// misrouted channel makes — and it is also exactly what a webinar looks
/// like, where the user listened and said nothing. The transcript is
/// identical in both. The levels are not: in the first, real audio reached
/// the recorder and nothing came out of it, and the recording is the only
/// evidence of that failure; in the second the channel was genuinely quiet
/// and the recording is a pile of other people's voices held against an
/// explicit instruction to delete it.
///
/// Absent (`nil` at the call site) means *not measured* — an older meeting,
/// a crash, a path that never collected levels — and then the decision
/// falls back to the line-rate rule alone. Missing data must never read as
/// "keep", or every meeting keeps its audio.
public struct ChannelEvidence: Equatable, Sendable {
    /// Seconds the microphone spent above the floor, over the whole meeting.
    public var micSoundSeconds: Double
    /// The same for the system tap.
    public var systemSoundSeconds: Double
    /// The microphone's audio arrived, but on a channel of the bus other
    /// than the one being recorded. That counts as carried however few
    /// seconds the meters saw, because the meters were watching the wrong
    /// channel.
    public var micMisrouted: Bool

    /// How long a stream must have spent above the floor before "it carried
    /// audio" is worth anything: **a twentieth of the meeting, and never
    /// less than 15 seconds.**
    ///
    /// Proportional, because the two populations it has to separate both
    /// scale with the length of the meeting, and they are an order of
    /// magnitude apart.
    ///
    /// The one worth keeping: a dead or misrouted microphone only *cost*
    /// the user something if they spoke into it. If they said nothing,
    /// nothing was lost and there is no failure to preserve evidence of.
    /// Anyone who did speak carries far more than a few seconds — a light
    /// participant's share of a ten-minute call is tens of seconds, an
    /// ordinary one's is minutes. 5% is 30 s of a ten-minute meeting and
    /// 90 s at the 30-minute ceiling, under what even a quiet participant
    /// produces.
    ///
    /// The one that must not fire: incidental noise from somebody who is
    /// listening. A cough, a chair, a door — and typing, which is the one
    /// that matters, because a note-taker types through much of a call and
    /// keyboard noise at a laptop microphone runs well above -50 dBFS. A
    /// flat threshold of a few seconds sits at the *bottom* of that
    /// population rather than above it: three cumulative seconds of typing
    /// across twenty minutes is not a stretch, it is likely, and it would
    /// keep a webinar's recording against an explicit delete setting for no
    /// reason at all. Requiring the sound to fill a twentieth of the whole
    /// meeting is what puts the bar above that.
    ///
    /// The 15 s floor is for short meetings, where 5% is a handful of
    /// seconds and two coughs would decide it. It is also comfortably under
    /// the one real failure on record: 95 seconds of continuous talking,
    /// one transcript line.
    ///
    /// **These numbers are reasoned, not measured.** Nobody has recorded
    /// what a listener's microphone does under voice processing over twenty
    /// minutes: VPIO's noise suppression may push typing below -50 dBFS
    /// entirely, in which case the bar could come down a long way, or it
    /// may not touch it. One live check settles it, and it needs no
    /// microphone experiment beyond an ordinary call — **sit in a call
    /// saying nothing, type throughout, end the meeting, and read the
    /// `levels carried` line from the log** (`MeetingSession.finish` writes
    /// the two numbers and this bar). If a silent typist's microphone comes
    /// in well under 5%, this can drop; if it comes in over, then level
    /// alone cannot decide this and the rule needs another signal.
    public static func carriedAudioSeconds(duration: Double) -> Double {
        max(minimumCarriedSeconds, carriedFraction * duration)
    }

    /// The share of the meeting, and the floor under it.
    public static let carriedFraction: Double = 0.05
    public static let minimumCarriedSeconds: Double = 15

    /// Did the microphone carry audio, judged against a meeting this long?
    public func micCarriedAudio(over duration: Double) -> Bool {
        micMisrouted || micSoundSeconds >= Self.carriedAudioSeconds(duration: duration)
    }

    public func systemCarriedAudio(over duration: Double) -> Bool {
        systemSoundSeconds >= Self.carriedAudioSeconds(duration: duration)
    }

    public init(micSoundSeconds: Double, systemSoundSeconds: Double, micMisrouted: Bool = false) {
        self.micSoundSeconds = micSoundSeconds
        self.systemSoundSeconds = systemSoundSeconds
        self.micMisrouted = micMisrouted
    }

    /// From what a running meeting already measures: `ChannelHealth`, fed
    /// ten times a second from the recorder's meters, and the per-channel
    /// report from the microphone's raw bus.
    ///
    /// **The floor is `ChannelHealth.soundDb`, -50 dBFS**, and it is
    /// deliberately the number already in this module rather than a new
    /// one. It is the speech gate's absolute floor
    /// (`Windowing.absoluteFloorDb`) to the decibel: the level the one
    /// microphone we have measurements for hovered at while it was working,
    /// ~15 dB under ordinary speech at a laptop (-20…-35), and the level
    /// below which a laptop input is indistinguishable from its own noise.
    /// A stream that never reached it carried nothing a recogniser could
    /// have read, so its empty transcript is the truth and its recording is
    /// evidence of nothing.
    ///
    /// The gate's *other* half — 12 dB of contrast with the window's own
    /// noise floor — is deliberately not applied here. That one asks
    /// whether a particular 30 s window contains speech; this asks whether
    /// a device delivered anything at all over a whole meeting, and there
    /// is no enclosing window to measure the contrast against.
    ///
    /// `micChannels` adds the one case the meters cannot see. When the
    /// microphone's audio arrived on a bus channel other than the one being
    /// recorded (`ChannelReport.warning`: some other channel at -55 dBFS or
    /// louder and 10 dB above the recorded one), mic.wav is near-silent
    /// because it was written from the wrong channel — real audio, lost on
    /// the way to the file, and precisely the misrouted case. Its opposite,
    /// `implausiblyQuiet`, is not counted: a channel below -80 dBFS is a
    /// device delivering nothing, and there is nothing in that recording to
    /// diagnose from.
    public init(health: ChannelHealth, micChannels: ChannelReport? = nil) {
        micSoundSeconds = health.micSoundSeconds
        systemSoundSeconds = health.systemSoundSeconds
        micMisrouted = micChannels?.warning != nil
    }

    /// The two numbers for the log at the end of a meeting — and the only
    /// way to check `carriedAudioSeconds` against a real call.
    public func line(duration: Double) -> String {
        String(format: "levels carried mic %.1f s, system %.1f s of %.0f s (bar %.0f s)%@",
               micSoundSeconds, systemSoundSeconds, duration,
               Self.carriedAudioSeconds(duration: duration),
               micMisrouted ? "; the mic's audio was on another channel of the bus" : "")
    }
}
