import Foundation
import CryptoKit
import Testing
@testable import MoeLedger

/// One corpus, both implementations — CLOUD-PLAN §15.1's retired keys.
///
/// `thread-keys.json` gained a `retired` field, and two languages have to
/// agree about it forever: Swift's `ThreadKeyring`, which is the only thing
/// that ever *writes* one, and Python's `moeledger.vault.Keyring` and
/// `claimstore.store`, which are what actually read a person's memory on a
/// Mac. They cannot share code, so what keeps them one implementation is a
/// committed file each asserts against independently:
///
///     Tests/vectors/retired-keys.json
///
/// Its readers are this suite,
/// `moe-home/hermes-plugins/moe-ledger/tests/test_retired_key_vectors.py` and
/// `moe-home/hermes-plugins/claimstore/tests/test_retired_key_vectors.py`.
/// §15.1 asks for exactly this — *"cross-tested against shared vectors, the
/// way everything else on this wire is"* — and the shape is `ledger-wire.json`'s:
/// generated from the Swift, committed, and read by everyone.
///
/// **Why a shared file rather than twin suites.** There already were twin
/// suites — `RetiredKeyTests` here and `test_retired_key_reads.py` there — and
/// twins are exactly how the machinery-notice rule ended up disagreeing four
/// ways while both suites passed. A keyring the two sides read differently
/// does not crash: it makes one half of a person's memory unreadable on the
/// other device, silently, which is the defect §15.1 exists to close pointing
/// the other way.
///
/// Regenerate deliberately, never as a way of making a failure go away:
///
///     MOE_WRITE_VECTORS=1 MOE_SKIP_PG=1 ./scripts/test.sh --filter RetiredKeyVectorTests
///
/// then run it again without the variable, because the reading tests below
/// take the file as it was when they started.
@Suite("Retired-key vectors (CLOUD-PLAN §15.1)", .serialized)
struct RetiredKeyVectorTests {

    // MARK: - The file

    static let vectorURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()            // Tests/MoeLedgerTests
        .deletingLastPathComponent()            // Tests
        .appendingPathComponent("vectors")
        .appendingPathComponent("retired-keys.json")

    static var writing: Bool {
        ProcessInfo.processInfo.environment["MOE_WRITE_VECTORS"] == "1"
    }

    enum VectorError: Error, CustomStringConvertible {
        case missing(URL)
        case malformed(String)
        /// A vector whose story is "the tenant's key won" and whose keys no
        /// longer say so. Thrown rather than asserted, because it means the
        /// order under test moved and the file is now describing a keyring
        /// this build cannot produce at all.
        case adoptDeclined(String)
        var description: String {
            switch self {
            case .missing(let url): return "\(url.path) is not there; regenerate it"
            case .malformed(let what): return "the vector file is malformed: \(what)"
            case .adoptDeclined(let name):
                return "\(name): adopt declined a key the vectors say it keeps — the total order moved"
            }
        }
    }

