import Foundation
import CryptoKit
import Testing
import MoeChat
@testable import MoeLedger

/// LEDGER-WIRE §13.2–§13.5: the memory key, the plaintext rule for every
/// kind, sealed claims, and documents.
///
/// What is being protected here is the same thing §12 protects for turns —
/// that the words never leave the machine in the clear, and that the one key
/// which opens them cannot be destroyed by a record. Memory is worse to lose
/// than a conversation: a thread has a person who remembers it, and a
/// person's facts about themselves are the thing that would be remembering.
struct MemoryRecordTests {

    private func root(_ label: String) -> URL { scratchRoot("memory-" + label) }

    private func fixture(_ label: String, device: String = "mac-a")
        -> (ledger: Ledger, keyring: ThreadKeyring, conversations: ConversationLedger) {
        let root = root(label)
        let ledger = Ledger(directory: root.appendingPathComponent("ledger"), device: device)
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let conversations = ConversationLedger(ledger: ledger, store: store)
        return (ledger, conversations.keyring, conversations)
    }

    private func record(kind: String, body: JSONValue, device: String = "mac-x",
                        seq: Int = 1) -> LedgerRecord {
        LedgerRecord(kind: kind, at: Date(timeIntervalSince1970: 1_788_000_000 + Double(seq)),
                     device: device, seq: seq, prev: nil, after: [], body: body)
    }

    // MARK: - §13.3 The plaintext rule, for every kind

    @Test func anyKindWithTextAndNoTextEncIsPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        // A claim in the clear — what every claim looked like before §13.
        let plainClaim = record(kind: LedgerRecord.Kind.claim, body: try Claim.body(
            op: Claim.Op.assert, id: Claim.id(target: "memory", text: "likes tea"),
            target: "memory", key: nil, source: "user", text: "likes tea"))
        #expect(plainClaim.carriesPlaintext)
        // A document somebody wrote in the clear by hand — nothing in this
        // build writes one, and the rule must not depend on that.
        let plainDocument = record(kind: LedgerRecord.Kind.document, body: .of([
            "name": .string("soul"), "bytes": .int(3), "text": .string("hi!")]))
        #expect(plainDocument.carriesPlaintext)
        // And a kind this build has never heard of.
        #expect(record(kind: "note", body: .of(["text": .string("x")])).carriesPlaintext)

