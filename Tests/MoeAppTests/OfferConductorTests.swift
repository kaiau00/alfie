import Foundation
import Testing
@testable import Moe

/// The island's offer card driven through the real Conductor (re-review of
/// the offer path, #1–#4, #8, #9): the stand-in brain records what it is
/// sent; the situation file, the send gate's marker and the WhatsApp
/// connector are real files in the scratch home.
@MainActor
@Suite(.serialized)
struct OfferConductorTests {
    static let draft = "Hi Mordecai, we agreed on Sept 22."

    static func situations(status: String = "offered", source: String = "composio/gmail",
                           thread: String = "18a1f00", version: String = "v1", offeredFor: String = "v1") -> String {
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        return """
        {"sit_1": {"title": "Chicken order payment", "thread_name": "Mordecai", "source": "\(source)",
                   "thread": "\(thread)", "status": "\(status)",
                   "offered": {"for": "\(offeredFor)", "at": "\(at)"},
                   "prepared": {"offer": "A reply is ready.", "for": "\(version)",
                                "draft": "\(draft)"}}}
        """
    }

    static func write(_ text: String) throws {
        let url = SituationOffer.situationsURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static let note = "This was an offer Moe made on its own.\n========\n\(draft)\n========\nSend exactly that."

    static func make() throws -> (Conductor, FakeBrain) {
        let (moe, brain) = try StallGuardConductorTests.make()
        SituationOffer.clearOfferSend()
        try? FileManager.default.removeItem(at: SituationOffer.feedbackURL)
        return (moe, brain)
    }

    /// The offer arrives in the inbox and is opened (docs/INBOX.md): the
    /// item is the one being acted on, and its offer loads as it always did.
    static func offer(_ moe: Conductor) {
        moe.queueReminder("A reply is ready.", handle: .init(job: "moe-situations", jobID: "", loops: [],
                                                             said: "", note: note, offer: "sit_1"))
        if let item = moe.notices.first(where: { $0.offer == "sit_1" && $0.status == .open }) {
            moe.focusNotice(item.id)
        }
    }

    static func until(_ what: @autoclosure () -> Bool) async throws {
        for _ in 0..<300 where !what() { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(what())
    }

    static func marker() -> [String: Double]? {
        (try? Data(contentsOf: SituationOffer.markerURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] }
    }

    @Test("the marker is written where, and in the shape, the send gate reads it")
    func markerContract() throws {
        _ = try Self.make()
        #expect(SituationOffer.markerURL == Paths.home.appendingPathComponent("gate/offer-send.json"))
        SituationOffer.markOfferSend(for: 600)
        let m = try #require(Self.marker())
        #expect(m["until"]! - m["at"]! == 600)
        let hook = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/MoeAppTests/OfferConductorTests.swift", with: "moe-home/hermes/hooks/confirm-send.sh"),
            encoding: .utf8)
        #expect(hook.contains("os.path.join(h, \"gate\", \"offer-send.json\")"))
        #expect(hook.contains("d.get(\"until\")"))
        #expect(hook.contains("Application Support/Moe"), "the gate reads the app's own home, not only the link")
        SituationOffer.clearOfferSend()
        #expect(Self.marker() == nil)
    }

    /// A service with no direct route (a plain MCP server; every Composio
    /// service now sends through lib/composio_send.py) goes through the brain.
    @Test("Use draft (no direct route): one fenced request, however many taps; the gate marked while its turn runs, cleared after")
    func useDraftThroughTheBrain() async throws {
        let (moe, brain) = try Self.make()
        try Self.write(Self.situations(source: "mcp/linear"))
        Self.offer(moe)
        try await Self.until(moe.offerCard == .current)
        moe.useOfferDraft()
        moe.useOfferDraft()
        try await brain.waitForSends(1)
        try await Task.sleep(nanoseconds: 200_000_000)
        let asks = brain.sent.filter { !$0.silent }
        #expect(asks.count == 1, "one send per card")
        #expect(asks[0].text.contains("id 18a1f00") && asks[0].text.contains("========\n\(Self.draft)\n========"))
        #expect(Self.marker() != nil, "the send gate knows this turn carries an offer's send")
        brain.reply("Sent.", end: .answered)
        try await Self.until(Self.marker() == nil)
        let feedback = (try? String(contentsOf: SituationOffer.feedbackURL, encoding: .utf8)) ?? ""
        #expect(feedback.contains("chose-to-send") && !feedback.contains("\"used\""))
    }

    @Test("Use draft (WhatsApp): the app sends it itself, to the jid, and records used only when it went")
    func useDraftDirectly() async throws {
        for (exit, sent) in [(0, true), (1, false)] {
            let (moe, brain) = try Self.make()
            let dir = Paths.home.appendingPathComponent("connectors")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let args = Paths.home.appendingPathComponent("wa-args.txt")
            try? FileManager.default.removeItem(at: args)
            let script = dir.appendingPathComponent("whatsapp.sh")
            try "#!/bin/bash\nprintf '%s\\n' \"$@\" > '\(args.path)'\ncat >> '\(args.path)'\nexit \(exit)\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try Self.write(Self.situations(source: "native/whatsapp", thread: "15551230001@s.whatsapp.net"))
            Self.offer(moe)
            try await Self.until(moe.offerCard == .current)
            moe.useOfferDraft()
            try await Self.until(moe.turns.contains { $0.text == (sent ? "Sent to Mordecai on WhatsApp." : "Not sent.") })
            let got = try String(contentsOf: args, encoding: .utf8)
            // `send-offer`, the chat and the words on stdin from the app's own
            // memory (whatsapp.sh checks the app's signature and the age).
            let lines = got.split(separator: "\n", maxSplits: 1).map(String.init)
            #expect(lines.first == "send-offer")
            let rec = try #require(try JSONSerialization.jsonObject(with: Data((lines.last ?? "").utf8)) as? [String: Any])
            #expect(rec["jid"] as? String == "15551230001@s.whatsapp.net")
            #expect(rec["body"] as? String == Self.draft)
            #expect(brain.sent.filter { !$0.silent }.isEmpty, "no model in between")
            let feedback = (try? String(contentsOf: SituationOffer.feedbackURL, encoding: .utf8)) ?? ""
            #expect(feedback.contains("\"used\"") == sent)
        }
    }

    @Test("a card whose offer is no longer current shows Dismiss only, and hands the brain no draft")
    func staleCard() async throws {
        let (moe, brain) = try Self.make()
        try Self.write(Self.situations(status: "resolved"))
        Self.offer(moe)
        try await Self.until(moe.offerCard == .gone)
        #expect(moe.cardIsOffer && moe.pendingOffer == nil)
        moe.dismissOffer()
        let note = try #require(brain.sent.last)
        #expect(note.silent && !note.text.contains(Self.draft))
        // Played by voice or keyboard instead: the note carries no draft either.
        Self.offer(moe)
        try await Self.until(moe.offerCard == .gone)
        moe.playNudge()
        #expect(!(brain.sent.last?.text.contains(Self.draft) ?? true))
        #expect(Self.marker() == nil)
    }

    @Test("Use draft sends only the version on the card: redrafted since, nothing is sent")
    func redraftedSinceTheCard() async throws {
        let (moe, brain) = try Self.make()
        try Self.write(Self.situations())
        Self.offer(moe)
        try await Self.until(moe.offerCard == .current)
        try Self.write(Self.situations(version: "v2", offeredFor: "v2"))
        moe.useOfferDraft()
        try await Self.until(moe.turns.contains { $0.text.hasPrefix("That offer is no longer current") })
        #expect(brain.sent.filter { !$0.silent }.isEmpty)
    }

    @Test("See it: the draft goes after the note's parentheses, and the gate is marked for the send that may follow")
    func seeIt() async throws {
        let (moe, brain) = try Self.make()
        try Self.write(Self.situations())
        Self.offer(moe)
        try await Self.until(moe.offerCard == .current)
        moe.seeOffer()
        let note = try #require(brain.sent.last)
        let close = try #require(note.text.range(of: "Do not reply to this message.)"))
        let draftAt = try #require(note.text.range(of: Self.draft))
        #expect(close.upperBound <= draftAt.lowerBound, "the draft is outside the parentheses")
        let m = try #require(Self.marker())
        #expect(m["until"]! - m["at"]! == SituationOffer.contextLife)
        #expect(moe.turns.last?.text.contains(Self.draft) == true)
    }
}
