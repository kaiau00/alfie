import Foundation
import Testing
@testable import MoeLedger

/// The agreement between the two languages that write this ledger.
///
/// Moe's Swift side and the `claimstore` Hermes plugin both mint claim ids,
/// both hash records, and both apply §3.1. They cannot share code — Swift
/// cannot run inside Hermes and Python cannot run inside the app — so what
/// keeps them one implementation is a committed vector file that each asserts
/// against independently:
///
///     moe-home/hermes-plugins/claimstore/tests/claim-conformance.json
///
/// Its Python half is `tests/test_conformance.py` in the same directory. The
/// file is *generated* by `tests/make_conformance.py` and *committed*, which
/// is the point: a fixture both sides recompute from their own code every run
/// proves nothing. Regenerating it is a deliberate act, and this test fails
/// until Swift is changed to match.
///
/// **Why this is the test that matters most.** A claim id that differs by one
/// character between the two runtimes does not crash anything. It produces two
/// halves of one person's memory that never notice each other — the Mac
/// asserting a fact the plugin will never recognise as the fact it already
/// holds, forever, silently. That is the worst failure this design has, and it
/// is invisible without exactly this file.
struct ClaimConformanceTests {

    // MARK: - The fixture

    struct Fixture {
        let claimIDs: [[String: Any]]
        let cases: [[String: Any]]
    }

    static let fixtureURL: URL = {
        // Up from Tests/MoeLedgerTests/ to the repo root, then into the
        // plugin. The fixture lives with the plugin because the plugin is the
        // half that ships to another machine; this side is the one that has
        // to go and find it.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MoeLedgerTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("moe-home/hermes-plugins/claimstore/tests/claim-conformance.json")
    }()

