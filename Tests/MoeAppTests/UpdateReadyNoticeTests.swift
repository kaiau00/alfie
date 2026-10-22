import Foundation
import Testing
@testable import Moe

/// docs/DEFAULTS.md row 47: once Sparkle has downloaded an update and is
/// holding it to install on quit, the island asks the person to restart —
/// never an automatic restart, never mid-meeting, mid-speech or mid-reply,
/// and "Later" asks again after a day.
///
/// `UpdateReadyPolicy.shouldShow` is the whole decision; the island and the
/// panel's height both call it through `UpdateReadyNotice.showing(for:)`. The
/// instant is fixed and the 24 hours are written out in seconds here, not read
/// from `askAgainAfter`, so a changed constant fails `laterHoldsForADay`
/// rather than agreeing with itself.
struct UpdateReadyNoticeTests {

    /// 2026-09-11 08:26:40 UTC. Nothing here reads the clock.
    private let now = Date(timeIntervalSince1970: 1_789_115_200)
    private let hour: TimeInterval = 3_600

    private func show(staged: Bool = true, dismissedAt: Date? = nil, at: Date? = nil,
                      meetingRecording: Bool = false, voiceBusy: Bool = false,
                      replyInProgress: Bool = false) -> Bool {
        UpdateReadyPolicy.shouldShow(staged: staged, dismissedAt: dismissedAt, now: at ?? now,
                                     meetingRecording: meetingRecording, voiceBusy: voiceBusy,
                                     replyInProgress: replyInProgress)
    }

    @Test func nothingStagedNeverAsks() {
        #expect(!show(staged: false))
        #expect(!show(staged: false, dismissedAt: now.addingTimeInterval(-48 * hour)))
    }

    @Test func aStagedUpdateAsksWhenMoeIsIdle() {
        #expect(show())
    }

    @Test func aRecordedMeetingDefersIt() {
        #expect(!show(meetingRecording: true))
    }

    @Test func listeningOrSpeakingDefersIt() {
        #expect(!show(voiceBusy: true))
    }

    @Test func aReplyInProgressDefersIt() {
        #expect(!show(replyInProgress: true))
    }

    /// Deferred, not dropped: the same inputs with the busy state gone ask.
    @Test func deferredAsksOnceIdle() {
        #expect(!show(meetingRecording: true, voiceBusy: true, replyInProgress: true))
        #expect(show(meetingRecording: false, voiceBusy: false, replyInProgress: false))
    }

    @Test func laterHoldsForADay() {
        #expect(!show(dismissedAt: now, at: now))
        #expect(!show(dismissedAt: now, at: now.addingTimeInterval(86_399)))
        #expect(show(dismissedAt: now, at: now.addingTimeInterval(86_400)))
        #expect(show(dismissedAt: now, at: now.addingTimeInterval(30 * hour)))
    }

    @Test func aDayLaterStillWaitsForIdle() {
        #expect(!show(dismissedAt: now, at: now.addingTimeInterval(25 * hour), replyInProgress: true))
    }

    /// A clock set backwards is not "dismissed a moment ago" for ever.
    @Test func aClockSetBackwardsAsks() {
        #expect(show(dismissedAt: now.addingTimeInterval(hour), at: now))
    }

    @Test func theWordsAreTheDecidedOnes() {
        #expect(UpdateReadyPolicy.sentence == "A new version of Alfie is ready.")
        #expect(UpdateReadyPolicy.restartLabel == "Restart to update")
    }

    // MARK: - The glow (glow + panel, owner 2026-09-15)

    /// The collapsed island's glow with no nudge held, from the same inputs
    /// the notice is decided on — the island passes `showing(for:)` straight in.
    private func glows(staged: Bool = true, dismissedAt: Date? = nil, at: Date? = nil,
                       meetingRecording: Bool = false, voiceBusy: Bool = false,
                       replyInProgress: Bool = false) -> Bool {
        IslandGlow.glows(nudgeHeld: false,
                         updateNoticeShowing: show(staged: staged, dismissedAt: dismissedAt, at: at,
                                                   meetingRecording: meetingRecording, voiceBusy: voiceBusy,
                                                   replyInProgress: replyInProgress))
    }

    /// Every combination: the glow and the notice agree, and both answers
    /// occur, so agreement is not two constants matching.
    @Test func anUpdateGlowsExactlyWhenTheNoticeWouldShow() {
        var seen = Set<Bool>()
        for staged in [false, true] {
            for dismissed in [nil, now, now.addingTimeInterval(-25 * hour)] as [Date?] {
                for meeting in [false, true] {
                    for voice in [false, true] {
                        for reply in [false, true] {
                            let notice = show(staged: staged, dismissedAt: dismissed, meetingRecording: meeting,
                                              voiceBusy: voice, replyInProgress: reply)
                            #expect(glows(staged: staged, dismissedAt: dismissed, meetingRecording: meeting,
                                          voiceBusy: voice, replyInProgress: reply) == notice)
                            seen.insert(notice)
                        }
                    }
                }
            }
        }
        #expect(seen == [false, true])
    }

    @Test func aStagedUpdateGlowsWhenMoeIsIdle() {
        #expect(glows())
        #expect(!glows(staged: false))
    }

    @Test func noGlowDuringAMeetingVoiceOrAReply() {
        #expect(!glows(meetingRecording: true))
        #expect(!glows(voiceBusy: true))
        #expect(!glows(replyInProgress: true))
    }

    @Test func noGlowForADayAfterLater() {
        #expect(!glows(dismissedAt: now, at: now))
        #expect(!glows(dismissedAt: now, at: now.addingTimeInterval(86_399)))
        #expect(glows(dismissedAt: now, at: now.addingTimeInterval(86_400)))
    }

    /// The update is a second reason for the nudge's glow, not a replacement.
    @Test func aHeldNudgeStillGlowsAndNothingDoesNot() {
        #expect(IslandGlow.glows(nudgeHeld: true, updateNoticeShowing: false))
        #expect(IslandGlow.glows(nudgeHeld: true, updateNoticeShowing: true))
        #expect(!IslandGlow.glows(nudgeHeld: false, updateNoticeShowing: false))
    }

    /// A call Moe offers to record waits on you like a reminder does, so it
    /// takes the same amber (2026-09-24): the corner card that used to carry
    /// it is gone, and the question lives on the island alone.
    @Test func aCallOfferGlowsToo() {
        #expect(IslandGlow.glows(nudgeHeld: false, updateNoticeShowing: false, callOffered: true))
    }
}
