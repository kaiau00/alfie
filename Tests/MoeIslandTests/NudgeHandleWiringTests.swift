import Foundation
import Testing
@testable import MoeIsland

/// The island's half of "answering a message Moe started".
///
/// A nudge on the amber pulse has always carried its words. What it never
/// carried was a way to change the thing that produced it, and that is what
/// broke on 2026-09-04: told "Eli's still waiting for IT admin rights", the
/// person said "ok dont remond me anymore about that" and Moe replied "which
/// reminder do you mean?" — with, at that moment, no reminder in view and no
/// tool that could have stopped one. The Telegram half of the fix is
/// `moe-home/hermes-plugins/moe-screen/followups.py` and is tested there.
/// This is the Mac's half, and all of it lives in call sites.
///
/// Read from source for the same reason `ConductorWiringTests` does: the
/// Conductor is an executable target and Swift cannot import one. These are
/// claims about *where* things are called, which no behavioural test would
/// notice going wrong — a `queueReminder` that quietly stopped passing the
/// handle would still show the pulse, still speak the words, and still leave
/// the person unable to stop it.
struct NudgeHandleWiringTests {

    private static let conductor: String? = source("Sources/Moe/Conductor.swift")
    private static let channels: String? = source("Sources/Moe/Settings/ReminderChannels.swift")
    private static let notch: String? = source("Sources/Moe/NotchIsland.swift")
    private static let islandView: String? = source("Sources/Moe/IslandView.swift")
    private static let inbox: String? = source("Sources/Moe/Inbox/IslandInbox.swift")
    private static let card: String? = source("Sources/Moe/Inbox/NoticeCard.swift")

