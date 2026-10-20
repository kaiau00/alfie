import Foundation
import CryptoKit
import Testing
import MoeChat
@testable import MoeLedger

/// Per-thread encryption, and Delete as the destruction of a key.
///
/// The ledger is append-only, so a record cannot be unwritten. These tests
/// are about the consequence the founder decided on: the words are sealed
/// with a key that can be destroyed, so deleting a conversation makes it
/// unrecoverable while leaving the record other records point at intact.
struct EncryptionTests {

    private func fixture() -> (ConversationLedger, ConversationStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-crypto-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let ledger = Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test")
        return (ConversationLedger(ledger: ledger, store: store), store, root)
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func conversation(_ opener: String = "what's in the Vasquez deck?")
        -> ConversationStore.Conversation {
        ConversationStore.Conversation(
            startedAt: start, updatedAt: start.addingTimeInterval(30),
            turns: [
                .init(role: .you, text: opener, at: start),
                .init(role: .moe, text: "Twelve slides; the ask is on nine.",
                      at: start.addingTimeInterval(30), tools: ["Reading your files"]),
            ])
    }

    private func ledgerText(_ root: URL) -> String {
        let dir = root.appendingPathComponent("ledger")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined()
    }

    // MARK: The seal

    @Test func aTurnRoundTripsThroughEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try ThreadCrypto.seal("the ask is on slide nine", with: key)
        #expect(!sealed.contains("slide"))
        #expect(ThreadCrypto.open(sealed, with: key) == "the ask is on slide nine")
    }

    @Test func theSameSentenceSealsDifferentlyEveryTime() throws {
        let key = SymmetricKey(size: .bits256)
        // A fresh nonce per field: two records of the same sentence must not
        // be recognisable as the same sentence by anyone holding the ledger.
        #expect(try ThreadCrypto.seal("hello", with: key) != ThreadCrypto.seal("hello", with: key))
    }

    @Test func anotherThreadsKeyOpensNothing() throws {
        let mine = SymmetricKey(size: .bits256)
        let theirs = SymmetricKey(size: .bits256)
        let sealed = try ThreadCrypto.seal("private", with: mine)
        #expect(ThreadCrypto.open(sealed, with: theirs) == nil)
        #expect(ThreadCrypto.open(sealed, with: nil) == nil)
        #expect(ThreadCrypto.open("not base64 at all", with: mine) == nil)
    }

    @Test func whatIsWrittenToDiskDoesNotContainTheWords() throws {
        let (ledger, _, root) = fixture()
        let convo = conversation("the private thing I said")
        try ledger.save(convo)

        let raw = ledgerText(root)
        #expect(!raw.contains("the private thing I said"))
        #expect(!raw.contains("Twelve slides"))
        #expect(!raw.contains("Reading your files"))
        #expect(raw.contains(ThreadCrypto.scheme))
        // And what ordering depends on is still legible in it.
        #expect(raw.contains(convo.id))
        #expect(raw.contains("\"seq\":1"))
        #expect(raw.contains("\"role\":\"you\""))

        // It comes back for the person who holds the key.
        let projected = try #require(ledger.projector.project(thread: convo.id))
        #expect(projected.turns.map(\.text) == convo.turns.map(\.text))
        #expect(projected.turns[1].tools == ["Reading your files"])
    }

    // MARK: Delete

    @Test func deletingAThreadDestroysItsKeyAndItsWords() throws {
        let (ledger, store, root) = fixture()
        let convo = conversation()
        try ledger.save(convo)
        #expect(ledger.keyring.has(thread: convo.id))

        try ledger.delete(id: convo.id)

        // The key is gone, the file is gone, and the thread does not project.
        #expect(!ledger.keyring.has(thread: convo.id))
        #expect(store.load(id: convo.id) == nil)
        #expect(ledger.projector.project(thread: convo.id) == nil)
        // The records are still there — other records point at them.
        #expect(!ledger.projector.records(thread: convo.id).isEmpty)
        // And nothing on disk can be turned back into what was said.
        #expect(!ledgerText(root).contains("Vasquez"))
    }

    @Test func aThreadWhoseKeyIsGoneProjectsAsDeletedRatherThanThrowing() throws {
        let (ledger, _, _) = fixture()
        let convo = conversation()
        try ledger.save(convo)

        // The key destroyed without the delete record — a keyring restored
        // from an older copy, or edited by hand. It must still be calm.
        try ledger.keyring.destroy(thread: convo.id)

        #expect(ledger.projector.project(thread: convo.id) == nil)
        #expect(ledger.projector.unreadableThreads() == [convo.id])
        #expect(throws: Never.self) { try ledger.rebuild() }
    }

    @Test func deletingOneThreadLeavesEveryOtherThreadReadable() throws {
        let (ledger, store, _) = fixture()
        let kept = (0..<3).map { conversation("thread \($0)") }
        for convo in kept { try ledger.save(convo) }
        let doomed = conversation("the one to go")
        try ledger.save(doomed)

        try ledger.delete(id: doomed.id)

        for convo in kept {
            let projected = try #require(ledger.projector.project(thread: convo.id))
            #expect(projected.turns.map(\.text) == convo.turns.map(\.text))
        }
        #expect(try ledger.rebuild() == kept.count)
        #expect(Set(store.all().map(\.id)) == Set(kept.map(\.id)))
    }

