import Foundation
import Testing
@testable import Moe
import MoeBrain
import MoeIsland

/// What a person gets when they download Moe — the rows of docs/DEFAULTS.md
/// that live in `Config`'s initialisers. Each row number is the table's.
/// A default that drifts fails here by name, so the doc and the code cannot
/// disagree without someone noticing.
struct FreshInstallDefaultsTests {
    let fresh = Config()

    @Test("row 5 — reply length starts Short")
    func replyLength() {
        #expect(fresh.replyLength == ReplyLength.short.rawValue)
    }

    @Test("row 6 — spoken questions are spoken back, typed ones are written")
    func speaking() {
        #expect(fresh.speakReplies)
        #expect(fresh.speakSpokenReplies)
        #expect(!fresh.speakTypedReplies)
        #expect(fresh.typedRepliesReadAsText)
    }

    @Test("row 7 — the panel opens only for a silent answer and stays until dismissed")
    func panel() {
        #expect(fresh.panelOnReply == PanelReveal.silent.rawValue)
        #expect(fresh.replyReadingSeconds == 0)
    }

    @Test("rows 11–14 — no instant ack, progress spoken, chime on, typed questions stay in the panel")
    func workingCues() {
        #expect(!fresh.instantAck)
        #expect(fresh.spokenProgress)
        #expect(fresh.replyChime)
        #expect(!fresh.typedAnswersOpenChat)
    }

    /// Keep listening is the one that is on (the owner, 2026-09-25); the
    /// rest stay opt-in. An existing install keeps its own value —
    /// `VoiceSettingsTests.anExistingInstallKeepsItsValue`.
    @Test("row 9 — keep listening is on for a new install; the other conversation extras are opt-in")
    func conversationExtras() {
        #expect(fresh.conversationMode)
        #expect(!fresh.bargeIn)
        #expect(!fresh.wakeWordEnabled)
        #expect(!fresh.holdOpensConversation)
    }

    /// Debug audio of the voice loop's flagged moments is for building a
    /// noise dataset by hand. It records the room, so it is never on by
    /// default (the 2026-09-22 noise work).
    @Test func voiceDebugAudioIsOffByDefault() {
        #expect(!fresh.voiceDebugAudio)
    }

    /// The wake word's second stage costs the owner recall on his own
    /// recordings (41/65 → 32/65, 2026-09-23), so it ships off; the evidence
    /// wait after a verdict is measured better on eot-bench and ships on.
    @Test func wakeConfirmIsOffAndTheEvidenceWaitIsOn() {
        #expect(!fresh.wakeConfirm)
        #expect(fresh.turnEvidence)
        // The owner gate only records until its line is measured (review H3).
        #expect(!fresh.ownerGateEnforce)
        // The on-device model's vote is unmeasured on a Mac where it runs,
        // and the owner's pause habit has no data yet: both ship off
        // (turn-semantics.md).
        #expect(!fresh.turnSemanticModel)
        #expect(!fresh.turnOwnerPauses)
    }

    @Test("row 17 — echo cancellation is on, as its comment now says")
    func echo() {
        #expect(fresh.echoCancellation)
    }

    @Test("row 21 — a heads-up ten minutes before something in the calendar")
    func headsUp() {
        #expect(fresh.calendarHeadsUpMinutes == 10)
    }

    @Test("row 30 — Alfie starts with the Mac")
    func launchAtLogin() {
        #expect(fresh.launchAtLogin)
    }

    @Test("row 28 — a report says who sent it unless the person turns that off")
    func problemReportsNameTheSender() throws {
        #expect(!fresh.problemReportsAnonymous)
        // moe-ticket.py reads this exact key out of config.json; a rename here
        // would leave the switch on screen and every report still named.
        var on = Config()
        on.problemReportsAnonymous = true
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(on)) as? [String: Any]
        #expect(json?["problemReportsAnonymous"] as? Bool == true)
        let back = try JSONDecoder().decode(Config.self, from: Data(#"{"problemReportsAnonymous": true}"#.utf8))
        #expect(back.problemReportsAnonymous)
    }

    @Test("row 38 — the Mac's language when Alfie can hear it, else English")
    func language() {
        #expect(SpeechLanguages.systemDefault(preferring: ["fr-FR", "en-US"]) == "fr-FR")
        #expect(SpeechLanguages.systemDefault(preferring: ["fr-CA"]) == "fr-FR")
        #expect(SpeechLanguages.systemDefault(preferring: ["af-ZA", "de-DE"]) == "de-DE")
        #expect(SpeechLanguages.systemDefault(preferring: ["af-ZA"]) == "en-US")
        #expect(SpeechLanguages.systemDefault(preferring: []) == "en-US")
        #expect(SpeechLanguages.entry(for: fresh.locale) != nil)
    }

    @Test("a config.json with none of these keys decodes to the same defaults")
    func decodeFallsBackToTheSameDefaults() throws {
        let decoded = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(decoded.replyLength == fresh.replyLength)
        #expect(decoded.replyReadingSeconds == fresh.replyReadingSeconds)
        #expect(decoded.typedAnswersOpenChat == fresh.typedAnswersOpenChat)
        #expect(decoded.calendarHeadsUpMinutes == fresh.calendarHeadsUpMinutes)
        #expect(decoded.launchAtLogin == fresh.launchAtLogin)
        #expect(decoded.problemReportsAnonymous == fresh.problemReportsAnonymous)
        #expect(decoded.locale == fresh.locale)
    }

    // The login item's once-per-Mac rule is LoginItemMomentTests: with a
    // recording registrar, so no test calls ServiceManagement. The test that
    // stood here registered the xctest process for real, and asserted the
    // marker was written after macOS refused — the bug, pinned.

    @Test("rows 5 and 21 reach the scripts: a missing config.json is written with the defaults")
    func defaultsWrittenWhenAbsent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-config-absent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        #expect(Config.writeIfAbsent(fresh, at: url))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // The two keys the scripts read: moe-calendar-heads-up.py and
        // configure-hermes.py's delivery_for.
        #expect(json["calendarHeadsUpMinutes"] as? Int == 10)
        #expect(json["replyLength"] as? String == "short")
        #expect(json["launchAtLogin"] as? Bool == true)
    }

    @Test("an existing config.json is never overwritten by the defaults")
    func existingConfigLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-config-present-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let mine = Data(#"{"replyLength": "detailed"}"#.utf8)
        try mine.write(to: url)
        #expect(!Config.writeIfAbsent(fresh, at: url))
        #expect(try Data(contentsOf: url) == mine)
    }
}
