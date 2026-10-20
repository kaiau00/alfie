import Foundation
import Testing
import MoeChat
@testable import MoeLedger

/// The projection: `~/.moe/conversations/` rebuilt from records.
///
/// The bet this slice exists to test is that a person's threads can be
/// reconstructed from small records and still be recognisably theirs. These
/// are the tests that would falsify it.
struct ConversationProjectionTests {

    private func fixture() -> (ConversationLedger, ConversationStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-projection-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let ledger = Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test")
        return (ConversationLedger(ledger: ledger, store: store), store, root)
    }

    private func conversation(id: String = UUID().uuidString) -> ConversationStore.Conversation {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return ConversationStore.Conversation(
            id: id, startedAt: start, updatedAt: start.addingTimeInterval(90),
            turns: [
                .init(role: .you, text: "what's in the Vasquez deck?", at: start),
                .init(role: .moe, text: "Twelve slides; the ask is on nine.",
                      at: start.addingTimeInterval(30), tools: ["Reading your files"]),
                .init(role: .you, text: "what's the ask?", at: start.addingTimeInterval(60)),
                .init(role: .moe, text: "Two million, on a twelve-month runway.",
                      at: start.addingTimeInterval(90)),
            ])
    }

    // MARK: Round trip

    @Test func theProjectorRebuildsAConversationFromRecords() throws {
        let (ledger, _, _) = fixture()
        let original = conversation()
        try ledger.save(original)

        let rebuilt = try #require(ledger.projector.project(thread: original.id))
        #expect(rebuilt.id == original.id)
        #expect(rebuilt.startedAt == original.startedAt)
        #expect(rebuilt.turns == original.turns)
        #expect(rebuilt.title == original.title)
    }

    /// A photo handed over with a message comes back with the thread, and its
    /// name and path are sealed like the words: a file called "Biopsy
    /// results.pdf" says as much as the sentence it was sent with.
    @Test func attachmentsSurviveTheProjectionAndAreSealed() throws {
        let (ledger, _, _) = fixture()
        var original = conversation()
        let photo = ChatAttachment(id: "photo-1", path: "/Users/sam/Desktop/Biopsy results.pdf",
                                   byteCount: 512_000)
        original.turns.append(.init(role: .you, text: "", at: original.updatedAt.addingTimeInterval(10),
                                    attachments: [photo]))
        try ledger.save(original)

        let rebuilt = try #require(ledger.projector.project(thread: original.id))
        #expect(rebuilt.turns.last?.attachments == [photo])

        let everything = ledger.ledger.all().map { "\($0.body)" }.joined()
        #expect(!everything.isEmpty)
        #expect(!everything.contains("Biopsy"))
    }

    @Test func deletingTheProjectionAndRebuildingRestoresIt() throws {
        let (ledger, store, _) = fixture()
        let original = conversation()
        try ledger.save(original)
        let onDisk = try #require(store.load(id: original.id))

        // The repair path of §8: the projection is disposable, the ledger is not.
        try store.deleteAll()
        #expect(store.all().isEmpty)
        #expect(try ledger.rebuild() == 1)

        #expect(store.load(id: original.id) == onDisk)
    }

    @Test func savingTheSameThreadTwiceAppendsNothingTheSecondTime() throws {
        let (ledger, _, _) = fixture()
        let convo = conversation()
        try ledger.save(convo)
        let after = ledger.ledger.all().count
        try ledger.save(convo)

        // Content-addressed ids make replay a no-op; a save that grew the
        // ledger every time would double a person's history on every turn.
        #expect(ledger.ledger.all().count == after)
    }

    @Test func newTurnsAreAppendedAndProjectedInOrder() throws {
        let (ledger, store, _) = fixture()
        var convo = conversation()
        try ledger.save(convo)
        convo.turns.append(.init(role: .you, text: "and the runway slide?",
                                 at: Date(timeIntervalSince1970: 1_700_000_200)))
        try ledger.save(convo)

        let projected = try #require(store.load(id: convo.id))
        #expect(projected.turns.count == 5)
        #expect(projected.turns.last?.text == "and the runway slide?")
        #expect(ledger.projector.turnRecords(thread: convo.id).count == 5)
    }

