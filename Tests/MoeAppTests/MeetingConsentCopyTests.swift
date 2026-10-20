import AppKit
import Foundation
import MoeMeeting
import Testing
@testable import Moe

/// The consent sheet promises a line to tell the room, and the promise has
/// to be kept by the sheet itself: Settings › Meetings says "the
/// announcement is one click away when you start", and until 2026-09-16 the
/// only click was Start. These tests pin the button, what it copies, and
/// that the small print no longer tells the person to manage alone.
struct MeetingConsentCopyTests {
    @Test("the copy button puts the announcement, and nothing else, on the pasteboard")
    func copiesTheAnnouncement() {
        let scratch = NSPasteboard(name: NSPasteboard.Name("moe-tests-meeting-consent"))
        defer { scratch.releaseGlobally() }
        let line = MeetingOwner.announcement(userName: "Lena")
        #expect(MeetingConsentSheet.copy(line, to: scratch))
        #expect(scratch.string(forType: .string) == line)
        // AppKit adds the legacy NSStringPboardType beside .string, so
        // "nothing else" is checked by content rather than by type list.
        #expect(scratch.types?.contains(.string) == true)
        // A second press replaces, never appends.
        #expect(MeetingConsentSheet.copy("again", to: scratch))
        #expect(scratch.string(forType: .string) == "again")
    }

    @Test("the line names the person's assistant and where the recording stays")
    func theLineIsTheAnnouncement() {
        let sheet = MeetingConsentSheet(onStart: {}, onCancel: {}, announcement: MeetingOwner.announcement(userName: "Lena"))
        #expect(sheet.announcement == "Lena's assistant is taking notes for this meeting. The recording stays on their Mac.")
    }

    @Test("the small print offers the line instead of leaving the person to it")
    func smallPrintMatchesTheButton() {
        let words = MeetingConsentSheet.smallPrint
        #expect(words.contains("Moe can't tell the other people on this call"))
        #expect(words.contains("copy a line below"))
        #expect(!words.contains("please do that yourself"))
        #expect(MeetingConsentSheet.copyTitle == "Copy a line to tell them")
        #expect(MeetingConsentSheet.copiedTitle == "Copied")
    }
}