        // Sealed: not plaintext, whatever the kind.
        let sealedClaim = record(kind: LedgerRecord.Kind.claim, body: try Claim.body(
            op: Claim.Op.assert, id: Claim.id(target: "memory", text: "likes tea"),
            target: "memory", key: nil, source: "user", text: "likes tea", sealedWith: key))
        #expect(!sealedClaim.carriesPlaintext)
        #expect(sealedClaim.body["text"] == nil)
        let sealedDocument = record(kind: LedgerRecord.Kind.document,
                                    body: try DocumentRecord.body(name: "soul", text: "hi!", key: key))
        #expect(!sealedDocument.carriesPlaintext)
        // No text at all: a retract, a delete, a `text` that is not a string.
        let retract = record(kind: LedgerRecord.Kind.claim, body: try Claim.body(
            op: Claim.Op.retract, id: "abc", target: "memory", key: nil, source: "user", text: nil))
        #expect(!retract.carriesPlaintext)
        #expect(!record(kind: LedgerRecord.Kind.threadDelete,
                        body: .of(["thread": .string("t")])).carriesPlaintext)
        #expect(!record(kind: "turn", body: .of(["text": .null])).carriesPlaintext)
        #expect(!record(kind: "turn", body: .of(["text": .int(1)])).carriesPlaintext)
    }

    // MARK: - §13.2 The memory key

    @Test func theMemoryKeyIsMintedOnceAndSharedBetweenWriters() throws {
        let root = root("mint")
        let url = root.appendingPathComponent("thread-keys.json")
        let app = ThreadKeyring(url: url)
        let plugin = ThreadKeyring(url: url)
        let minted = try #require(try app.memoryKey(peerBook: nil))
        // `.fileWins`: the second writer takes the first one's key.
        #expect(try #require(try plugin.memoryKey(peerBook: nil)) == minted)
        #expect(app.key(for: ThreadKeyring.memoryKeyID) == minted)
        #expect(ThreadKeyring.memoryKeyID == "moe:memory")
        #expect(ThreadKeyring.isReserved("moe:memory"))
        #expect(ThreadKeyring.isReserved("moe:anything-later"))
        #expect(!ThreadKeyring.isReserved("7B2E1C4A-9F03-4D6E-8A15-C0FFEE000001"))
        // It is a keyring entry like any other, which is what lets the
        // courier deliver it with no code of its own.
        #expect(app.threads() == ["moe:memory"])
    }

    @Test func theMemoryKeyCannotBeDestroyedOrForgotten() throws {
        let (_, keyring, _) = fixture("indestructible")
        let key = try #require(try keyring.memoryKey(peerBook: nil))
        try keyring.destroy(thread: ThreadKeyring.memoryKeyID)
        #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == key)
        #expect(try keyring.forget(threads: [ThreadKeyring.memoryKeyID, "moe:other"]) == 0)
        #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == key)
        // A real thread beside it still goes, so the guard is on the prefix
        // and not on the whole operation.
        try keyring.key(creatingFor: "thread-1")
        #expect(try keyring.forget(threads: ["thread-1", ThreadKeyring.memoryKeyID]) == 1)
        #expect(keyring.has(thread: "thread-1") == false)
        #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == key)
    }

    @Test func aThreadDeleteNamingTheMemoryKeyIsIgnoredByEveryReader() throws {
        let (ledger, keyring, conversations) = fixture("delete-record")
        let key = try #require(try keyring.memoryKey(peerBook: nil))

        // The person asks the app to delete "moe:memory". It is not a
        // thread; nothing happens, and nothing is written.
        try conversations.delete(id: ThreadKeyring.memoryKeyID)
        #expect(ledger.all().isEmpty)
        #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == key)

        // A `thread.delete` naming it arrives from elsewhere — a forged one,
        // or a buggy writer. It is a record, so it is kept; it is ignored by
        // everything that reads deletions.
        let forged = record(kind: LedgerRecord.Kind.threadDelete,
                            body: .of(["thread": .string(ThreadKeyring.memoryKeyID)]),
                            device: "mac-b")
        #expect(try ledger.adopt(forged))
        #expect(!conversations.projector.isDeleted(thread: ThreadKeyring.memoryKeyID))
        #expect(conversations.deletedThreads().isEmpty)
        // The two sweeps that forget keys for deleted threads.
        _ = try conversations.reproject(threads: [ThreadKeyring.memoryKeyID])
        #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == key)
        _ = try conversations.rebuild()
        #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == key)

        // And a real deletion beside it still works, so the guard is narrow.
        try keyring.key(creatingFor: "real-thread")
        let turn = record(kind: LedgerRecord.Kind.turn, body: .of([
            "thread": .string("real-thread"), "turn_id": .string("t1"),
            "role": .string("you"), "at": .string("2026-01-01T00:00:00Z"),
            "text": .string("hi")]), device: "mac-b", seq: 2)
        let tomb = record(kind: LedgerRecord.Kind.threadDelete,
                          body: .of(["thread": .string("real-thread")]), device: "mac-b", seq: 3)
        _ = try ledger.adopt(turn)
        _ = try ledger.adopt(tomb)
        _ = try conversations.reproject(threads: ["real-thread"])
        #expect(keyring.has(thread: "real-thread") == false)
        #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == key)
    }

    // MARK: - §13.4 Sealed claims

    @Test func aClaimLedgerWithTheMemoryKeySealsWhatItWrites() throws {
        let (ledger, keyring, _) = fixture("sealed-writes")
        let key = try #require(try keyring.memoryKey(peerBook: nil))
        let claims = ClaimLedger(ledger: ledger, key: key, namesFrontier: false)
        let record = try #require(try claims.assert("I work at Kaplan.", key: "job",
                                                    source: "user"))
        // Sealed exactly as a turn is (§1.7); the labels stay in the clear.
        #expect(record.body["enc"]?.stringValue == ThreadCrypto.scheme)
        #expect(record.body["text"] == nil)
        #expect(ThreadCrypto.open(record.body["text_enc"]?.stringValue ?? "", with: key)
                == "I work at Kaplan.")
        #expect(record.body["op"]?.stringValue == "assert")
        #expect(record.body["target"]?.stringValue == "memory")
        #expect(record.body["key"]?.stringValue == "job")
        #expect(record.body["source"]?.stringValue == "user")
        #expect(!record.carriesPlaintext)
        // The claim id is over the plaintext — the same id a plaintext
        // writer and the Python side mint — so two devices converge.
        #expect(record.body["claim"]?.stringValue == Claim.id(target: "memory", text: "I work at Kaplan."))

        // Read back with the key: an ordinary live claim.
        let projection = claims.resolve(target: "memory")
        #expect(projection.texts == ["I work at Kaplan."])
        #expect(projection.unreadable.isEmpty)
        // Asserting it again is a repetition, not a change of belief.
        #expect(try claims.assert("I work at Kaplan.", key: "job", source: "user") == nil)

        // A retract carries the id and no text, as before.
        let retract = try #require(try claims.retract("I work at Kaplan.", source: "user"))
        #expect(retract.body["text"] == nil && retract.body["text_enc"] == nil)
        #expect(claims.resolve(target: "memory").texts.isEmpty)
    }

    @Test func aReaderWithoutTheKeyCountsASealedClaimAndShowsNothing() throws {
        let (ledger, keyring, _) = fixture("unreadable")
        let key = try #require(try keyring.memoryKey(peerBook: nil))
        let writer = ClaimLedger(ledger: ledger, key: key, namesFrontier: false)
        let a = try #require(try writer.assert("Lives in Leeds.", key: "home", source: "user"))
        let b = try #require(try writer.assert("Allergic to cats.", source: "hermes:assistant_tool"))

        // The same records, read by a device the courier has not reached.
        let stranger = ClaimLedger(ledger: Ledger(directory: ledger.directory, device: "mac-b"),
                                   key: nil, namesFrontier: false)
        let projection = stranger.resolve(target: "memory")
        #expect(projection.live.isEmpty, "a claim nobody can read was projected")
        #expect(projection.pendingRevivals.isEmpty)
        #expect(projection.superseded.isEmpty)
        #expect(projection.unreadable.map(\.recordID) == [a.id, b.id])
        #expect(projection.unreadable.map(\.key) == ["home", Claim.id(target: "memory", text: "Allergic to cats.")])
        #expect(projection.unreadable.map(\.source) == ["user", "hermes:assistant_tool"])
        #expect(stranger.targets() == ["memory"])
        #expect(stranger.records(target: "memory").count == 2)

        // Never retracted on the person's behalf: the stranger cannot write
        // a retraction for a claim it cannot read, by id or by text.
        #expect(try stranger.retract(id: Claim.id(target: "memory", text: "Lives in Leeds."),
                                     source: "user") == nil)
        #expect(try stranger.retract("Lives in Leeds.", source: "user") == nil)
        #expect(ledger.all().count == 2)

        // A retraction the *writer* makes still finds the claim on the
        // stranger's side — the id is in the clear — so it is no longer
        // counted there either.
        try writer.retract("Lives in Leeds.", source: "user")
        let after = stranger.resolve(target: "memory")
        #expect(after.unreadable.map(\.recordID) == [b.id])

        // And the moment the key arrives, the ordinary projection.
        let delivered = ClaimLedger(ledger: stranger.ledger, key: key, namesFrontier: false)
        #expect(delivered.resolve(target: "memory").texts == ["Allergic to cats."])
        #expect(delivered.resolve(target: "memory").unreadable.isEmpty)
    }

    @Test func aWrongKeyIsAsGoodAsNoKey() throws {
        let (ledger, keyring, _) = fixture("wrong-key")
        let writer = ClaimLedger(ledger: ledger, key: try #require(try keyring.memoryKey(peerBook: nil)), namesFrontier: false)
        try writer.assert("Prefers mornings.", source: "user")
        let wrong = ClaimLedger(ledger: ledger, key: SymmetricKey(size: .bits256), namesFrontier: false)
        let projection = wrong.resolve(target: "memory")
        #expect(projection.live.isEmpty)
        #expect(projection.unreadable.count == 1)
    }

    @Test func aReadableCopyOfAnUnreadableClaimMakesItLive() throws {
        // Two devices asserted one sentence: one sealed under a key this
        // reader lacks (it never will — a stale legacy key, say), one in the
        // clear. Same id, same words by construction: live, and not counted
        // twice.
        let (ledger, _, _) = fixture("mixed-copies")
        let other = SymmetricKey(size: .bits256)
        try ledger.append(kind: LedgerRecord.Kind.claim, body: try Claim.body(
            op: Claim.Op.assert, id: Claim.id(target: "memory", text: "Has a dog."),
            target: "memory", key: nil, source: "user", text: "Has a dog.", sealedWith: other))
        try ledger.append(kind: LedgerRecord.Kind.claim, body: try Claim.body(
            op: Claim.Op.assert, id: Claim.id(target: "memory", text: "Has a dog."),
            target: "memory", key: nil, source: "user", text: "Has a dog."))
        let projection = ClaimLedger(ledger: ledger, key: nil, namesFrontier: false)
            .resolve(target: "memory")
        #expect(projection.texts == ["Has a dog."])
        #expect(projection.unreadable.isEmpty)
    }

    @Test func aSealedReStatementAfterADeletionIsCountedNotAsked() throws {
        // The pending-revival path needs words to ask with. Without the key
        // there are none, so the re-statement is counted and not asked
        // about — and not revived either.
        let (ledger, keyring, _) = fixture("sealed-revival")
        let key = try #require(try keyring.memoryKey(peerBook: nil))
        let writer = ClaimLedger(ledger: ledger, key: key, namesFrontier: false)
        let first = try #require(try writer.assert("Vegetarian.", source: "user"))
        let gone = try #require(try writer.retract("Vegetarian.", source: "user"))
        let again = try #require(try writer.assert("Vegetarian.", source: "hermes:assistant_tool",
                                                   after: [gone.id]))
        _ = first
        let withKey = writer.resolve(target: "memory")
        #expect(withKey.live.isEmpty && withKey.pendingRevivals.map(\.id).count == 1)

        let without = ClaimLedger(ledger: ledger, key: nil, namesFrontier: false).resolve(target: "memory")
        #expect(without.live.isEmpty)
        #expect(without.pendingRevivals.isEmpty)
        #expect(without.unreadable.map(\.recordID) == [again.id])
    }

    @Test func plaintextClaimsStillReadAsBefore() throws {
        // Records written before the memory key existed stay readable on
        // the machine that wrote them, with or without a key in hand.
        let (ledger, keyring, _) = fixture("legacy")
        let legacy = ClaimLedger(ledger: ledger, key: nil, namesFrontier: false)
        try legacy.assert("Old fact.", source: "user")
        #expect(ledger.all().allSatisfy { $0.carriesPlaintext })
        let modern = ClaimLedger(ledger: ledger, key: try #require(try keyring.memoryKey(peerBook: nil)), namesFrontier: false)
        #expect(modern.resolve(target: "memory").texts == ["Old fact."])
        #expect(legacy.resolve(target: "memory").texts == ["Old fact."])
    }

    // MARK: - §13.5 Documents

    @Test func aDocumentIsSealedHashedAndLatestWins() throws {
        let (ledger, keyring, _) = fixture("documents")
        let key = try #require(try keyring.memoryKey(peerBook: nil))
        let first = try DocumentRecord.append(name: "profile/people.md", text: "# People\n",
                                              to: ledger, key: key)
        #expect(first.kind == "document")
        #expect(first.body["thread"] == nil, "a document never carries a thread")
        #expect(first.body["name"]?.stringValue == "profile/people.md")
        #expect(first.body["bytes"]?.intValue == 9)
        #expect(first.body["enc"]?.stringValue == ThreadCrypto.scheme)
        #expect(first.body["text"] == nil)
        #expect(!first.carriesPlaintext)
        // Nothing about the words in the clear — not even their hash. A
        // hash of `hermes/skills-disabled` (a few hundred possible arrays)
        // or of `SOUL.md` ("still the default") would say what the file is
        // to anybody holding the edge's rows. The body is exactly these
        // four keys.
        #expect(first.body["sha256"] == nil)
        if case .object(let fields) = first.body {
            #expect(Set(fields.keys) == ["name", "bytes", "enc", "text_enc"])
            #expect(Set(fields.keys) == DocumentRecord.bodyKeys)
        } else { Issue.record("a document body is an object") }
        // The hash is the reader's, of what it opened.
        #expect(DocumentRecord.parse(first, key: key)?.sha256 == DocumentRecord.sha256(of: "# People\n"))
        #expect(DocumentRecord.sha256(of: "") ==
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ThreadCrypto.open(first.body["text_enc"]?.stringValue ?? "", with: key) == "# People\n")

        // Latest in ledger order wins; there is no merge.
        try DocumentRecord.append(name: "profile/people.md", text: "# People\n- Ana\n",
                                  to: ledger, key: key)
        try DocumentRecord.append(name: "soul", text: "Be kind.", to: ledger, key: key)
        let people = try #require(DocumentRecord.latest(name: "profile/people.md", in: ledger, key: key))
        #expect(people.text == "# People\n- Ana\n")
        #expect(people.bytes == 15 && !people.removed && people.readable)
        #expect(Set(DocumentRecord.latest(in: ledger, key: key).keys) == ["profile/people.md", "soul"])
        #expect(DocumentRecord.latest(name: "who", in: ledger, key: key) == nil)

        // Without the key: present, unreadable — and with no hash to
        // compare a file against, because there are no words to hash.
        let sealed = try #require(DocumentRecord.latest(name: "soul", in: ledger, key: nil))
        #expect(sealed.text == nil && !sealed.readable && !sealed.removed)
        #expect(sealed.sha256 == nil)

        // Removal: `bytes: 0`, `text_enc` empty — legible with no key at all.
        let removal = try DocumentRecord.append(name: "soul", text: nil, to: ledger, key: key)
        #expect(removal.body["bytes"]?.intValue == 0)
        #expect(removal.body["text_enc"]?.stringValue == "")
        #expect(!removal.carriesPlaintext)
        let gone = try #require(DocumentRecord.latest(name: "soul", in: ledger, key: nil))
        #expect(gone.removed && gone.readable && gone.text == nil)
        #expect(gone.sha256 == DocumentRecord.sha256(of: ""))
        #expect(gone.recordID == removal.id)

        // A `sha256` that a pre-fix writer put on the wire is ignored, not
        // believed: the reader's hash is of what it opened.
        let stale = record(kind: LedgerRecord.Kind.document, body: .of([
            "name": .string("soul"), "sha256": .string("not the hash"), "bytes": .int(8),
            "enc": .string(ThreadCrypto.scheme),
            "text_enc": .string(try ThreadCrypto.seal("Be kind.", with: key))]))
        #expect(DocumentRecord.parse(stale, key: key)?.sha256 == DocumentRecord.sha256(of: "Be kind."))
    }

    @Test func aDocumentThatIsTooLargeOrMalformedIsRefused() throws {
        let key = SymmetricKey(size: .bits256)
        let big = String(repeating: "x", count: DocumentRecord.maxBytes + 1)
        #expect(throws: DocumentError.self) { try DocumentRecord.body(name: "soul", text: big, key: key) }
        #expect(throws: DocumentError.self) { try DocumentRecord.body(name: "", text: "x", key: key) }
        _ = try DocumentRecord.body(name: "soul", text: String(repeating: "x", count: DocumentRecord.maxBytes),
                                    key: key)
        // Not a document this build reads: no name, a non-integer size, a
        // turn.
        #expect(DocumentRecord.parse(record(kind: "document", body: .of([
            "bytes": .int(1), "text_enc": .string("")])), key: key) == nil)
        #expect(DocumentRecord.parse(record(kind: "document", body: .of([
            "name": .string("soul"), "bytes": .double(1.0), "text_enc": .string("")])), key: key) == nil)
        #expect(DocumentRecord.parse(record(kind: "turn", body: .of([
            "name": .string("soul"), "bytes": .int(1), "text_enc": .string("")])), key: key) == nil)
    }

    // MARK: - §13.4 An empty text_enc on a claim

    @Test func aClaimWithAnEmptyTextEncIsNotAClaim() throws {
        // `text_enc: ""` is a removal on a document (§13.5) and malformed on
        // a claim: no key will ever open zero bytes, so it can never become
        // readable, and Python's reader treats it as absent. Swift used to
        // count it as sealed-unreadable for ever — one entry the two halves
        // of a memory disagreed about. Now it is not a claim, with or
        // without the key.
        let key = SymmetricKey(size: .bits256)
        let id = Claim.id(target: "memory", text: "likes tea")
        let empty = record(kind: LedgerRecord.Kind.claim, body: .of([
            "op": .string(Claim.Op.assert), "claim": .string(id), "target": .string("memory"),
            "source": .string("user"), "enc": .string(ThreadCrypto.scheme),
            "text_enc": .string("")]))
        #expect(Claim.parse(empty, key: key) == nil)
        #expect(Claim.parse(empty, key: nil) == nil)
        #expect(!empty.carriesPlaintext, "and it is not plaintext either")
        // Through the resolver: neither live nor counted as unreadable.
        let (ledger, _, _) = fixture("empty-text-enc")
        try ledger.append(kind: LedgerRecord.Kind.claim, body: empty.body)
        let withKey = ClaimLedger(ledger: ledger, key: key, namesFrontier: false).resolve(target: "memory")
        #expect(withKey.live.isEmpty && withKey.unreadable.isEmpty)
        let without = ClaimLedger(ledger: ledger, key: nil, namesFrontier: false).resolve(target: "memory")
        #expect(without.live.isEmpty && without.unreadable.isEmpty)
        // A genuinely sealed one under a key this reader lacks is still
        // counted — the rule is about zero bytes, not about not opening.
        try ledger.append(kind: LedgerRecord.Kind.claim, body: try Claim.body(
            op: Claim.Op.assert, id: id, target: "memory", key: nil, source: "user",
            text: "likes tea", sealedWith: SymmetricKey(size: .bits256)))
        #expect(ClaimLedger(ledger: ledger, key: key, namesFrontier: false)
            .resolve(target: "memory").unreadable.count == 1)
    }

    // MARK: - §13.2 When a mint is a second key

    /// The states a Mac can be in when it needs `moe:memory` and the
    /// keyring has none, and what `memoryKey(peerBook:)` does in each. A
    /// mint on an enrolled Mac whose keyring is gone is a second key under
    /// one id; `collect` keeps the one it has, so the two sides would seal
    /// memory to each other under keys neither opens, until the hourly
    /// reseal — and everything sealed before that is lost.
    @Test func theMemoryKeyIsMintedOnlyWhenNoPeerCanHoldIt() throws {
        func peerBook(_ root: URL, peers: [String], revoked: [String] = []) throws -> URL {
            let url = root.appendingPathComponent("cloud/peers.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var stored: [String: Any] = [:]
            for id in peers { stored[id] = ["identity_pub": "AA==", "signing_pub": "AA=="] }
            try JSONSerialization.data(withJSONObject: ["peers": stored, "revoked": revoked])
                .write(to: url)
            return url
        }
        var notes: [String] = []

        // 1. A fresh Mac with no peers: mints. Whether the peer book is
        //    absent, empty, or names only revoked devices.
        do {
            let root = root("mint-fresh")
            let keyring = ThreadKeyring(url: root.appendingPathComponent("ledger/thread-keys.json"))
            #expect(try keyring.memoryKey(peerBook: root.appendingPathComponent("cloud/peers.json")) != nil)
            let empty = ThreadKeyring(url: root.appendingPathComponent("ledger2/thread-keys.json"))
            #expect(try empty.memoryKey(peerBook: try peerBook(root, peers: [])) != nil)
            let revoked = ThreadKeyring(url: root.appendingPathComponent("ledger3/thread-keys.json"))
            #expect(try revoked.memoryKey(peerBook: try peerBook(
                root, peers: ["mac-gone"], revoked: ["mac-gone"])) != nil)
        }

        // 2. A damaged marker beside the keyring. With no peer, nobody can
        //    deliver the key, so the Mac mints; with a peer named, nil —
        //    the key existed here, was lost here, and the peer holds it.
        do {
            let root = root("mint-damaged-alone")
            let url = root.appendingPathComponent("ledger/thread-keys.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("{not json".utf8).write(to: url)
            let keyring = ThreadKeyring(url: url)
            // A thread mint moves the unreadable file aside, as it always did.
            try keyring.key(creatingFor: "thread-1")
            #expect(ThreadKeyring.damagedMarker(beside: url)?.hasPrefix("thread-keys.json.damaged.") == true)
            #expect(try keyring.memoryKey(peerBook: nil) != nil)
            let again = ThreadKeyring(url: root.appendingPathComponent("ledger2/thread-keys.json"))
            try FileManager.default.createDirectory(at: again.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("{not json".utf8).write(to: again.url)
            try again.key(creatingFor: "thread-1")
            #expect(try again.memoryKey(peerBook: try peerBook(root, peers: [])) != nil)
        }
        do {
            let root = root("mint-damaged-peer")
            let url = root.appendingPathComponent("ledger/thread-keys.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("{not json".utf8).write(to: url)
            let keyring = ThreadKeyring(url: url) { notes.append($0) }
            try keyring.key(creatingFor: "thread-1")
            let peers = try peerBook(root, peers: ["mac-other"])
            #expect(try keyring.memoryKey(peerBook: peers) == nil)
            #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == nil, "nothing was written")
            #expect(notes.contains { $0.contains("waiting for moe:memory to come back from a peer") })
            // The key arriving from a peer ends the wait.
            let delivered = SymmetricKey(size: .bits256)
            try keyring.install(delivered, for: ThreadKeyring.memoryKeyID)
            #expect(try keyring.memoryKey(peerBook: peers) == delivered)
        }

        // 3. The keyring file is absent while the peer book names a peer:
        //    an enrolled Mac whose ledger directory was lost. Nil.
        do {
            let root = root("mint-lost")
            let url = root.appendingPathComponent("ledger/thread-keys.json")
            let peers = try peerBook(root, peers: ["mac-other"])
            let keyring = ThreadKeyring(url: url) { notes.append($0) }
            #expect(try keyring.memoryKey(peerBook: peers) == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path), "nothing was written")
            // Delivered by the courier: from then on it is simply there.
            let delivered = SymmetricKey(size: .bits256)
            try keyring.install(delivered, for: ThreadKeyring.memoryKeyID)
            #expect(try keyring.memoryKey(peerBook: peers) == delivered)
        }

        // 4. The keyring is present, a peer is named, and the key is absent:
        //    the live tenant on the day this ships, whose Macs have thread
        //    keys and no memory key yet. Mints.
        do {
            let root = root("mint-live")
            let url = root.appendingPathComponent("ledger/thread-keys.json")
            let keyring = ThreadKeyring(url: url)
            try keyring.key(creatingFor: "an-old-thread")
            let peers = try peerBook(root, peers: ["mac-other"])
            let minted = try #require(try keyring.memoryKey(peerBook: peers))
            #expect(try keyring.memoryKey(peerBook: peers) == minted)
            #expect(Set(keyring.threads()) == ["an-old-thread", "moe:memory"])
        }

        // And the unguarded path cannot be used to get round the guard: a
        // reserved entry is minted through memoryKey(peerBook:) or not at all.
        do {
            let keyring = ThreadKeyring(url: root("mint-reserved").appendingPathComponent("thread-keys.json"))
            #expect(throws: ThreadKeyringError.self) { try keyring.key(creatingFor: ThreadKeyring.memoryKeyID) }
            #expect(keyring.key(for: ThreadKeyring.memoryKeyID) == nil)
            let minted = try #require(try keyring.memoryKey(peerBook: nil))
            #expect(try keyring.key(creatingFor: ThreadKeyring.memoryKeyID) == minted, "but an existing one is returned")
        }
    }

    @Test func memoryRecordsDoNotDisturbTheThreadProjection() throws {
        // Records with no `thread` are invisible to everything that indexes
        // by thread, and a ledger full of them still projects its threads.
        let (ledger, keyring, conversations) = fixture("no-thread")
        let key = try #require(try keyring.memoryKey(peerBook: nil))
        try ClaimLedger(ledger: ledger, key: key, namesFrontier: false)
            .assert("Fact.", source: "user")
        try DocumentRecord.append(name: "soul", text: "Soul.", to: ledger, key: key)
        #expect(conversations.projector.threads().isEmpty)
        #expect(ledger.byThread().isEmpty)
        #expect(conversations.deletedThreads().isEmpty)
        #expect(try conversations.rebuild() == 0)
        #expect(try conversations.reproject(threads: []).isEmpty)
    }
}