    static func load() throws -> Fixture {
        let data = try Data(contentsOf: fixtureURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Fixture(claimIDs: object["claim_ids"] as? [[String: Any]] ?? [],
                       cases: object["cases"] as? [[String: Any]] ?? [])
    }

    // MARK: - The claim id

    @Test func theTwoLanguagesMintTheSameClaimID() throws {
        let fixture = try Self.load()
        #expect(fixture.claimIDs.count >= 8, "the vector file lost its vectors")
        for vector in fixture.claimIDs {
            let target = vector["target"] as? String ?? ""
            let text = vector["text"] as? String ?? ""
            let expectedID = vector["id"] as? String ?? ""
            let expectedNormal = vector["normalised"] as? String ?? ""
            #expect(Claim.normalise(text) == expectedNormal,
                    "normalise(\(text.debugDescription)) diverged from Python")
            #expect(Claim.id(target: target, text: text) == expectedID,
                    "claim id for \(text.debugDescription) in \(target) diverged from Python")
        }
    }

    /// The revival rule, source class by source class, against the same
    /// matrix the Python side reads.
    ///
    /// `Claim.revives` is a two-line function and it was wrong for a week:
    /// Swift accepted only the literal `"user"` and Python also accepted any
    /// `hermes:`, which over identical bytes meant Python kept a deleted fact
    /// live and Swift dropped it. This asserts the function directly, so a
    /// divergence fails here as well as through the projection.
    @Test func onlyThePersonRevivesADeletedClaim() throws {
        for source in ["user", "user:memory-pane", "user:notch"] {
            #expect(Claim.revives(source: source), "\(source) is the person")
        }
        for source in ["hermes:assistant_tool", "hermes:background_review",
                       "hermes:side_question", "gmail", "imessage", "file",
                       "unknown", "", "users", "user-ish"] {
            #expect(!Claim.revives(source: source),
                    "\(source) must not be able to undo a person's deletion")
        }

        // And the fixture's matrix agrees with the function, row for row.
        let fixture = try Self.load()
        var rows = 0
        for testCase in fixture.cases {
            let name = testCase["name"] as? String ?? ""
            guard name.hasPrefix("restated-after-deletion-by-") else { continue }
            rows += 1
            let expected = testCase["expect"] as? [String: Any] ?? [:]
            let live = expected["live"] as? [String] ?? []
            let pending = expected["pending_revivals"] as? [[String: Any]] ?? []
            let source = (pending.first?["source"] as? String)
                ?? (expected["live_sources"] as? [String])?.first ?? ""
            #expect(Claim.revives(source: source) == !live.isEmpty,
                    "\(name): the fixture and Claim.revives disagree")
            #expect(pending.isEmpty == !live.isEmpty,
                    "\(name): a refused revival must become a question")
        }
        #expect(rows >= 8, "the revival matrix lost rows")
    }

    @Test func normalisationIsWhitespaceOnlyAndScalarWise() throws {
        // The three edges the enumerated whitespace set exists for. `\r\n` is
        // one `Character` in Swift and two scalars in Python; the C1 and
        // no-break spaces are whitespace to one language's built-in test and
        // not the other's. All three have to give the same id or two devices
        // silently hold two copies of one fact.
        #expect(Claim.normalise("a\r\nb") == "a b")
        #expect(Claim.normalise("a\u{0b}b\u{0c}c") == "a b c")
        #expect(Claim.normalise("\u{a0}x\u{a0}") == "\u{a0}x\u{a0}",
                "a no-break space is a character, not a separator")
        #expect(Claim.id(target: "memory", text: "one two")
                == Claim.id(target: "memory", text: "  one \t two \n"))
        #expect(Claim.id(target: "memory", text: "x") != Claim.id(target: "user", text: "x"))
        #expect(Claim.id(target: "memory", text: "x").count == Claim.idLength)
    }

    // MARK: - The record hash

    @Test func everyFixtureRecordHashesToTheIDPythonGaveIt() throws {
        let fixture = try Self.load()
        var checked = 0
        for testCase in fixture.cases {
            for raw in testCase["records"] as? [[String: Any]] ?? [] {
                let line = try JSONSerialization.data(withJSONObject: raw)
                let record = try #require(LedgerRecord.decode(line: line),
                                          "a fixture record did not decode")
                #expect(LedgerRecord.hash(of: record) == record.id,
                        "record \(record.id) rehashes differently in Swift: the canonical JSON encodings have diverged")
                checked += 1
            }
        }
        #expect(checked >= 20, "the vector file lost its records")
    }

    // MARK: - §3.1, decided identically on both sides

    @Test func everyFixtureCaseResolvesTheSameWayInSwift() throws {
        let fixture = try Self.load()
        for testCase in fixture.cases {
            let name = testCase["name"] as? String ?? "?"
            let target = testCase["target"] as? String ?? "memory"
            let expected = testCase["expect"] as? [String: Any] ?? [:]

            let directory = scratchRoot("claim-conformance")
            defer { try? FileManager.default.removeItem(at: directory) }
            try Self.write(records: testCase["records"] as? [[String: Any]] ?? [],
                           into: directory)

            let claims = ClaimLedger(ledger: Ledger(directory: directory, device: "reader"))
            let projection = claims.resolve(target: target)

            #expect(projection.texts == (expected["live"] as? [String] ?? []),
                    "\(name): live set diverged from Python")
            #expect(projection.live.map(\.source) == (expected["live_sources"] as? [String] ?? []),
                    "\(name): live sources diverged from Python")
            #expect(projection.superseded.map(\.text) == (expected["superseded"] as? [String] ?? []),
                    "\(name): superseded set diverged from Python")

            // The other half of the revival rule, and the half a fixture that
            // only checked `live` let diverge in silence: Swift revived on the
            // literal "user" while Python also revived on any `hermes:`, and
            // every revival case happened to use a source the two agreed on.
            let expectedPending = expected["pending_revivals"] as? [[String: Any]] ?? []
            #expect(projection.pendingRevivals.map(\.source)
                    == expectedPending.map { $0["source"] as? String ?? "" },
                    "\(name): pending revivals diverged from Python")
            #expect(projection.pendingRevivals.map(\.text)
                    == expectedPending.map { $0["text"] as? String ?? "" },
                    "\(name): pending revival text diverged from Python")

            let expectedDisagreements = expected["disagreements"] as? [[String: Any]] ?? []
            #expect(projection.disagreements.count == expectedDisagreements.count,
                    "\(name): disagreement count diverged from Python")
            for (mine, theirs) in zip(projection.disagreements, expectedDisagreements) {
                #expect(mine.key == theirs["key"] as? String, "\(name): disagreement key")
                #expect(mine.sources.sorted() == theirs["sources"] as? [String] ?? [],
                        "\(name): disagreement sources")
                #expect(mine.readings.map(\.text).sorted() == theirs["readings"] as? [String] ?? [],
                        "\(name): disagreement readings")
            }
        }
    }

    /// Lay the fixture's records out as a ledger directory — one file per
    /// device, records in the order the fixture gives them, which is the
    /// order they were written.
    static func write(records: [[String: Any]], into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines: [String: Data] = [:]
        var order: [String] = []
        for raw in records {
            guard let device = raw["device"] as? String else { continue }
            if lines[device] == nil { order.append(device) }
            var payload = lines[device] ?? Data()
            payload.append(try JSONSerialization.data(withJSONObject: raw,
                                                      options: [.sortedKeys, .withoutEscapingSlashes]))
            payload.append(UInt8(ascii: "\n"))
            lines[device] = payload
        }
        for device in order {
            try lines[device]?.write(to: directory.appendingPathComponent(device)
                .appendingPathExtension("jsonl"))
        }
    }
}