    static func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: vectorURL.path) else {
            throw VectorError.missing(vectorURL)
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL))
                as? [String: Any] else { throw VectorError.malformed("top level is not an object") }
        return object
    }

    static func section(_ name: String, of file: [String: Any]) throws -> [[String: Any]] {
        guard let rows = file[name] as? [[String: Any]] else {
            throw VectorError.malformed("\(name) is missing or is not a list of objects")
        }
        return rows
    }

    // MARK: - Fixed inputs

    /// A 32-byte key whose place in `adopt`'s total order is decided by the
    /// one byte a reader can see, so the vectors can be checked by eye.
    static func key(_ lead: UInt8, _ fill: UInt8) -> SymmetricKey {
        SymmetricKey(data: Data([lead] + [UInt8](repeating: fill, count: 31)))
    }

    static func raw(_ bytes: [UInt8]) -> SymmetricKey { SymmetricKey(data: Data(bytes)) }

    static func b64(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// The tenant's `moe:memory` key. Smaller than `freeKey`, so it is the one
    /// `adopt` keeps — which is what makes these vectors the §15.1 story and
    /// not its mirror image.
    static let tenantKey = key(0x20, 0xA1)
    /// What this Mac minted for itself while it ran free and peerless.
    static let freeKey = key(0x90, 0x5C)
    static let conversationKey = key(0x4D, 0x77)

    /// Three keys for the Mac that is displaced twice, in the order it meets
    /// them: each smaller than the last, or the second adopt would decline.
    static let firstMemoryKey = key(0xC0, 0x13)
    static let secondMemoryKey = key(0x80, 0x24)
    static let thirdMemoryKey = key(0x40, 0x35)

    static let memory = ThreadKeyring.memoryKeyID
    static let conversation = "a-conversation"

    static func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retired-vectors-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("thread-keys.json")
    }

    /// What a keyring at `url` answers for the threads the vectors name.
    static func expectation(of keyring: ThreadKeyring) -> [String: Any] {
        var out: [String: Any] = [:]
        for thread in [memory, conversation] {
            let opening = keyring.openingKeys(for: thread).map(b64)
            var sealing: Any = NSNull()
            if let current = keyring.key(for: thread) { sealing = b64(current) }
            out[thread] = [
                "opening": opening,
                "sealing": sealing,
                "retired_count": keyring.retiredCount(for: thread),
            ] as [String: Any]
        }
        return out
    }

    // MARK: - The vectors this file pins

    /// Every keyring in `written`, built the way the app builds one. The
    /// closure is the *only* thing that produces the bytes: nothing here
    /// hand-writes a file the app would not have written, which is what makes
    /// `text` worth comparing byte for byte.
    static let writtenVectors: [(name: String, story: String, build: (ThreadKeyring) throws -> Void)] = [
        (
            "a-free-mac-that-joined-a-tenant",
            "§15.1 itself: this Mac minted moe:memory while it ran free, then joined a "
                + "tenant whose key wins the order. The tenant's key becomes the one "
                + "everything seals under and the Mac's own is kept openable.",
            { ring in
                try ring.install(conversationKey, for: conversation)
                try ring.install(freeKey, for: memory)
                guard try ring.adopt(tenantKey, for: memory) else {
                    throw VectorError.adoptDeclined("a-free-mac-that-joined-a-tenant")
                }
            }
        ),
        (
            "the-same-key-delivered-again-and-again",
            "The courier ships every key it holds on every full run, so the tenant's "
                + "key arrives over and over. Re-delivery must not fill the file with "
                + "copies of one key.",
            { ring in
                try ring.install(freeKey, for: memory)
                _ = try ring.adopt(tenantKey, for: memory)
                _ = try ring.adopt(tenantKey, for: memory)
                _ = try ring.adopt(tenantKey, for: memory)
            }
        ),
        (
            "a-key-that-came-back-and-was-displaced-twice",
            "An enrolment installs the free Mac's own key over the tenant's — install is "
                + "an instruction, and it does not retire anything — and the courier then "
                + "displaces it a second time. The history on disk names that key TWICE, "
                + "and both implementations still hand out each key once: the "
                + "deduplication is on the read, where it is one rule rather than a "
                + "promise every writer has to keep. This is the only vector whose file "
                + "carries a repeat, and it is what makes that agreement checkable.",
            { ring in
                try ring.install(freeKey, for: memory)
                _ = try ring.adopt(tenantKey, for: memory)
                try ring.install(freeKey, for: memory)
                _ = try ring.adopt(tenantKey, for: memory)
            }
        ),
        (
            "a-mac-displaced-twice-by-two-different-keys",
            "Two displacements by two different keys. The order of the retired list is "
                + "the order this Mac met them, oldest first — it is an array on disk "
                + "and nothing sorts it.",
            { ring in
                try ring.install(firstMemoryKey, for: memory)
                _ = try ring.adopt(secondMemoryKey, for: memory)
                _ = try ring.adopt(thirdMemoryKey, for: memory)
            }
        ),
        (
            "a-keyring-from-before-15.1",
            "Nothing was ever displaced, so the file carries no `retired` field at all "
                + "and is byte-identical to one written before §15.1 existed. Every "
                + "keyring on every Mac looks like this until the day it joins.",
            { ring in
                try ring.install(conversationKey, for: conversation)
                try ring.install(tenantKey, for: memory)
            }
        ),
    ]

    /// Files no writer produces, which both implementations must nonetheless
    /// read: `retired` is a field a later build added, so a shape this one
    /// does not understand is *no history*, never *unreadable*. Refusing here
    /// would strand a Mac whose keyring is perfectly healthy.
    static func toleratedVectors() -> [[String: Any]] {
        let keys: [String: SymmetricKey] = [memory: tenantKey, conversation: conversationKey]
        func entry(_ name: String, _ why: String, _ retired: Any,
                   opening: [SymmetricKey]) -> [String: Any] {
            [
                "name": name,
                "why": why,
                "text": text(of: body(keys: keys, retired: retired)),
                "expect": [
                    memory: ["opening": opening.map(b64), "sealing": b64(tenantKey),
                             "retired_count": opening.count - 1] as [String: Any],
                    conversation: ["opening": [b64(conversationKey)], "sealing": b64(conversationKey),
                                   "retired_count": 0] as [String: Any],
                ],
            ]
        }
        return [
            entry("retired-is-a-string",
                  "A later build wrote something else under this name entirely.",
                  "a shape from the future", opening: [tenantKey]),
            entry("retired-is-a-list",
                  "The same field as a list rather than a map of thread to keys.",
                  [memory], opening: [tenantKey]),
            entry("retired-maps-a-thread-to-a-string",
                  "The field is the right shape and one thread's value is not.",
                  [memory: b64(freeKey)], opening: [tenantKey]),
            entry("retired-is-an-empty-map",
                  "A writer that emitted the field even with nothing to put in it.",
                  [String: [String]](), opening: [tenantKey]),
            entry("retired-holds-a-good-key-and-junk-beside-it",
                  "One decodable key among entries that are not base64 and not 32 bytes. "
                      + "The good one survives; the rest are dropped rather than taking "
                      + "the keyring down with them.",
                  [memory: [b64(freeKey), "not base64!!!", "c2hvcnQ="]],
                  opening: [tenantKey, freeKey]),
            entry("retired-holds-nothing-this-build-can-decode",
                  "Both sides read this as no history, by different routes: Swift's cast "
                      + "of the whole field fails on the number, Python drops the two "
                      + "entries one at a time. The corpus keeps such a file to ONE "
                      + "thread deliberately — see _about.malformed_granularity.",
                  [memory: ["not base64!!!", 7] as [Any]], opening: [tenantKey]),
        ]
    }

    /// The other half of the asymmetry, and the reason the section above can
    /// fail. A `keys` shape this build cannot parse is a keyring to leave
    /// alone, not one to read as empty and write over — so both
    /// implementations refuse these outright, and a build that read anything
    /// at all would pass `tolerated` and fail here.
    static func refusedVectors() -> [[String: Any]] {
        [
            [
                "name": "the-file-is-not-an-object",
                "why": "Not a keyring at all. Reading it as empty would replace it.",
                "text": "[1, 2, 3]",
            ],
            [
                "name": "keys-is-a-list",
                "why": "The one field neither side may guess at.",
                "text": text(of: ["README": ThreadKeyring.warning, "version": 1,
                                  "keys": [memory, conversation]]),
            ],
            [
                "name": "keys-is-missing-but-retired-is-not",
                "why": "A file carrying history and no keys is not a keyring this build "
                    + "can write over, however well it understands the new field.",
                "text": text(of: ["README": ThreadKeyring.warning, "version": 1,
                                  "retired": [memory: [b64(freeKey)]]]),
            ],
        ]
    }

    /// `adopt`'s total order, pair by pair. The numerically smaller key
    /// material wins, unsigned, first differing byte decides — and `winner`
    /// is null where there is none, which is what makes re-delivery a no-op.
    static func orderVectors() -> [[String: Any]] {
        func fill(_ byte: UInt8) -> [UInt8] { [UInt8](repeating: byte, count: 32) }
        func at(_ bytes: [UInt8], _ index: Int, _ byte: UInt8) -> [UInt8] {
            var out = bytes; out[index] = byte; return out
        }
        func pair(_ name: String, _ why: String, _ a: SymmetricKey, _ b: SymmetricKey,
                  _ winner: String?) -> [String: Any] {
            var named: Any = NSNull()
            if let winner { named = winner }
            return ["name": name, "why": why, "a": b64(a), "b": b64(b), "winner": named]
        }
        return [
            pair("differs-only-in-the-last-byte",
                 "Thirty-one identical bytes. A comparison that looked at the first byte "
                     + "alone would find no difference and call it a tie.",
                 raw(at(fill(0x5A), 31, 0x01)), raw(at(fill(0x5A), 31, 0x02)), "a"),
            pair("differs-only-in-the-last-byte-00-vs-ff",
                 "The same case at the ends of the byte range.",
                 raw(at(fill(0xC7), 31, 0x00)), raw(at(fill(0xC7), 31, 0xFF)), "a"),
            pair("differs-only-in-the-first-byte",
                 "`a` is larger in every byte but the first, and wins on the first. The "
                     + "first byte that differs decides; nothing sums or averages.",
                 raw([0x01] + [UInt8](repeating: 0xFF, count: 31)),
                 raw([0x02] + [UInt8](repeating: 0x00, count: 31)), "a"),
            pair("differs-in-the-middle-and-contradicted-after",
                 "The bytes after the first difference point the other way, so a rule "
                     + "that let a later byte have the last word would get this wrong.",
                 raw(at(at(fill(0x33), 16, 0x00), 17, 0xFF)),
                 raw(at(at(fill(0x33), 16, 0x01), 17, 0x00)), "a"),
            pair("unsigned-not-signed",
                 "0x7F against 0x80. Compared as signed bytes 0x80 is -128 and would "
                     + "win, which is the whole of the bug this pins.",
                 raw([0x7F] + [UInt8](repeating: 0x11, count: 31)),
                 raw([0x80] + [UInt8](repeating: 0x11, count: 31)), "a"),
            pair("the-two-keys-in-the-written-vectors",
                 "The tenant's key against the one this Mac minted while free. The "
                     + "written section is this pair's answer, on disk.",
                 tenantKey, freeKey, "a"),
            pair("the-same-key-twice",
                 "Neither displaces the other, which is why re-delivering a key the "
                     + "courier already delivered retires nothing.",
                 tenantKey, tenantKey, nil),
        ]
    }

    // MARK: - Building the file

    static func body(keys: [String: SymmetricKey], retired: Any?) -> [String: Any] {
        var body: [String: Any] = [
            "README": ThreadKeyring.warning,
            "version": 1,
            "keys": keys.mapValues(b64),
        ]
        if let retired { body["retired"] = retired }
        return body
    }

    /// A keyring file as text, in the form Foundation writes one: pretty,
    /// sorted, `/` escaped, no trailing newline. `ThreadKeyring.write` and
    /// `moeledger.identity.pretty_json` both produce exactly this — that
    /// agreement is one of the things being pinned.
    static func text(of object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// The sealed samples for the first written vector: one claim sealed
    /// under the key this Mac retired, one under the key it seals with now.
    ///
    /// The nonce is CryptoKit's and cannot be injected, so these are *kept*
    /// from the stored file whenever they still open — a regeneration that
    /// adds a vector must not churn ciphertext the Python readers pin.
    static func sealedSamples(keeping stored: [[String: Any]]?) throws -> [[String: Any]] {
        let wanted: [(under: String, key: SymmetricKey, text: String)] = [
            ("retired", freeKey, "the car is due in March"),
            ("current", tenantKey, "the dentist is on Tuesday"),
        ]
        return try wanted.map { sample in
            if let kept = stored?.first(where: { $0["under"] as? String == sample.under }),
               let combined = kept["combined"] as? String,
               ThreadCrypto.open(combined, with: sample.key) == sample.text {
                return kept
            }
            return ["under": sample.under, "text": sample.text,
                    "combined": try ThreadCrypto.seal(sample.text, with: sample.key)]
        }
    }

    static func build(keeping stored: [String: Any]?) throws -> [String: Any] {
        let storedWritten = (stored?["written"] as? [[String: Any]]) ?? []
        var written: [[String: Any]] = []
        for vector in writtenVectors {
            let url = scratch()
            let keyring = ThreadKeyring(url: url) { _ in }
            try vector.build(keyring)
            let text = try String(contentsOf: url, encoding: .utf8)
            let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any] ?? [:]
            var entry: [String: Any] = [
                "name": vector.name,
                "story": vector.story,
                "text": text,
                "has_retired_field": onDisk["retired"] != nil,
                "expect": expectation(of: keyring),
            ]
            if vector.name == writtenVectors[0].name {
                let keptSamples = storedWritten
                    .first { $0["name"] as? String == vector.name }?["sealed"] as? [[String: Any]]
                entry["sealed"] = try sealedSamples(keeping: keptSamples)
            }
            written.append(entry)
        }
        return [
            "_about": about,
            "written": written,
            "tolerated": toleratedVectors(),
            "refused": refusedVectors(),
            "order": orderVectors(),
        ]
    }

    static let about: [String: Any] = [
        "what": "CLOUD-PLAN §15.1's retired keys, pinned across the two implementations "
            + "of thread-keys.json: Swift's ThreadKeyring, and Python's "
            + "moeledger.vault.Keyring and claimstore.store.",
        "generator": "Tests/MoeLedgerTests/RetiredKeyVectorTests.swift "
            + "(MOE_WRITE_VECTORS=1 MOE_SKIP_PG=1 ./scripts/test.sh --filter RetiredKeyVectorTests)",
        "readers": [
            "Tests/MoeLedgerTests/RetiredKeyVectorTests.swift",
            "moe-home/hermes-plugins/moe-ledger/tests/test_retired_key_vectors.py",
            "moe-home/hermes-plugins/claimstore/tests/test_retired_key_vectors.py",
        ],
        "bytes": "every key is 32 raw bytes as standard base64 with padding. The key "
            + "material is fixed and legible on purpose — the leading byte decides "
            + "every ordering question in this file, so a reader can check it by eye.",
        "text": "`text` is the file byte for byte, in Foundation's [.prettyPrinted, "
            + ".sortedKeys] form with no trailing newline. Python's "
            + "moeledger.records.foundation_pretty_json reproduces it exactly; "
            + "Keyring._write_keys then appends one newline, so a file Python has "
            + "rewritten is this text plus \\n and nothing else.",
        "adopt_is_swift_only": "The `order` section is `ThreadKeyring.wins`, and there is "
            + "no Python implementation of it to check: `retired` is READ-ONLY on that "
            + "side by design — the writer is the courier, which is Swift, and the "
            + "machine never mints or destroys the memory key at all (§11.2). So Python "
            + "asserts the documented rule rather than a function of its own: the "
            + "winner is min(a, b) over the raw bytes, which is what `numerically "
            + "smaller wins` means and what Python's own byte comparison does. That is "
            + "an independent statement of the rule, not a call into moeledger, and it "
            + "is why changing Swift's order and regenerating this file fails the "
            + "Python suite. Python also checks the reachable consequence: the current "
            + "key of every written vector is the winner of its pair.",
        "refusal_is_spelled_differently": "In `refused` the two sides express the same "
            + "answer in their own idiom — Swift hands out no key (a fresh ThreadKeyring "
            + "reads nothing and openingKeys is empty), Python raises VaultError. What "
            + "the vector pins is that neither hands out a key and neither writes over "
            + "the file.",
        "duplicates": "openingKeys must never name one key twice, and neither side "
            + "leans on the writer for that: both deduplicate when they read "
            + "(`ThreadKeyring.openingKeys`, `Keyring.opening_keys`). A repeat does "
            + "reach the disk — `install` is `.callerWins` with no order test, so a key "
            + "can be put back as current and displaced a second time — and "
            + "`a-key-that-came-back-and-was-displaced-twice` is that file, retired list "
            + "and all. It is the vector that makes the agreement checkable rather than "
            + "asserted: two entries on disk, one key in the answer, on both sides.",
        "malformed_granularity": "Swift parses `retired` as one cast of the whole field "
            + "and Python element by element, so a file whose retired list mixes "
            + "decodable keys with a non-string would lose ALL history on the Swift "
            + "side and only that element on the Python side. Both still read the "
            + "keyring, which is what §15.1 requires; the corpus keeps such a file to "
            + "one thread so it does not pin a difference no writer can produce.",
        "sealed": "`sealed` carries ciphertext, so it is verified by opening, never "
            + "compared: CryptoKit's nonce cannot be injected. Regeneration keeps a "
            + "sample that still opens.",
    ]

    // MARK: - The names each section is expected to carry

    static let writtenNames = writtenVectors.map(\.name)
    static let toleratedNames = toleratedVectors().map { $0["name"] as? String ?? "" }
    static let refusedNames = refusedVectors().map { $0["name"] as? String ?? "" }
    static let orderNames = orderVectors().map { $0["name"] as? String ?? "" }

    static func named(_ section: String, _ name: String) throws -> [String: Any] {
        guard let row = try Self.section(section, of: Self.load())
            .first(where: { $0["name"] as? String == name })
        else { throw VectorError.malformed("\(section)/\(name) is not in the file") }
        return row
    }

    // MARK: - The tests

    /// The file is there, and it holds exactly the vectors this generator
    /// produces — no more, so a vector added here without regenerating is
    /// caught, and no fewer, so a corpus quietly emptied cannot pass every
    /// test below in silence.
    ///
    /// This is also where the file is written: `MOE_WRITE_VECTORS=1` and then
    /// a second run without it, because the reading tests take the file as it
    /// was when they started.
    @Test("Tests/vectors/retired-keys.json holds the vectors this generator produces")
    func theCorpusIsWhatThisGeneratorProduces() throws {
        if Self.writing {
            let stored = try? Self.load()
            let fresh = try Self.build(keeping: stored)
            var data = try JSONSerialization.data(
                withJSONObject: fresh,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0a)
            try FileManager.default.createDirectory(
                at: Self.vectorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.vectorURL, options: .atomic)
            print("wrote \(Self.vectorURL.path) (\(data.count) bytes)")
            return
        }

        let file = try Self.load()
        func names(_ section: String) throws -> [String] {
            try Self.section(section, of: file).map { $0["name"] as? String ?? "" }
        }
        #expect(try names("written") == Self.writtenNames)
        #expect(try names("tolerated") == Self.toleratedNames)
        #expect(try names("refused") == Self.refusedNames)
        #expect(try names("order") == Self.orderNames)
        let about = file["_about"] as? [String: Any] ?? [:]
        #expect((about["generator"] as? String)?.contains("RetiredKeyVectorTests") == true,
                "the file no longer says where it comes from")
    }

    /// The vector file is what the Swift actually writes, byte for byte.
    ///
    /// Every entry is rebuilt here through `install` and `adopt` — nothing
    /// hand-assembles a keyring — so this fails if the writer's shape moves at
    /// all: a field, a key order, a base64 alphabet, the decision to leave
    /// `retired` out when there is nothing to put in it.
    @Test("the keyring the Swift writes is the vector's bytes",
          arguments: RetiredKeyVectorTests.writtenNames)
    func theKeyringTheSwiftWritesIsTheVectorsBytes(_ name: String) throws {
        let vector = try Self.named("written", name)
        let build = try #require(Self.writtenVectors.first { $0.name == name }).build
        let url = Self.scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        try build(keyring)
        let produced = try String(contentsOf: url, encoding: .utf8)
        #expect(produced == vector["text"] as? String,
                "the keyring the Swift writes for \(name) is not the one in the vectors")
        // Said about what was just produced, and not only about the stored
        // file, because it is the one property here that no regeneration can
        // make true: a keyring whose history names a key twice is wrong
        // however faithfully the vectors record it. Written after a rewrite of
        // `adopt` in this worktree dropped the guard against appending a key
        // the history already held, and the first thing that failed was the
        // byte comparison — which reads like a stale fixture and is not.
        for thread in [Self.memory, Self.conversation] {
            let opening = keyring.openingKeys(for: thread).map(Self.b64)
            #expect(Set(opening).count == opening.count,
                    "\(name): the keyring the Swift just wrote names one \(thread) key twice")
        }
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any] ?? [:]
        #expect((onDisk["retired"] != nil) == (vector["has_retired_field"] as? Bool ?? true),
                "\(name): the presence of the `retired` field itself moved")
    }

    /// Ordering, on the files the writer produces: the current key first,
    /// then the retired ones oldest first, and no key named twice.
    @Test("openingKeys is current-first, then retired, with nothing repeated",
          arguments: RetiredKeyVectorTests.writtenNames)
    func openingKeysAreCurrentFirstThenRetired(_ name: String) throws {
        try Self.checkExpectation(Self.named("written", name), label: "written")
    }

    /// A `retired` field this build does not understand is *no history*, and
    /// the keyring still opens everything it always did. Every install on
    /// every Mac predates this field, so refusing would be a far worse answer
    /// than ignoring.
    @Test("a missing or malformed retired field reads as no history, never as unreadable",
          arguments: RetiredKeyVectorTests.toleratedNames)
    func aMalformedRetiredFieldIsToleratedNotRefused(_ name: String) throws {
        try Self.checkExpectation(Self.named("tolerated", name), label: "tolerated")
    }

    /// And the other direction, without which the section above could not
    /// fail: a `keys` field this build cannot parse is a keyring to leave
    /// alone. A reader lenient enough to pass everything above and this too
    /// would be one that writes over a file it cannot read, which is the one
    /// permanent loss this design has.
    @Test("a keyring neither implementation may read hands out no key",
          arguments: RetiredKeyVectorTests.refusedNames)
    func aKeyringThatCannotBeReadHandsOutNothing(_ name: String) throws {
        let vector = try Self.named("refused", name)
        let url = Self.scratch()
        try #require(vector["text"] as? String).write(to: url, atomically: true, encoding: .utf8)
        let keyring = ThreadKeyring(url: url) { _ in }
        #expect(keyring.key(for: Self.memory) == nil, "\(name): a key came out of it")
        #expect(keyring.openingKeys(for: Self.memory).isEmpty,
                "\(name): an opening key came out of it")
        #expect(throws: ThreadKeyringError.self, "\(name): the write went through") {
            try keyring.install(Self.tenantKey, for: Self.memory)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == vector["text"] as? String,
                "\(name): the file was written over rather than left alone")
    }

    /// `adopt`'s total order, pair by pair and in both directions.
    ///
    /// Both directions matter: a rule that answered "yes" to everything would
    /// pass one direction on every pair in the file. The pairs that differ in
    /// a single byte are what make this more than a formality — a comparison
    /// of leading bytes alone gets every other vector here right.
    @Test("adopt's total order is the one the vectors name",
          arguments: RetiredKeyVectorTests.orderNames)
    func adoptsTotalOrderIsWhatTheVectorsSay(_ name: String) throws {
        let vector = try Self.named("order", name)
        let a = try Self.decode(vector["a"], name)
        let b = try Self.decode(vector["b"], name)
        switch vector["winner"] as? String {
        case "a":
            #expect(ThreadKeyring.wins(a, over: b), "\(name): a should displace b")
            #expect(!ThreadKeyring.wins(b, over: a), "\(name): b displaced a as well")
        case "b":
            #expect(ThreadKeyring.wins(b, over: a), "\(name): b should displace a")
            #expect(!ThreadKeyring.wins(a, over: b), "\(name): a displaced b as well")
        default:
            #expect(!ThreadKeyring.wins(a, over: b), "\(name): there is no winner here")
            #expect(!ThreadKeyring.wins(b, over: a), "\(name): there is no winner here")
        }
    }

    /// The pairs a leading-byte comparison would pass are the ones doing the
    /// work, and a corpus that lost them would report PASS for ever.
    @Test("the order pairs still include the ones that are hard")
    func theHardOrderPairsAreStillThere() throws {
        let pairs = try Self.section("order", of: Self.load())
        func bytes(_ row: [String: Any], _ field: String) -> [UInt8]? {
            (try? Self.decode(row[field], ""))?.withUnsafeBytes { Array($0) }
        }
        let lastByteOnly = pairs.filter { row in
            guard let a = bytes(row, "a"), let b = bytes(row, "b") else { return false }
            return a.dropLast() == b.dropLast() && a.last != b.last
        }
        let firstByteDiffers = pairs.filter { row in
            guard let a = bytes(row, "a"), let b = bytes(row, "b") else { return false }
            return a.first != b.first
        }
        #expect(lastByteOnly.count >= 2, "the pairs that differ only in the last byte are gone")
        #expect(firstByteDiffers.count >= 2, "the pairs that differ in the first byte are gone")
    }

    /// The whole point of retiring a key, on the artefact both languages
    /// read: what this Mac sealed while it ran free still opens, and the key
    /// that opens it is never the one anything seals with now.
    @Test("a retired key opens what it sealed and seals nothing new")
    func aRetiredKeyOpensWhatItSealedAndSealsNothing() throws {
        let vectors = try Self.section("written", of: Self.load())
        let vector = try #require(vectors.first { $0["sealed"] != nil },
                                  "no vector carries a sealed sample any more")
        let url = Self.scratch()
        try #require(vector["text"] as? String).write(to: url, atomically: true, encoding: .utf8)
        let keyring = ThreadKeyring(url: url) { _ in }
        let sealing = try #require(keyring.key(for: Self.memory))

        for sample in try #require(vector["sealed"] as? [[String: Any]]) {
            let combined = try #require(sample["combined"] as? String)
            let plain = try #require(sample["text"] as? String)
            let under = sample["under"] as? String ?? ""
            let opened = keyring.openingKeys(for: Self.memory)
                .compactMap { ThreadCrypto.open(combined, with: $0) }
            #expect(opened == [plain], "the opening keys did not open the \(under) sample")
            if under == "retired" {
                #expect(ThreadCrypto.open(combined, with: sealing) == nil,
                        "the retired sample opened under the sealing key — they are one key")
            }
        }
    }

    // MARK: - Shared checking

    static func decode(_ value: Any?, _ name: String) throws -> SymmetricKey {
        guard let text = value as? String, let raw = Data(base64Encoded: text), raw.count == 32
        else { throw VectorError.malformed("\(name): not a 32-byte base64 key") }
        return SymmetricKey(data: raw)
    }

    /// Load a vector's file text and hold the keyring to its `expect` block.
    /// One routine for `written` and `tolerated` so the two sections cannot
    /// drift into asking different questions.
    static func checkExpectation(_ vector: [String: Any], label: String) throws {
        let name = vector["name"] as? String ?? "(unnamed)"
        let url = scratch()
        guard let text = vector["text"] as? String else {
            throw VectorError.malformed("\(label)/\(name) has no text")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        let keyring = ThreadKeyring(url: url) { _ in }
        guard let expect = vector["expect"] as? [String: [String: Any]] else {
            throw VectorError.malformed("\(label)/\(name) has no expect block")
        }
        for (thread, wanted) in expect {
            let opening = keyring.openingKeys(for: thread).map(b64)
            #expect(opening == (wanted["opening"] as? [String] ?? []),
                    "\(label)/\(name): the opening keys for \(thread) are not the vector's")
            #expect(Set(opening).count == opening.count,
                    "\(label)/\(name): \(thread) named one key twice")
            #expect(keyring.key(for: thread).map(b64) == wanted["sealing"] as? String,
                    "\(label)/\(name): the sealing key for \(thread) is not the vector's")
            #expect(keyring.retiredCount(for: thread) == wanted["retired_count"] as? Int,
                    "\(label)/\(name): the history length for \(thread) is not the vector's")
            if let first = opening.first {
                #expect(first == wanted["sealing"] as? String,
                        "\(label)/\(name): the key that seals is not the first one tried")
            }
        }
    }
}
