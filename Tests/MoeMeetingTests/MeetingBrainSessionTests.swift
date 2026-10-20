import Foundation
import Testing

@testable import MoeMeeting

/// The separation that stops the action scan answering the notes request.
///
/// Every one of these is about *ids*, not keys. Hermes keys its transcript
/// on the session id, so two purposes sharing an id share a conversation
/// however different their session keys are — which is exactly how a
/// six-key notes request came back as `{"actions":[…]}` in 11.6 s.
@Suite("Meeting brain sessions")
struct MeetingBrainSessionTests {

    private let meeting = "b42356bf-3b4b-4c8a-b5d3-099983dd9e29"

    @Test("no two purposes share a session id")
    func purposesAreApart() {
        let ids = MeetingBrainPurpose.allCases.map {
            MeetingBrainSession.id(meetingID: meeting, purpose: $0)
        }
        #expect(Set(ids).count == MeetingBrainPurpose.allCases.count)
    }

    /// The pair that caused it. The scan is asked sixty times an hour for
    /// `{"actions":…}`; the notes must not arrive in that conversation.
    @Test("the scan and the notes are on different sessions")
    func theScanCannotAnswerTheNotes() {
        #expect(MeetingBrainSession.id(meetingID: meeting, purpose: .scan)
                != MeetingBrainSession.id(meetingID: meeting, purpose: .notes))
    }

    @Test("no two meetings share a session id")
    func meetingsAreApart() {
        let a = MeetingBrainSession.id(meetingID: "meeting-a", purpose: .scan)
        let b = MeetingBrainSession.id(meetingID: "meeting-b", purpose: .scan)
        #expect(a != b)
    }

    /// A retry inside one meeting has to land on the same warm session, so
    /// the derivation cannot be random.
    @Test("the same meeting and purpose always give the same id")
    func stable() {
        #expect(MeetingBrainSession.id(meetingID: meeting, purpose: .caption)
                == MeetingBrainSession.id(meetingID: meeting, purpose: .caption))
    }

    @Test("it is a UUID, because that is what the header carries")
    func shape() {
        for purpose in MeetingBrainPurpose.allCases {
            let id = MeetingBrainSession.id(meetingID: meeting, purpose: purpose)
            #expect(UUID(uuidString: id) != nil, "\(purpose) gave \(id)")
        }
    }

    @Test("only the notes get a clean session every time")
    func onlyNotesStartFresh() {
        #expect(!MeetingBrainPurpose.notes.isContinuous)
        for purpose in MeetingBrainPurpose.allCases where purpose != .notes {
            #expect(purpose.isContinuous, "\(purpose) should keep its session warm")
        }
    }

    @Test("only the notes stay on the person's model; the recurring jobs go cheap")
    func onlyNotesKeepTheChosenModel() {
        #expect(!MeetingBrainPurpose.notes.usesCheapestModel)
        for purpose in MeetingBrainPurpose.allCases where purpose != .notes {
            #expect(purpose.usesCheapestModel, "\(purpose) should run on the cheapest model")
        }
    }

    @Test("the action scan runs every two minutes, not every minute")
    func scanEveryTwoMinutes() {
        // 2026-09-15: a 62-minute meeting made 61 scans on Opus. Two minutes
        // was the owner's call; a faster clock is a cost decision, not a tweak.
        #expect(ActionItemScan.interval == 120)
    }

    @Test("session keys are distinct too, so Hermes's memory is scoped per job")
    func keysAreApart() {
        let keys = MeetingBrainPurpose.allCases.map(\.sessionKey)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix(MeetingSummaryPrompt.sessionKey) })
    }
}
