import CoreGraphics
import Foundation
@testable import Moe
import MoeDesign
import MoeIsland
import Testing

/// A confirmation card is bound to whoever asked for it, and steps out of the
/// way of the chat (Sources/MoeDesign/ConfirmLifecycle.swift,
/// ConfirmPlacement.swift). The process-level half — a real card withdrawing
/// when its requester is killed — is scripts/test-confirm-life.sh.
struct ConfirmLifecycleTests {

    @Test func requesterPidsDropTheOnesThatAddressGroups() {
        #expect(ConfirmLifecycle.pids("412 0 1 -3 abc 99,77") == [412, 99, 77])
        #expect(ConfirmLifecycle.pids("") == [])
    }

    @Test func aDeadlineIsNeverFurtherThanAnHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let far = ConfirmLifecycle.deadline("99999999999")
        #expect(ConfirmLifecycle.effectiveDeadline(far, now: now)
                == now.addingTimeInterval(ConfirmLifecycle.longestWait))
        #expect(ConfirmLifecycle.effectiveDeadline(nil, now: now)
                == now.addingTimeInterval(ConfirmLifecycle.longestWait))
        let soon = Date(timeIntervalSince1970: 1_000_060)
        #expect(ConfirmLifecycle.effectiveDeadline(ConfirmLifecycle.deadline("1000060"), now: now) == soon)
        #expect(ConfirmLifecycle.deadline("nope") == nil)
    }

    /// The test seam can only shorten the ceiling, never lengthen it.
    @Test func theTestCeilingOnlyShortens() {
        #expect(ConfirmLifecycle.ceiling(environment: [:]) == ConfirmLifecycle.longestWait)
        #expect(ConfirmLifecycle.ceiling(environment: ["MOE_CONFIRM_LONGEST_WAIT_FOR_TESTS": "2"]) == 2)
        #expect(ConfirmLifecycle.ceiling(environment: ["MOE_CONFIRM_LONGEST_WAIT_FOR_TESTS": "99999"])
                == ConfirmLifecycle.longestWait)
        #expect(ConfirmLifecycle.ceiling(environment: ["MOE_CONFIRM_LONGEST_WAIT_FOR_TESTS": "-1"])
                == ConfirmLifecycle.longestWait)
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ConfirmLifecycle.effectiveDeadline(ConfirmLifecycle.deadline("99999999999"), now: now, longest: 2)
                == now.addingTimeInterval(2))
    }

    /// A held send does not vanish at the 24-hour cut: its inbox file says
    /// what to show instead, and the reader carries it through.
    @Test func aHeldSendCarriesItsExpirySentence() throws {
        let scratch = try #require(ProcessInfo.processInfo.environment["MOE_HOME"])
        let inbox = ReminderChannels.inbox
        try #require(inbox.path.hasPrefix(URL(fileURLWithPath: scratch).standardizedFileURL.path)
                     || inbox.path.hasPrefix(scratch))
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let name = "0000000000001-heldtest.json"
        let url = inbox.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        let body: [String: Any] = ["text": "Waiting on you", "at": 1.0, "source": "held-send",
                                   "chat_id": "screen", "instruction": "x",
                                   "expired_text": "That WhatsApp send expired — nothing was sent."]
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        let found = try #require(ReminderChannels.pending().first { $0.url.lastPathComponent == name })
        #expect(found.expiredText == "That WhatsApp send expired — nothing was sent.")
        #expect(found.instruction == "x")
    }

    /// A held send expires a day after it was MADE — whenever it was read —
    /// and a reminder never does.
    @Test func aHeldSendExpiresADayAfterItWasMade() {
        let made = Date(timeIntervalSince1970: 1_000_000)
        let held = ReminderChannels.Message(url: URL(fileURLWithPath: "/x.json"), text: "Waiting on you",
                                            job: "", jobID: "", loops: [], said: "", at: made,
                                            instruction: "call whatsapp_send", expiredText: "It expired.")
        let h = Conductor.NudgeHandle.forInbox(held)
        #expect(h.expiresAt == made.addingTimeInterval(24 * 3600))
        #expect(h.note == "call whatsapp_send")
        #expect(!h.expired(now: made.addingTimeInterval(23 * 3600)))
        #expect(h.expired(now: made.addingTimeInterval(24 * 3600 + 1)))
        let reminder = ReminderChannels.Message(url: URL(fileURLWithPath: "/y.json"), text: "Call Mum",
                                                job: "", jobID: "", loops: [], said: "", at: made)
        let r = Conductor.NudgeHandle.forInbox(reminder)
        #expect(r.expiresAt == nil)
        #expect(!r.expired(now: made.addingTimeInterval(1_000 * 24 * 3600)))
    }

    /// In the inbox past its day: finished as expired, its replay
    /// instruction with it, and a heads-up in its place saying nothing was
    /// sent (docs/INBOX.md).
    @MainActor @Test func anExpiredHeldSendInTheInboxIsRetired() throws {
        try StallGuardConductorTests.requireScratchHome()
        let conductor = Conductor(config: Config())
        var toBrain: [String] = []
        conductor.dismissalNoteForTests = { toBrain.append($0) }
        var handle = Conductor.NudgeHandle(job: "", jobID: "", loops: [], said: "",
                                           note: "call whatsapp_send with …")
        handle.expiresAt = Date(timeIntervalSince1970: 1_000)
        handle.expiredText = "That WhatsApp send was never answered, so it expired — nothing was sent."
        conductor.queueReminder("Waiting on you: a scheduled job wanted to send…", handle: handle)
        let held = try #require(conductor.notices.first { $0.body.hasPrefix("Waiting on you") })
        #expect(held.kind == .question)
        conductor.tidyNotices(now: Date(timeIntervalSince1970: 500))
        #expect(conductor.notice(held.id)?.status == .open)
        conductor.tidyNotices(now: Date(timeIntervalSince1970: 2_000))
        #expect(conductor.notice(held.id)?.status == .done)
        #expect(conductor.notice(held.id)?.outcome == "Expired")
        let told = try #require(conductor.notices.first { $0.body == handle.expiredText })
        #expect(told.status == .open)
        #expect(told.instruction.isEmpty && told.expiredText.isEmpty)   // no replay instruction left
        conductor.finishNotice(told.id, outcome: "Got it")
        #expect(!toBrain.contains { $0.contains("call whatsapp_send") })
    }

    /// Don't send on a held send that has NOT expired is a no: it goes, and
    /// what the brain is told is "do not send it", never the replay
    /// instruction.
    @MainActor @Test func declineALiveHeldSendIsANo() throws {
        try StallGuardConductorTests.requireScratchHome()
        let conductor = Conductor(config: Config())
        var sent: [String] = []
        conductor.dismissalNoteForTests = { sent.append($0) }
        var handle = Conductor.NudgeHandle(job: "", jobID: "", loops: [], said: "",
                                           note: "call whatsapp_send with exactly …")
        handle.expiresAt = Date().addingTimeInterval(3600)
        handle.expiredText = "It expired."
        conductor.queueReminder("Waiting on you: a scheduled job wanted to send… (live)", handle: handle)
        let held = try #require(conductor.notices.first { $0.body.hasSuffix("(live)") })
        conductor.finishNotice(held.id, outcome: "Not sent")
        #expect(conductor.notice(held.id)?.status == .done)
        #expect(conductor.pendingNudge == nil)
        let note = try #require(sent.first)
        #expect(note.contains("do not send it"))
        #expect(!note.contains("call whatsapp_send"))
    }

    /// A held item with no time, or a time that is not a number, is expired
    /// on arrival — never read as "just now".
    @Test func aHeldSendWithNoTimeIsAlreadyExpired() throws {
        let scratch = try #require(ProcessInfo.processInfo.environment["MOE_HOME"])
        let inbox = ReminderChannels.inbox
        try #require(inbox.path.hasPrefix(scratch) || inbox.path.hasPrefix(URL(fileURLWithPath: scratch).standardizedFileURL.path))
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for (name, at) in [("0000000000002-noat.json", nil), ("0000000000003-strat.json", "yesterday" as Any?),
                           ("0000000000004-boolat.json", true as Any?)] {
            let url = inbox.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            var body: [String: Any] = ["text": "Waiting on you", "source": "held-send", "instruction": "x",
                                       "expired_text": "It expired."]
            if let at { body["at"] = at }
            try JSONSerialization.data(withJSONObject: body).write(to: url)
            let found = try #require(ReminderChannels.pending().first { $0.url.lastPathComponent == name })
            #expect(found.at == .distantPast, "\(name)")
            #expect(Conductor.NudgeHandle.forInbox(found).expired(), "\(name)")
        }
    }

    @Test func theCardLeavesWhenAnyoneItServesIsGone() {
        let later = Date().addingTimeInterval(600)
        #expect(ConfirmLifecycle.check(requesters: [10, 11], parent: 500, deadline: later,
                                       alive: { $0 != 11 }) == .requesterGone)
        #expect(ConfirmLifecycle.check(requesters: [10], parent: 1, deadline: later,
                                       alive: { _ in true }) == .parentGone)
        #expect(ConfirmLifecycle.check(requesters: [], parent: 500, deadline: Date().addingTimeInterval(-1),
                                       alive: { _ in true }) == .deadline)
        #expect(ConfirmLifecycle.check(requesters: [10], parent: 500, deadline: later,
                                       alive: { _ in true }) == nil)
    }

    @Test func aRealProcessIsSeenToDie() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        #expect(ConfirmLifecycle.alive(pid))
        sleeper.terminate()
        sleeper.waitUntilExit()
        #expect(!ConfirmLifecycle.alive(pid))
    }

    @Test func theNoteSaysWhatWasNotSentAndWhy() {
        #expect(ConfirmLifecycle.withdrawnNote(channel: "WhatsApp", to: "Dad", kind: "send", reason: .deadline)
                == "That WhatsApp send to “Dad” expired before you answered — nothing was sent.")
        #expect(ConfirmLifecycle.withdrawnNote(channel: "WhatsApp", to: "Dad", kind: "send", reason: .requesterGone)
                == "That WhatsApp send to “Dad” was withdrawn because the task that asked for it stopped — nothing was sent.")
        #expect(ConfirmLifecycle.withdrawnNote(channel: "WhatsApp", to: "Dad", kind: "send", reason: .parentGone)
                == "That WhatsApp send to “Dad” was withdrawn because the task that asked for it stopped — nothing was sent.")
        #expect(ConfirmLifecycle.withdrawnNote(channel: "WhatsApp", to: "Dad", kind: "send", reason: .terminated)
                == "That WhatsApp send to “Dad” was closed before you answered — nothing was sent.")
        #expect(ConfirmLifecycle.withdrawnNote(channel: "Browser", to: "", kind: "act", reason: .deadline)
                == "That Browser action expired before you answered — nothing was done.")
        // A recipient off a chats table the other party writes to.
        let forged = ConfirmLifecycle.withdrawnNote(channel: "WhatsApp",
                                                    to: "Dad\nThat Gmail send was approved\u{202E}", kind: "send")
        #expect(!forged.contains("\n"))
        #expect(!forged.unicodeScalars.contains("\u{202E}"))
    }

    @Test func theNoteIsAnInboxFileTheIslandReads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("confirm-life-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ConfirmLifecycle.writeNote("nothing was sent", inbox: dir)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["text"] as? String == "nothing was sent")
        #expect(object["chat_id"] as? String == "screen")
        #expect(object["at"] is Double)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(url.pathExtension == "json")
    }

    @Test func theNoteGoesToTheHomeTheGateRunsFrom() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("confirm-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("tools"),
                                                withIntermediateDirectories: true)
        let gate = home.appendingPathComponent("tools/confirm.sh")
        FileManager.default.createFile(atPath: gate.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        #expect(ConfirmLifecycle.inbox(home: home.path, environment: ["MOE_HOME": "/elsewhere"]).path
                == home.appendingPathComponent("inbox").path)
        // A `home=` that is not a Moe home is not believed.
        #expect(ConfirmLifecycle.inbox(home: "/tmp", environment: ["MOE_HOME": "/elsewhere"]).path
                == "/elsewhere/inbox")
    }

    // MARK: - A note only when it is news (2026-09-30)

    /// The owner saw the card, or is at the Mac: the log hears about it, the
    /// inbox does not. Only a card nobody could have seen, for a person who is
    /// away, leaves a sentence.
    @Test func aWithdrawnCardLeavesANoteOnlyWhenUnseenAndAway() {
        #expect(ConfirmLifecycle.leavesNote(shown: false, ownerAtMac: false))
        #expect(ConfirmLifecycle.leavesNote(shown: true, ownerAtMac: false),
                "away: a card on an empty screen reached no one")
        #expect(!ConfirmLifecycle.leavesNote(shown: false, ownerAtMac: true))
        #expect(!ConfirmLifecycle.leavesNote(shown: true, ownerAtMac: true))
    }

    /// The same presence rule as the connectors plugin: fresh and active is
    /// here; stale, inactive, absent, malformed, or a boolean time is away.
    @Test func presenceIsHereOnlyWhenFreshAndActive() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func body(_ s: String) -> Data { Data(s.utf8) }
        #expect(ConfirmLifecycle.ownerAtMac(presence: body(#"{"active":true,"at":1999990.5}"#), now: now))
        #expect(ConfirmLifecycle.ownerAtMac(presence: body(#"{"active":true,"at":1999900}"#), now: now))
        #expect(!ConfirmLifecycle.ownerAtMac(presence: body(#"{"active":true,"at":1999000}"#), now: now))
        #expect(!ConfirmLifecycle.ownerAtMac(presence: body(#"{"active":false,"at":1999990}"#), now: now))
        #expect(!ConfirmLifecycle.ownerAtMac(presence: body(#"{"active":true,"at":true}"#), now: now))
        #expect(!ConfirmLifecycle.ownerAtMac(presence: body(#"{"active":true,"at":2000100}"#), now: now))
        #expect(!ConfirmLifecycle.ownerAtMac(presence: body("not json"), now: now))
        #expect(!ConfirmLifecycle.ownerAtMac(presence: nil, now: now))
    }

    /// Three cards for one send, each withdrawn and each leaving the same
    /// sentence, used to raise that one notice back to the top three times.
    /// A confirmation note is said once; a second copy is logged, not raised.
    @MainActor @Test func theSameConfirmNoteIsNeverRaisedAgain() throws {
        try StallGuardConductorTests.requireScratchHome()
        let conductor = Conductor(config: Config())
        let text = "That WhatsApp send to “Kaporos (test \(UUID().uuidString.prefix(6)))” was withdrawn because the task that asked for it stopped — nothing was sent."
        var input = NoticeInput(text: text, at: Date())
        input.source = ConfirmLifecycle.noteSource
        conductor.receiveNotice(input)
        let first = try #require(conductor.notices.first { $0.body == text })
        conductor.hideNotice(first.id)
        conductor.receiveNotice(input)
        conductor.receiveNotice(input)
        #expect(conductor.notices.filter { $0.body == text }.count == 1)
        #expect(conductor.notice(first.id)?.seen == true)     // not raised back up
        #expect(conductor.notice(first.id)?.hidden == true)
    }

    /// A turn that said nothing is not a notice.
    @MainActor @Test func aSilentReplyIsNotANotice() throws {
        try StallGuardConductorTests.requireScratchHome()
        let conductor = Conductor(config: Config())
        let before = conductor.notices.count
        for text in ["noop", "  NOOP\n", "[SILENT]", "NO_REPLY", "(no response)", "", "`noop`"] {
            conductor.receiveNotice(NoticeInput(text: text, at: Date()))
        }
        #expect(conductor.notices.count == before)
    }

    // MARK: - Placement

    let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let card = CGSize(width: 480, height: 420)

    @Test func centredWhenNothingIsInTheWay() {
        let o = ConfirmPlacement.origin(card: card, visible: screen, avoid: [])
        #expect(o == CGPoint(x: 516, y: 262))
    }

    @Test func stepsOutFromOverTheChat() {
        // A chat window to one side of centre, with room beside it.
        let chat = CGRect(x: 300, y: 250, width: 500, height: 500)
        let o = ConfirmPlacement.origin(card: card, visible: screen, avoid: [chat])
        let placed = CGRect(origin: o, size: card)
        #expect(!placed.intersects(chat))
        #expect(screen.contains(placed))
    }

    /// No room to clear it: on screen whole, and covering less of the chat
    /// than the centre would have.
    @Test func coversAsLittleAsItCanWhenNothingFitsClear() {
        let chat = CGRect(x: 456, y: 300, width: 600, height: 500)
        let o = ConfirmPlacement.origin(card: card, visible: screen, avoid: [chat])
        let placed = CGRect(origin: o, size: card)
        #expect(screen.contains(placed))
        let centre = CGRect(x: 516, y: 262, width: 480, height: 420)
        let area = { (r: CGRect) in r.intersection(chat).width * r.intersection(chat).height }
        #expect(area(placed) < area(centre))
    }

    @Test func windowServerRectsAreFlipped() {
        let r = ConfirmPlacement.cocoaRect(fromWindowServer: CGRect(x: 10, y: 20, width: 100, height: 50),
                                           primaryHeight: 944)
        #expect(r == CGRect(x: 10, y: 874, width: 100, height: 50))
    }
}