    @Test func aDeletedThreadIsNeverPrimedBackIntoTheBrain() throws {
        let (ledger, _, _) = fixture()
        let convo = conversation()
        try ledger.save(convo)
        try ledger.delete(id: convo.id)

        // Even handed the turns from somewhere else, resume must not put a
        // deleted conversation in front of the thing that would remember it.
        let resume = ledger.resume(thread: convo.id, brain: "hermes/test",
                                   knownTurns: convo.turns, startedAt: convo.startedAt)
        #expect(resume.priming == nil)
    }

    @Test func aSaveCannotResurrectADeletedThread() throws {
        let (ledger, store, _) = fixture()
        let convo = conversation()
        try ledger.save(convo)
        try ledger.delete(id: convo.id)

        // The ledger holds this thread and will not open it. Falling back to
        // the caller's copy here would undo the deletion and write the words
        // back to disk in the clear.
        try ledger.save(convo)
        #expect(store.load(id: convo.id) == nil)
    }

    // MARK: Ordering does not depend on being able to read

    @Test func orderingSurvivesEveryTextBeingUnreadable() throws {
        let (ledger, _, root) = fixture()
        var convo = conversation()
        try ledger.save(convo)
        convo.turns.append(.init(role: .you, text: "and the runway slide?",
                                 at: start.addingTimeInterval(60)))
        try ledger.save(convo)
        let orderBefore = ledger.ledger.all().map(\.id)

        // Destroy every key; the chain must be exactly as it was.
        try ledger.keyring.destroy(thread: convo.id)
        let cold = Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test")
        #expect(cold.all().map(\.id) == orderBefore)
        #expect(cold.gapsForThisDevice().isEmpty)
        // seq/prev/after are all still readable without any key at all.
        let records = cold.all()
        #expect(records[1].prev == records[0].id)
        #expect(records[1].after == [records[0].id])
    }

    // MARK: Both shapes

    @Test func aPlaintextRecordWrittenBeforeThisChangeStillReads() throws {
        let (ledger, _, _) = fixture()
        let at = start
        let thread = "th-from-before-the-keyring"
        // Exactly the shape the first version of this slice wrote.
        try ledger.ledger.append(kind: LedgerRecord.Kind.turn, body: .of([
            "thread": .string(thread),
            "thread_started_at": .string(LedgerRecord.timestamps.string(from: at)),
            "turn_id": .string("turn-1"),
            "role": .string("you"),
            "text": .string("said before there were keys"),
            "at": .string(LedgerRecord.timestamps.string(from: at)),
            "tools": .array([.string("Reading your files")]),
            "source": .string("live"),
        ]))

        // No key exists for it and none is needed.
        #expect(!ledger.keyring.has(thread: thread))
        let projected = try #require(ledger.projector.project(thread: thread))
        #expect(projected.turns.first?.text == "said before there were keys")
        #expect(projected.turns.first?.tools == ["Reading your files"])
        // And it is not counted as unreadable, because it is not.
        #expect(ledger.projector.unreadableThreads().isEmpty)
    }

    @Test func aThreadCanHoldBothShapesAtOnce() throws {
        let (ledger, _, _) = fixture()
        let thread = "th-mixed"
        try ledger.ledger.append(kind: LedgerRecord.Kind.turn, body: .of([
            "thread": .string(thread),
            "thread_started_at": .string(LedgerRecord.timestamps.string(from: start)),
            "turn_id": .string("old"),
            "role": .string("you"),
            "text": .string("from before"),
            "at": .string(LedgerRecord.timestamps.string(from: start)),
            "source": .string("live"),
        ]))
        // Saving it now seals only what is new; the old record is untouched,
        // because nothing in an append-only log is ever rewritten.
        var convo = ConversationStore.Conversation(id: thread, startedAt: start, updatedAt: start,
                                                   turns: [.init(id: "old", role: .you,
                                                                 text: "from before", at: start)])
        convo.turns.append(.init(role: .moe, text: "and from after",
                                 at: start.addingTimeInterval(10)))
        try ledger.save(convo)

        let projected = try #require(ledger.projector.project(thread: thread))
        #expect(projected.turns.map(\.text) == ["from before", "and from after"])
    }

    // MARK: The keyring itself

