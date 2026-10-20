import Testing
@testable import MoeVoice

/// Whether an answer is read out loud.
///
/// The bug this exists to stop: every speaking gate in `Conductor` read one
/// global switch, so a question typed quietly into the island's field — the
/// one whose placeholder reads "Ask Moe — quietly" — was answered aloud.
struct ReplyRouteTests {

    /// The default arrangement, which is the whole point of the feature:
    /// talk to Moe and it talks back, type to Moe and it doesn't.
    @Test func typedIsQuietAndSpokenIsNot() {
        #expect(!ReplyRoute.speaks(origin: .typed, master: true, typed: false,
                                   spoken: true, meetingRecording: false))
        #expect(ReplyRoute.speaks(origin: .spoken, master: true, typed: false,
                                  spoken: true, meetingRecording: false))
    }

    /// Somebody who wants their typed answers read out can have that.
    @Test func typedCanBeSpokenWhenAskedFor() {
        #expect(ReplyRoute.speaks(origin: .typed, master: true, typed: true,
                                  spoken: true, meetingRecording: false))
    }

    /// And somebody who talks to Moe but wants to read the answer can have
    /// that too. The two are genuinely independent; neither implies the other.
    @Test func spokenCanBeSilentWhileTypedTalks() {
        #expect(!ReplyRoute.speaks(origin: .spoken, master: true, typed: true,
                                   spoken: false, meetingRecording: false))
        #expect(ReplyRoute.speaks(origin: .typed, master: true, typed: true,
                                  spoken: false, meetingRecording: false))
    }

    /// The master switch is the master switch. Off means off, and neither of
    /// the two below it can talk over it.
    @Test func theMasterSwitchWinsOverBoth() {
        for origin in [TurnOrigin.typed, .spoken] {
            #expect(!ReplyRoute.speaks(origin: origin, master: false, typed: true,
                                       spoken: true, meetingRecording: false))
        }
    }

    /// A recorded meeting is silent whatever anybody has chosen: the room
    /// would hear it and the call's microphone would carry it to everyone
    /// else. This is not a preference and must not be reachable by one.
    @Test func aRecordedMeetingSilencesEverything() {
        for origin in [TurnOrigin.typed, .spoken] {
            #expect(!ReplyRoute.speaks(origin: origin, master: true, typed: true,
                                       spoken: true, meetingRecording: true))
        }
    }

    /// The meeting rule outranks the master switch as well, which is only
    /// worth stating because the two are checked in the same guard and an
    /// edit that reorders them would be invisible.
    @Test func theMeetingRuleIsCheckedEvenWithSpeechAlreadyOff() {
        #expect(!ReplyRoute.speaks(origin: .spoken, master: false, typed: false,
                                   spoken: false, meetingRecording: true))
    }

    /// `TurnOrigin` is stored nowhere yet, but it is `Codable` and a spelling
    /// change would be a silent migration. Pin the wire form.
    @Test func theOriginNamesAreStable() {
        #expect(TurnOrigin.typed.rawValue == "typed")
        #expect(TurnOrigin.spoken.rawValue == "spoken")
    }
}
