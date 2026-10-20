import Foundation
import Testing

@testable import MoeMeeting

@Suite("Calendar name offer")
struct CalendarNameOfferTests {

    private func record(speakers: [Int], named: [Int: String] = [:]) -> MeetingRecord {
        var r = MeetingRecord(startedAt: Date(), durationSeconds: 600, folder: "/tmp/m", speakers: speakers)
        r.speakerNames = speakers.map { n in
            SpeakerName(speaker: n, name: named[n], candidates: [],
                        confidence: named[n] == nil ? .unsure : .likely, source: .calendar)
        }
        return r
    }

    /// The 14:00 meeting on 2026-09-08: seven voices, seven empty candidate
    /// lists, because Calendar access had never been granted — `moe.log` has
    /// no "calendar event …" line in its whole history.
    @Test("seven numbered voices and no answer yet is exactly when to ask")
    func theCaseThisExistsFor() {
        let r = record(speakers: [1, 2, 3, 4, 5, 6, 7])
        #expect(CalendarNameOffer.unnamedVoices(r) == 7)
        #expect(CalendarNameOffer.shouldOffer(unnamedVoices: 7, accessUndecided: true, alreadyAsked: false))
        #expect(CalendarNameOffer.text(unnamedVoices: 7).contains("7 other voices"))
    }

    @Test("one voice is worth asking about too — it is the case that names itself")
    func oneVoice() {
        #expect(CalendarNameOffer.shouldOffer(unnamedVoices: 1, accessUndecided: true, alreadyAsked: false))
        #expect(CalendarNameOffer.text(unnamedVoices: 1).contains("1 other voice"))
        #expect(CalendarNameOffer.text(unnamedVoices: 1).contains("a name"))
    }

    @Test("nothing to name, nothing to ask")
    func noVoices() {
        #expect(!CalendarNameOffer.shouldOffer(unnamedVoices: 0, accessUndecided: true, alreadyAsked: false))
        #expect(CalendarNameOffer.unnamedVoices(record(speakers: [])) == 0)
    }

    @Test("voices that already have names do not count")
    func namedVoicesAreNotUnnamed() {
        let r = record(speakers: [1, 2, 3], named: [1: "Dan", 3: "Priya"])
        #expect(CalendarNameOffer.unnamedVoices(r) == 1)
    }

    @Test("asked once, ever — a permission asked twice is nagging")
    func onlyOnce() {
        #expect(!CalendarNameOffer.shouldOffer(unnamedVoices: 4, accessUndecided: true, alreadyAsked: true))
    }

    @Test("refused is an answer; granted needs no asking")
    func onlyWhileUndecided() {
        #expect(!CalendarNameOffer.shouldOffer(unnamedVoices: 4, accessUndecided: false, alreadyAsked: false))
    }
}