    @Test func turnsStampedTheSameSecondKeepTheOrderTheyWereSaidIn() throws {
        let (ledger, _, _) = fixture()
        // Not a contrivance: this is what every real thread looks like. The
        // reply is filed with the question's timestamp, so a projector that
        // breaks ties on anything but write order answers before it is asked.
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let convo = ConversationStore.Conversation(
            startedAt: at, updatedAt: at,
            turns: [
                .init(id: "ZZZ-asked-first", role: .you, text: "is the deck ready?", at: at),
                .init(id: "AAA-answered", role: .moe, text: "Yes, as of this morning.", at: at),
            ])
        try ledger.save(convo)

        let rebuilt = try #require(ledger.projector.project(thread: convo.id))
        #expect(rebuilt.turns.map(\.text) == ["is the deck ready?", "Yes, as of this morning."])
    }

    @Test func aReplyStampedBeforeItsQuestionStaysAfterIt() throws {
        let (ledger, _, _) = fixture()
        // Not hypothetical on one machine with no cloud in it: an NTP
        // correction or someone changing the date steps the clock backwards
        // between two turns, and the wall clock then says the answer came
        // first. Causality says otherwise, and causality is what is recorded.
        let asked = Date(timeIntervalSince1970: 1_700_000_000)
        let convo = ConversationStore.Conversation(
            startedAt: asked, updatedAt: asked,
            turns: [
                .init(role: .you, text: "asked", at: asked),
                .init(role: .moe, text: "answered", at: asked.addingTimeInterval(-1_000)),
            ])
        try ledger.save(convo)

        let rebuilt = try #require(ledger.projector.project(thread: convo.id))
        #expect(rebuilt.turns.map(\.text) == ["asked", "answered"])
    }

    @Test func aClockThatStepsBackwardsDoesNotReorderTheLedger() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-projection-tests-\(UUID().uuidString)", isDirectory: true)
        let ledger = Ledger(directory: root, device: "mac-test")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // One device, one thread, and the clock moves backwards mid-thread.
        // The per-device `prev` chain is causality and outranks the clock.
        let first = try ledger.append(kind: LedgerRecord.Kind.turn,
                                      body: .of(["thread": .string("th-1"), "n": .int(1)]), at: now)
        let second = try ledger.append(kind: LedgerRecord.Kind.turn,
                                       body: .of(["thread": .string("th-1"), "n": .int(2)]),
                                       at: now.addingTimeInterval(-3_600))

