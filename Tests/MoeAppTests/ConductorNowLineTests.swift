import Foundation
import MoeBrain
import Testing
@testable import Moe

/// Ticket #9: every turn starts with the Now line.
///
/// What `TurnClock.stamped` — applied in `HermesBrain.pumpLocked`, where
/// every turn becomes a request — makes of the shapes a turn leaves the
/// Conductor in (spoken, typed, a background note, one carrying the brief),
/// under an injected clock. That every route really passes through it — a
/// plain turn, a re-issue after sleep, a resume's priming — is proven on the
/// requests themselves by scripts/test-now-line.sh.
@Suite(.serialized)
struct ConductorNowLineTests {
    static let ny = TimeZone(identifier: "America/New_York")!
    static let ticket = ISO8601DateFormatter().date(from: "2026-09-23T22:08:00Z")!
    static let expected = "Now: Wednesday 23 September 2026, 6:08 PM (evening), New York time (EDT, UTC-4)."

    private func withClock<T>(_ body: () -> T) -> T {
        let saved = TurnClock.source
        TurnClock.source = { (Self.ticket, Self.ny) }
        defer { TurnClock.source = saved }
        return body()
    }

    /// What `submit` builds for a spoken "What's up?": the words, then the
    /// delivery rules (Conductor.submit), possibly behind the brief.
    @Test func aSpokenTurnStartsWithNow() {
        let turn = withClock {
            TurnClock.stamped("What's up?" + "\n\n" + BrainPrompt.deliveryReminder)
        }
        #expect(turn.hasPrefix(Self.expected + "\n\n"))
        #expect(turn.contains("What's up?"))
    }

    @Test func aTypedTurnStartsWithNowAndThenItsMarker() {
        let turn = withClock {
            TurnClock.stamped(BrainPrompt.typedTurnMarker + "\n\nWhat's up?\n\n" + BrainPrompt.deliveryReminder)
        }
        #expect(turn.hasPrefix(Self.expected + "\n\n(Typed, not spoken:"))
    }

    @Test func aBackgroundNoteStartsWithNow() {
        let turn = withClock {
            TurnClock.stamped("(Background note, not from the user. You just told them out loud: \"Call Dani\" Do not reply to this message.)")
        }
        #expect(turn.hasPrefix(Self.expected + "\n\n(Background note"))
    }

    @Test func aTurnCarryingTheBriefStillStartsWithNow() throws {
        let brief = try #require(BrainPrompt.briefBlock("# Right now\n\n## Calendar\n\n- 2:00–3:00 PM Project Atlas call — ended 3 h ago"))
        let dated = BrainPrompt.dated(brief, gathered: Self.ticket.addingTimeInterval(-60),
                                      now: Self.ticket, zone: Self.ny)
        #expect(dated.hasPrefix("# What is going on right now (as of 6:07 PM, 1 min before this message)"))
        let turn = withClock { TurnClock.stamped(dated + "\n\n---\n\nWhat's up?") }
        #expect(turn.hasPrefix(Self.expected + "\n\n# What is going on right now (as of 6:07 PM"))
    }

    /// The brief's age is read from its own stamp, which is what its labels
    /// are relative to; the file's mtime only when the stamp is unreadable.
    @Test func theBriefsAgeComesFromItsRefreshedStamp() {
        let brief = "# Right now\n\n_Refreshed Wednesday 23 September, 6:07 PM._\n\n## Calendar"
        let at = BrainPrompt.refreshedAt(brief, now: Self.ticket, zone: Self.ny)
        #expect(at == Self.ticket.addingTimeInterval(-60))
        // Read on New Year's Day, a December stamp is last year's.
        let jan1 = ISO8601DateFormatter().date(from: "2027-01-01T05:10:00Z")!
        let dec = BrainPrompt.refreshedAt("_Refreshed Thursday 31 December, 11:50 PM._", now: jan1, zone: Self.ny)
        #expect(dec == ISO8601DateFormatter().date(from: "2027-01-01T04:50:00Z"))
        #expect(BrainPrompt.refreshedAt("_Rafraîchi mercredi 23 septembre, 18:07._", now: Self.ticket, zone: Self.ny) == nil)
    }

    /// The rule the model is given for the line, on every Mac turn.
    @Test func theDeliveryReminderCarriesTheRule() {
        #expect(BrainPrompt.deliveryReminder.contains(BrainPrompt.nowRule))
        #expect(BrainPrompt.nowRule.hasPrefix("The Now line at the top of each message is the only clock."))
    }

    // MARK: - Wiring, from source

    private static func source(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Chat turns (Telegram, WhatsApp, the away machine) get the same rule
    /// from the moe-screen plugin; the two copies may not drift.
    @Test func theChatPluginSaysTheSameRule() throws {
        let py = try #require(Self.source("moe-home/hermes-plugins/moe-screen/nowline.py"))
        #expect(py.contains(BrainPrompt.nowRule))
    }

    // MARK: - AGENTS.md (FirstRun)

    /// The persona said the brief was "in your system prompt" (FirstRun.swift,
    /// ticket #9). New installs get the corrected text; installed copies have
    /// the old paragraph replaced once, verbatim.
    @Test func thePersonaNoLongerSaysTheBriefIsInTheSystemPrompt() throws {
        #expect(!FirstRun.agentsMd.contains("Your system prompt already contains"))
        #expect(FirstRun.agentsMd.contains(FirstRun.briefBullet))
        #expect(FirstRun.briefBullet.contains("the **Now** line at the top of each message is the only clock"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-agents-\(UUID().uuidString).md")
        try ("# Alfie\n\n## Before you answer\n\n" + FirstRun.legacyBriefBullet + "\nMine.\n")
            .write(to: url, atomically: true, encoding: .utf8)
        FirstRun.refreshManagedSections(at: url)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(!after.contains("Your system prompt already contains"))
        #expect(after.contains(FirstRun.briefBullet))
        #expect(after.contains("Mine."))
    }
}