    @Test func theKeyringIsPrivateAndSaysWhatItIs() throws {
        let (ledger, _, root) = fixture()
        try ledger.save(conversation())

        let url = root.appendingPathComponent("ledger/thread-keys.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let text = try String(contentsOf: url, encoding: .utf8)
        // A person who opens this file must not have to guess what it does.
        #expect(text.contains("permanently destroys"))
        #expect(text.contains("Nobody else has a copy"))
        // And, since the cloud exists, must not have to guess how to get a
        // second copy either. `docs/ONE-AGENT.md` §15.1 settles that there is
        // no escrow and no reset, which makes "enrol another Mac, or copy
        // this file yourself" the whole of the answer — and the only moment
        // it is any use to a person is *before* they lose it.
        #expect(text.contains("no reset"))
        #expect(text.contains("enrol another Mac"))
        #expect(text.contains("device-identity.json"))
    }

    @Test func anAbsentKeyringLeavesEverythingWorking() throws {
        let (ledger, _, root) = fixture()
        let convo = conversation()
        try ledger.save(convo)

        // Someone deletes the keyring: every thread becomes unreadable, and
        // nothing throws, hangs or refuses to start.
        try FileManager.default.removeItem(at: root.appendingPathComponent("ledger/thread-keys.json"))
        let fresh = ConversationLedger(
            ledger: Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test"),
            store: ConversationStore(directory: root.appendingPathComponent("conversations")))

        #expect(fresh.projector.project(thread: convo.id) == nil)
        #expect(fresh.projector.unreadableThreads() == [convo.id])
        #expect(throws: Never.self) { try fresh.rebuild() }
        // And a new thread still works, on a keyring built from nothing.
        let next = conversation("a new one")
        #expect(throws: Never.self) { try fresh.save(next) }
        #expect(fresh.projector.project(thread: next.id)?.turns.count == 2)
    }

    @Test func aCorruptKeyringIsKeptOnceAndDoesNotStopAnything() throws {
        let (ledger, _, root) = fixture()
        try ledger.save(conversation())
        let url = root.appendingPathComponent("ledger/thread-keys.json")
        try Data("{ this was a keyring once".utf8).write(to: url)

        var told: [String] = []
        let fresh = ConversationLedger(
            ledger: Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test"),
            store: ConversationStore(directory: root.appendingPathComponent("conversations")),
            note: { told.append($0) })

        // Reading it yields no keys rather than an error.
        #expect(fresh.keyring.key(for: "anything") == nil)
        // Writing preserves what could not be read rather than clobbering it,
        // and says so. This is never done to a file that parsed, so it can
        // never hold a key somebody destroyed on purpose.
        let next = conversation("after the damage")
        try fresh.save(next)
        let kept = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("ledger").path)
            .filter { $0.contains("damaged") }
        #expect(kept.count == 1)
        #expect(told.contains { $0.contains("could not be read") })
        #expect(fresh.projector.project(thread: next.id)?.turns.count == 2)
    }

    @Test func aKeyringThatCannotBeOpenedLeavesEverythingWorking() throws {
        let (ledger, _, root) = fixture()
        let convo = conversation()
        try ledger.save(convo)
        let url = root.appendingPathComponent("ledger/thread-keys.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: url.path) }

        let fresh = ConversationLedger(
            ledger: Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test"),
            store: ConversationStore(directory: root.appendingPathComponent("conversations")))
        #expect(fresh.projector.project(thread: convo.id) == nil)
        #expect(throws: Never.self) { try fresh.rebuild() }
    }

    @Test func aKeyOrphanedByACrashMidDeleteIsDropped() throws {
        let (ledger, _, _) = fixture()
        let convo = conversation()
        try ledger.save(convo)

        // The delete record landed and then the process died before the key
        // was destroyed. The thread is already hidden; the key must not linger.
        try ledger.ledger.append(kind: LedgerRecord.Kind.threadDelete,
                                 body: .of(["thread": .string(convo.id)]),
                                 after: ledger.projector.head(thread: convo.id))
        #expect(ledger.keyring.has(thread: convo.id))

        try ledger.rebuild()
        #expect(!ledger.keyring.has(thread: convo.id))
    }

    @Test func aDestroyThatCannotBeWrittenDoesNotPretendToHaveHappened() throws {
        let (ledger, _, root) = fixture()
        let convo = conversation()
        try ledger.save(convo)
        let dir = root.appendingPathComponent("ledger")

        // The keyring cannot be rewritten — a full disk, a permissions
        // problem. Forgetting the key in memory anyway would show the person
        // a deleted conversation again after the next restart.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: dir.path) }

        #expect(throws: (any Error).self) { try ledger.keyring.destroy(thread: convo.id) }
        #expect(ledger.keyring.has(thread: convo.id))
        #expect(ledger.projector.project(thread: convo.id)?.turns.count == 2)
    }

    @Test func aKeyThatCannotBeWrittenIsNotUsedToSealAnything() throws {
        let (ledger, store, root) = fixture()
        let dir = root.appendingPathComponent("ledger")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: dir.path) }

        // A key held only in memory would seal turns that nothing could open
        // after a restart. The save fails instead — and the conversation is
        // still filed, because losing it would be worse than either.
        let convo = conversation()
        #expect(throws: (any Error).self) { try ledger.save(convo) }
        #expect(!ledger.keyring.has(thread: convo.id))
        #expect(store.load(id: convo.id)?.turns.count == 2)
    }

    @Test func aThreadThatWasNeverSpokenInHasNoKey() throws {
        let (ledger, _, _) = fixture()
        _ = ledger.resume(thread: "th-never-used", brain: "hermes/test")
        #expect(!ledger.keyring.has(thread: "th-never-used"))
    }
}