        #expect(Ledger(directory: root, device: "mac-test").all().map(\.id) == [first.id, second.id])
    }

    @Test func aTurnWhoseRoleIsFromANewerVersionIsShownRatherThanDropped() throws {
        let (ledger, _, _) = fixture()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let convo = conversation()
        try ledger.save(convo)

        // A later Moe adds a role this build has never heard of. The record
        // layer keeps every byte of it; the projection must not be the place
        // a person's words quietly disappear.
        try ledger.ledger.append(kind: LedgerRecord.Kind.turn, body: .of([
            "thread": .string(convo.id),
            "turn_id": .string("from-the-future"),
            "role": .string("witness"),
            "text": .string("something a later version said"),
            "at": .string(LedgerRecord.timestamps.string(from: at.addingTimeInterval(500))),
        ]), after: ledger.projector.head(thread: convo.id))

        let projected = try #require(ledger.projector.project(thread: convo.id))
        let carried = try #require(projected.turns.first { $0.id == "from-the-future" })
        #expect(carried.text == "something a later version said")
        #expect(carried.role == .system)
    }

    // MARK: Deletion

    @Test func aDeletedThreadStaysDeletedWhenTheProjectionIsRebuilt() throws {
        let (ledger, store, _) = fixture()
        let convo = conversation()
        try ledger.save(convo)
        try ledger.delete(id: convo.id)

        #expect(store.load(id: convo.id) == nil)
        #expect(try ledger.rebuild() == 0)
        #expect(store.load(id: convo.id) == nil)
    }

    // MARK: Nobody's existing setup breaks

    @Test func aMoeHomeWithNoLedgerStillWorksAndIsNotDamaged() throws {
        let (ledger, store, root) = fixture()

        // What a person has today: conversations on disk, no ledger anywhere.
        let existing = (0..<3).map { i -> ConversationStore.Conversation in
            var c = conversation()
            c.turns[0].text = "thread \(i)"
            return c
        }
        for c in existing { try store.save(c) }
        let before = store.all()
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ledger").path))

        // Nothing has been recorded, so there is nothing to project — and the
        // rebuild must not treat "no records" as "delete their history".
        #expect(try ledger.rebuild() == 0)
        #expect(store.all() == before)

        // Opening one imports that thread, and only that thread.
        let opened = existing[1]
        _ = ledger.resume(thread: opened.id, brain: "hermes/test",
                          knownTurns: opened.turns, startedAt: opened.startedAt)
        #expect(ledger.projector.threads() == [opened.id])
        #expect(store.all() == before)

        // And what comes back out is what went in.
        let projected = try #require(ledger.projector.project(thread: opened.id))
        #expect(projected.turns == opened.turns)
        #expect(projected.startedAt == opened.startedAt)
    }

    @Test func importingAThreadTwiceRecordsItOnce() throws {
        let (ledger, _, _) = fixture()
        let legacy = conversation()
        _ = ledger.resume(thread: legacy.id, brain: "hermes/test", knownTurns: legacy.turns)
        let count = ledger.ledger.all().count
        _ = ledger.resume(thread: legacy.id, brain: "hermes/test", knownTurns: legacy.turns)
        #expect(ledger.ledger.all().count == count)
    }

    /// The same upgrade path, run against a real corpus rather than a made-up
    /// one — the falsifier §10 names for this slice is that a person's own
    /// threads do not come back in a form they recognise.
    ///
    /// Runs only when `MOE_LEDGER_FIXTURE_DIR` points at a *copy* of a
    /// `conversations/` directory; the trait makes it report as skipped
    /// rather than as a pass, so a green run without it cannot be mistaken
    /// for evidence. Tests never read anybody's real `~/.moe`.
    ///
    /// Nothing in here prints a turn. These are somebody's actual
    /// conversations, and a failing `#expect` prints both of its operands —
    /// so what is compared is counts, ids and fields, and what is reported on
    /// failure is an index.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOE_LEDGER_FIXTURE_DIR"] != nil))
    func realThreadsProjectBackToThemselves() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOE_LEDGER_FIXTURE_DIR"])
        let source = ConversationStore(directory: URL(fileURLWithPath: path))
        let existing = source.all()
        #expect(!existing.isEmpty, "MOE_LEDGER_FIXTURE_DIR has no conversations in it")

        let (ledger, store, _) = fixture()
        for convo in existing { try store.save(convo) }
        for (n, convo) in existing.enumerated() {
            _ = ledger.resume(thread: convo.id, brain: "hermes/test",
                              knownTurns: convo.turns, startedAt: convo.startedAt)
            guard let projected = ledger.projector.project(thread: convo.id) else {
                Issue.record("thread \(n) did not come back at all")
                continue
            }
            #expect(projected.turns.count == convo.turns.count, "thread \(n): turn count")
            #expect(projected.startedAt == convo.startedAt, "thread \(n): start time")
            // Computed outside the macro: a title is the person's own first
            // sentence, and #expect prints what it is given.
            let titleMatches = projected.title == convo.title
            #expect(titleMatches, "thread \(n): title")
            for (i, pair) in zip(projected.turns, convo.turns).enumerated() {
                let (got, want) = pair
                let same = got.id == want.id && got.role == want.role
                    && got.text == want.text && got.at == want.at && got.tools == want.tools
                #expect(same, "thread \(n), turn \(i) differs")
                if !same { break }
            }
        }
        try ledger.rebuild()
        #expect(Set(store.all().map(\.id)) == Set(existing.map(\.id)))
    }

    @Test func aLedgerFailureDoesNotCostTheConversation() throws {
        // The ledger directory is a file, so every append fails.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-projection-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerDir = root.appendingPathComponent("ledger")
        try Data("not a directory".utf8).write(to: ledgerDir)

        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let ledger = ConversationLedger(ledger: Ledger(directory: ledgerDir, device: "mac-test"),
                                        store: store)
        let convo = conversation()
        #expect(throws: (any Error).self) { try ledger.save(convo) }
        // The thread is still filed. Losing the conversation a person just had
        // would be a far worse bug than the one this slice is fixing.
        #expect(store.load(id: convo.id)?.turns.count == 4)
    }
}
