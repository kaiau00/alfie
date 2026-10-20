import Foundation
import Testing
@testable import MoeBrain

/// What Moe says while the confirmation sheet waits on the person.
///
/// The bug these guard: Moe said "Still getting that ready to send" for as
/// long as the sheet sat there, because it did not know a sheet existed. So
/// the tests are about two things — that the person is told what to do (press
/// Send, and that they can change the words), and that nothing here ever
/// claims the message went.
struct ConfirmWaitTests {

    @Test func aSendTellsThemToPressSend() {
        let line = ConfirmWait.announcement(kind: .send, editable: true)
        #expect(line.contains("press Send"))
        #expect(line.contains("on your screen"))
    }

    @Test func anEditableSendSaysTheWordsCanChange() {
        #expect(ConfirmWait.announcement(kind: .send, editable: true).contains("change the words"))
    }

    /// The sheet shows some messages read-only (bidi characters, a body too
    /// long to draw, a call whose words cannot be put back). Offering an edit
    /// the sheet will not allow would be a wrong account of what is on screen.
    @Test func aReadOnlySendDoesNotOfferAnEdit() {
        let line = ConfirmWait.announcement(kind: .send, editable: false)
        #expect(line.contains("press Send"))
        #expect(!line.contains("change"))
        #expect(!line.lowercased().contains("edit"))
    }

    /// An act's button is "Do it", not "Send" — telling someone to press a
    /// button that is not there is the same mistake in a different place.
    @Test func anActDoesNotTalkAboutSending() {
        for line in [ConfirmWait.announcement(kind: .act, editable: true),
                     ConfirmWait.reminder(kind: .act),
                     ConfirmWait.status(kind: .act)] {
            #expect(!line.lowercased().contains("send"), "\(line)")
        }
    }

    /// Nothing is sent while the sheet is up, so no line may say it was, or
    /// that it is happening now.
    @Test func nothingClaimsTheMessageWent() {
        var lines: [String] = []
        for kind in [ConfirmWait.Kind.send, .act] {
            lines.append(ConfirmWait.announcement(kind: kind, editable: true))
            lines.append(ConfirmWait.announcement(kind: kind, editable: false))
            lines.append(ConfirmWait.reminder(kind: kind))
            lines.append(ConfirmWait.status(kind: kind))
        }
        for line in lines {
            let l = line.lowercased()
            #expect(!l.contains("sending"), "\(line)")
            #expect(!l.contains("sent"), "\(line)")
            #expect(!l.contains("getting that ready"), "\(line)")
        }
    }

    /// The dialog's wire word. Only "act" is an act; anything else — absent,
    /// misspelt, from an older dialog — is treated as a send, the question
    /// that most needs naming.
    @Test func theWireKindDefaultsToSend() {
        #expect(ConfirmWait.Kind(wire: "act") == .act)
        #expect(ConfirmWait.Kind(wire: "send") == .send)
        #expect(ConfirmWait.Kind(wire: nil) == .send)
        #expect(ConfirmWait.Kind(wire: "session") == .send)
    }

    /// One reminder, and not before the step narration's own twelve-second
    /// rhythm would have spoken — otherwise the reminder lands on top of the
    /// announcement.
    @Test func theReminderWaitsLongerThanAStepRepeat() {
        #expect(ConfirmWait.reminderAfter > 12)
    }
}
