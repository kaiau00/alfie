import Foundation

/// What a near-silent turn is allowed to become, and when Moe trusts the
/// owner check and the name. Every number here is from the owner's own logs
/// (`VOICE-DEEP-DIVE-2026-10-06.md`); each rule names the incident it ends.
public enum QuietTurnPolicy {

    /// Below this a turn's RMS is the room, not a voice. Owner speech sits at
    /// 0.054–0.076 median per day; below 0.01 median read confidence was 0.48
    /// and 68% of reads were under 0.7 (n=68).
    public static let silentLevel: Float = 0.01

    /// Below this, a read is only believed if the recogniser is sure.
    public static let inventedLevel: Float = 0.005
    public static let inventedConfidence: Float = 0.85

    /// A read of near-silence that the recogniser was not sure of is an
    /// invention. 11 of 16 texts read out of level < 0.005 were: "Thank
    /// you" ×3, "jedna" ×2 (one reached the brain, 09-30 23:45:36), "Okay",
    /// "Yeah" ×2, "No", "Hmm", a Hebrew sentence — at confidence 0.20–0.83.
    /// The real quiet reads in the same band were 0.85–0.97. Was wake-only;
    /// the inventions came through follow-up windows too.
    public static func isInvented(text: String, confidence: Float?, level: Float) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard level < inventedLevel else { return false }
        return (confidence ?? 0) < inventedConfidence
    }

    /// An accurate read that came back empty and unsure does not get to erase
    /// a sentence the live recogniser wrote down from a real voice.
    ///
    /// 09-24 17:15:22: live had "let's keep going and other things in the
    /// meantime"; the re-read took 10.1 s, answered "" at confidence 0.10,
    /// and the empty answer won — the owner said it again 31 s later. The
    /// rule that an empty read stands is right for silence (it is how a door
    /// stopped becoming a sentence), so this needs all three: a real level,
    /// several live words, and a read that says itself it is guessing.
    public static func liveWordsOutrankEmptyRead(read: String, readConfidence: Float?,
                                                 live: String, level: Float) -> Bool {
        guard read.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard level >= silentLevel else { return false }
        guard let c = readConfidence, c < 0.3 else { return false }
        return TurnPolicy.words(live).count >= 4
    }

    /// A cloud failure on audio this quiet is the room, not the cloud: it
    /// must not switch the cloud off for the turns after it. 25 of 31 "no
    /// final within 4 s of ForceEndpoint" and 13 of 21 "socket is not
    /// connected" fallbacks were near-silent turns, and each switched the
    /// cloud off for up to 60 s (82 times in 16 days).
    public static func isSilent(rms: Float) -> Bool { rms < silentLevel }

    /// At or above this a turn had a voice in it, as far as the Mac can tell
    /// — loud enough that a cloud recogniser with no words back yet is slow,
    /// not right. Measured 10-01 → 10-13 on the 15 turns the cloud called
    /// silent: the 13 that were (an empty or invented local read) sat at
    /// 0.000–0.011; the two that were speech — "How does that mean…",
    /// "Fifty dollars" — at 0.052 and 0.066. Owner speech runs 0.054–0.076.
    public static let voiceLevel: Float = 0.03

    public static func voiceIsPresent(rms: Float) -> Bool { rms >= voiceLevel }

    /// Whether an onset over Moe thinking or speaking sounds enough like a
    /// voice for its words to count. Rejected "no words" onsets averaged a
    /// voice-detector probability of 0.51; taken ones 0.82–1.0. Below 0.6
    /// would have dropped 144 of 246 false onsets and 0 of 51 real takes
    /// (09-16 → 10-06). Judged once there are a few chunks to average.
    public static let onsetMinMeanVad = 0.6
    public static let onsetMinChunks = 3

    public static func onsetSoundsLikeSpeech(meanVad: Double?, chunks: Int) -> Bool {
        guard let meanVad, chunks >= onsetMinChunks else { return true }
        return meanVad >= onsetMinMeanVad
    }
}

/// The owner check at the wake word, and the name over a reply.
public enum WakeOwnerCheck {

    /// The owner check refused the owner. Of 16 wake refusals at a fixed
    /// 0.3, 8 were followed within 1–4 s by a retry that went through, and
    /// the refused-owner scores (−0.14…0.29) overlap the rest completely: on
    /// two seconds of mostly "Hey Moe" the embedding cannot tell him apart.
    /// So it refuses only what is clearly someone else, and only when the
    /// head was not sure either.
    public static let refuseBelowVoice: Float = -0.1
    public static let refuseBelowHead: Float = 0.4

    public static func refuses(head: Float, voice: Float) -> Bool {
        voice < refuseBelowVoice && head < refuseBelowHead
    }

    /// A wake this sure may stop a reply even with interruptions off (owner,
    /// 2026-10-06). Five wakes over a reply were ignored 09-29 → 09-30, two
    /// ending on the hotkey. The v6 head fires at a median 0.56; the false
    /// accepts were mostly 0.28–0.34.
    public static let stopsReplyAtHead: Float = 0.45

    /// No "finished" with no words this soon after the name. Five wake turns
    /// ended on the pause after "Hey Moe" (p 0.94–0.96, 0 words, 0.8–1.0 s
    /// of quiet), and the request then arrived as a continuation.
    public static let wordlessFinishAfterWake: TimeInterval = 2.0

    public static func mayFinishWordless(sinceWake: TimeInterval?) -> Bool {
        guard let sinceWake else { return true }
        return sinceWake >= wordlessFinishAfterWake
    }
}