    private static func source(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)   // Tests/MoeIslandTests/…
            .deletingLastPathComponent()             // Tests/MoeIslandTests
            .deletingLastPathComponent()             // Tests
            .deletingLastPathComponent()             // repo root
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(_ needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    @Test func bothSourcesAreWhereThisExpectsThem() {
        #expect(Self.conductor != nil, "Sources/Moe/Conductor.swift moved.")
        #expect(Self.channels != nil, "Sources/Moe/Settings/ReminderChannels.swift moved.")
        #expect(Self.notch != nil, "Sources/Moe/NotchIsland.swift moved.")
        #expect(Self.islandView != nil, "Sources/Moe/IslandView.swift moved.")
    }

    // MARK: - The handles survive the trip from the plugin

    /// `deliver.write_inbox` writes `job_id` and `loops` beside the text. If
    /// this stops reading them the pulse still works and every "stop
    /// reminding me" quietly becomes an apology again.
    @Test func theInboxReaderKeepsTheHandles() throws {
        let source = try #require(Self.channels)
        #expect(source.contains("jobID: obj[\"job_id\"] as? String ?? \"\""),
                "ReminderChannels stopped reading job_id out of the inbox file.")
        #expect(source.contains("loops: (obj[\"loops\"] as? [String] ?? [])"),
                "ReminderChannels stopped reading loops out of the inbox file.")
        #expect(source.contains("let jobID: String") && source.contains("let loops: [String]"),
                "Message no longer carries the handles.")
    }

    /// One door onto the amber pulse, and the handle goes through it.
    /// `pendingNudge` is assigned in `queueReminder`, in `pose` (the preview
    /// harness) and in the places that clear it — never straight from a
    /// watcher, which is how the nudge.json path once bypassed the filter
    /// that lives in `queueReminder`. So the ONE call from the inbox
    /// watcher is the only place the handle can be lost, and this is that
    /// call.
    @Test func theInboxWatcherPassesTheHandleToQueueReminder() throws {
        let source = try #require(Self.conductor)
        // Every inbox file is `receive(m)` (docs/INBOX.md), which keeps the
        // message's handles on the item and its held-send expiry from
        // `NudgeHandle.forInbox(m)`; an action loads them back as the handle.
        #expect(count("receive(m)", in: source) == 1,
                "The inbox watcher no longer hands each message to receive, or has a second path.")
        #expect(source.contains("let handle = NudgeHandle.forInbox(m)"),
                "receive stopped building the handle from the message.")
        #expect(source.contains("var h = NudgeHandle(job: m.job, jobID: m.jobID,"),
                "forInbox stopped building the handle from the message.")
        for field in ["input.loops = m.loops", "input.said = m.said", "input.jobID = m.jobID",
                      "input.instruction = m.instruction", "input.offer = m.offer"] {
            #expect(source.contains(field), "receive no longer keeps \(field) on the item.")
        }
        #expect(source.contains("var h = NudgeHandle(job: n.job, jobID: n.jobID, loops: n.loops, said: n.said,"),
                "An item's action no longer rebuilds the handle it came with.")
    }

    // MARK: - And reach the brain

    /// Playing a nudge tells the brain what was said. It now also tells it
    /// what may be done about it — otherwise the model has the sentence and
    /// no way to act on the answer, which is exactly the reported bug.
    @Test func playingANudgeTellsTheBrainHowToChangeIt() throws {
        let source = try #require(Self.conductor)
        let start = try #require(source.range(of: "func playNudge()"))
        let end = try #require(source.range(of: "func dismissNudge()"))
        let body = String(source[start.upperBound..<end.lowerBound])
        // Through `handleNote`, which gives the handle's instruction — and, for
        // an offer, the fenced draft after the note, or none when not current.
        #expect(body.contains("handleNote(handle)"),
                "playNudge no longer tells the brain how to act on the answer.")
        #expect(body.contains("silent: true"), "The note is no longer a silent turn.")
        #expect(source.contains("guard !handle.offer.isEmpty else { return (handle.instruction, \"\") }"),
                "handleNote no longer hands a reminder's own instruction to the brain.")
    }

    /// Dismissing one tells the brain too. "Not now" is the commonest thing
    /// a person does with a pulse, and the message they waved away is the
    /// one they then refer to. Before this, × cleared it with no trace and
    /// the words were nowhere the model could see them.
    @Test func dismissingANudgeAlsoTellsTheBrain() throws {
        let source = try #require(Self.conductor)
        let start = try #require(source.range(of: "func dismissNudge()"))
        let rest = String(source[start.upperBound...])
        let end = try #require(rest.range(of: "\n    func "))
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("bridge.send"),
                "dismissNudge no longer tells the brain what was waved away.")
        #expect(body.contains("handleNote(handle)"),
                "dismissNudge no longer carries the handle.")
        #expect(body.contains("silent: true"),
                "The dismissal note must not be a turn the person hears an answer to.")
    }

    // MARK: - Cleared everywhere the words are

    /// A handle outliving its message is worse than none: it would point the
    /// next answer at the previous nudge's follow-up. Every assignment of
    /// `pendingNudge` has one of `pendingNudgeHandle` beside it.
    ///
    /// Per site, not by counting: two clears in the wrong two places
    /// balance a count and leave a handle alive across a nudge, which is
    /// precisely the bug.
    @Test func theHandleIsClearedWhereverTheWordsAre() throws {
        let source = try #require(Self.conductor)
        let clears = ["pendingNudge = nil", "pendingNudgeWhen = nil",
                      "pendingNudgeHandle = nil"]
        // The six places the words are dropped: played, replied to,
        // dismissed, "Let Moe get your attention" switched off, an offer
        // answered on its card (`clearNudge`, which says what they did
        // rather than that they waved it away), and a held send retired
        // unanswered a day after it was asked (`retireExpiredNudge`, which
        // must take its replay instruction with it).
        #expect(count(clears[0], in: source) == 6,
                "A place that drops the nudge appeared or went; check the handle there too.")
        for site in ["func playNudge()", "func replyToNudge(", "func dismissNudge()", "func setNudges(",
                     "func clearNudge(", "func retireExpiredNudge("] {
            let start = try #require(source.range(of: site))
            let rest = String(source[start.upperBound...])
            let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
            let body = String(rest[..<end])
            #expect(clears.allSatisfy { body.contains($0) },
                    "\(site) clears the nudge without clearing its handle.")
        }
    }

    /// Playing or dismissing on the Mac settles the copy that went to a
    /// phone. Without it a nudge dealt with here sits unanswered in the
    /// spool and is attached to an unrelated Telegram message that
    /// evening — the `said` id was written into the inbox file and read by
    /// nobody.
    @Test func theIslandSettlesTheCopyThatWentToAPhone() throws {
        let conductor = try #require(Self.conductor)
        let channels = try #require(Self.channels)
        #expect(channels.contains("said: obj[\"said\"] as? String ?? \"\""),
                "ReminderChannels stopped reading the spool id out of the inbox file.")
        #expect(channels.contains("static func markAnsweredOnScreen"),
                "The marker writer is gone.")
        #expect(count("markAnsweredOnScreen(handle?.said ?? \"\")", in: conductor) == 3,
                "Playing, replying and dismissing must all settle the phone's copy.")
    }

    // MARK: - Reply: the answer typed into the card

    /// The third thing on the card. On 2026-09-06 the owner hovered the
    /// island and typed "stop reminding me about that" into the ask field,
    /// where the words arrived with no card behind them. Reply puts the
    /// card's words and its handle in front of the answer, in the same
    /// turn — the Mac's version of what `followups.py` attaches to a
    /// Telegram reply.
    @Test func theCardOffersAReplyAndItCarriesTheHandle() throws {
        // The inbox row's Reply, and the card's box, reach the conductor,
        // which answers through `replyToNudge` with the item's handle.
        let inbox = try #require(Self.inbox)
        #expect(inbox.contains("InboxButton(\"Reply\", style: .quiet) { conductor.replyToNotice(n.id"),
                "The reminder row lost its Reply.")
        let card = try #require(Self.card)
        #expect(card.contains("conductor.replyToNotice(n.id, text: ask)"),
                "The card's box no longer reaches the conductor.")
        let c = try #require(Self.conductor)
        #expect(c.contains("replyToNudge(trimmed, shownAs: shown)"),
                "An item's reply no longer goes through replyToNudge and its handle.")

        let conductor = try #require(Self.conductor)
        let fn = try #require(conductor.range(of: "func replyToNudge("))
        let after = String(conductor[fn.upperBound...])
        let fnEnd = try #require(after.range(of: "\n    func "))
        let body = String(after[..<fnEnd.lowerBound])
        #expect(body.contains("handleNote(handle)"),
                "The reply no longer tells the brain how to act on the answer.")
        #expect(body.contains("nudgeReplyNote ="),
                "The card's words are no longer staged in front of the answer.")
        #expect(body.contains("submit(trimmed, origin: .typed, starter: .person)"),
                "The reply is no longer a turn of the person's own.")
        #expect(body.contains("guard !awaitingReply"),
                "A reply typed while Moe is busy would drop the card with the dropped turn.")
        // And `submit` actually reads it — a staged note nobody merges is
        // the exact shape of the bug this test file exists for.
        #expect(conductor.contains("if let replying = nudgeReplyNote {"),
                "submit no longer puts the card's words in front of the reply.")
    }

    /// The card sits under the panel's own ✕ and ⌃, not beneath them.
    ///
    /// It has a filled background, so the two floating chrome buttons landed
    /// INSIDE it and read as its own controls — one of them a ✕ four points
    /// from the card's own, meaning something else entirely. Reserving
    /// space on the card's first line was not enough; the buttons still sat
    /// on the fill. The card starts below them — or, on a notched Mac, the
    /// buttons move up into the band beside the notch and nothing is under
    /// them at all.
    ///
    /// The height half of this used to pin a flat `103` for the card, which
    /// was one line of sentence and nothing for the talk-key row: the ask
    /// field hanging off the panel in the owner's screenshot of 2026-09-14.
    /// The arithmetic is `ConversationPanel` now, tested on its own in
    /// ConversationPanelMetricsTests; what is checked here is that the view
    /// and the island are both wired to it.
    @Test func theNudgeCardStartsBelowThePanelsOwnButtons() throws {
        let view = try #require(Self.islandView)
        #expect(view.contains(".padding(.top, chromeInBand ? 0 : Self.chromeDrop)"),
                "The banners no longer clear the panel's own chrome.")
        #expect(view.contains("offset(y: chromeInBand ?"),
                "The chrome no longer moves into the band beside the notch.")
        #expect(view.contains("CGFloat(ConversationPanel.Metric.chromeDrop)"),
                "chromeDrop no longer comes from the metrics the height is counted with.")
        let island = try #require(Self.notch)
        #expect(island.contains("nudge: nil,") && island.contains("InboxLayout.height(rows: rows)"),
                "The panel's height no longer counts the inbox (and no card sits above the chat).")
        #expect(island.contains("offers.append(.init(text: accessibility"),
                "The panel's height no longer counts the talk-key row.")
    }

    /// One ✕, one meaning. Each inbox row's own ✕ dismisses it — finished,
    /// out of the count (docs/INBOX-QUIET.md) — and the other ways to finish
    /// it are words — Done, Got it — never a second glyph.
    @Test func theCardOffersAWordRatherThanASecondGlyph() throws {
        let body = try #require(Self.inbox)
        #expect(!body.contains("IslandButton"),
                "A circular panel button is back on an inbox row, beside the panel's own.")
        #expect(body.contains("InboxButton(\"Done\", style: .primary)"), "A reminder lost its Done.")
        #expect(body.contains("InboxButton(\"Got it\")"), "A brief lost its Got it.")
        #expect(body.contains("Button { conductor.dismissNotice(n.id) }"), "The row's ✕ no longer dismisses it.")
        #expect(body.contains("conductor.declineNotice(n.id, kind: true)"), "Ready work lost its Not this kind.")
    }

    /// The three shapes an answer can be acted on through, and the honest
    /// third one. A well-formed instruction naming a tool that cannot reach
    /// the thing would be worse than saying so — CLAUDE.md's "a well-formed
    /// identifier that resolves to nothing is more dangerous than an absent
    /// one".
    @Test func theInstructionNamesTheRightToolForEachKind() throws {
        let source = try #require(Self.conductor)
        let start = try #require(source.range(of: "var instruction: String {"))
        let rest = String(source[start.upperBound...])
        let end = try #require(rest.range(of: "\n    }"))
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("moe_followups"),
                "A follow-up Moe raised is changed with the moe_followups tool.")
        #expect(body.contains("cronjob tool"),
                "A reminder the person asked for is a Hermes cron.")
        #expect(body.contains("no handle on this one"),
                "With nothing to act on, Moe has to say so rather than pretend.")
        // And the one the review caught: `moe-proactive` IS a cron job with
        // a job id, and it says plenty that opens no loop. Pointing "don't
        // tell me about that any more" at `cronjob remove` on that id
        // deletes the whole proactive pass because one sentence out of it
        // was unwelcome.
        #expect(body.contains("!isMoeJob"),
                "Moe's own background jobs must not be offered to the cronjob tool.")
        #expect(body.contains("Do not touch any cron job"),
                "There is no wording steering the model away from the engine's own job.")
        #expect(source.contains("hasPrefix(\"moe-\")"),
                "The moe- rule that tells Moe's own jobs from the person's reminders is gone.")
    }
}
