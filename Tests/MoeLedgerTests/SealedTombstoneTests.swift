import Foundation
import Testing
import CryptoKit
@testable import MoeLedger

/// The Mac's half of LEDGER-WIRE §15.1 — the sealed tombstone.
///
/// The machine's half shipped first, in `moeledger/connections.py`, and a
/// review found the asymmetry that left: **Swift could still write the dead
/// shape and could not write a live one.** `DocumentRecord.body` had no name
/// check and `append(name:text:nil,…)` is public, so on the Mac — the side
/// that owns revocation — the one obvious call produced a record the machine
/// now ignores. That is the outcome the Python constructor's own docstring
/// refuses ("a revocation that silently does nothing"), and the Mac is where
/// it would actually have been made.
///
/// These tests are the falsifiers for that pair, plus the cross-language
/// agreements the two halves have to keep: the canonical plaintext, the four
/// body keys, and the `sha256` of a removal — which disagreed across the two
/// languages the moment a tombstone gained a plaintext.
@Suite("Sealed tombstones (LEDGER-WIRE §15.1)")
struct SealedTombstoneTests {

    let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    let other = SymmetricKey(data: Data((32..<64).map { UInt8($0) }))

    private func record(_ body: JSONValue) -> LedgerRecord {
        LedgerRecord(kind: LedgerRecord.Kind.document, at: Date(), device: "dev",
                     seq: 1, prev: nil, after: [], body: body)
    }

    // MARK: - The refusal

    @Test("the general constructor refuses a connection removal")
    func bodyRefusesConnectionRemoval() throws {
        #expect(throws: DocumentError.self) {
            _ = try DocumentRecord.body(name: "connection/supabase", text: nil, key: key)
        }
        // And the message points at the replacement rather than just saying no.
        do {
            _ = try DocumentRecord.body(name: "connection/supabase", text: nil, key: key)
            Issue.record("no refusal")
        } catch let error as DocumentError {
            #expect(error.description.contains("removalBody"))
        }
    }

    @Test("the identity document is on the same list")
    func bodyRefusesIdentityRemoval() throws {
        // `composio-identity` is a §15 document in every respect but its name:
        // same key, same reader, same refusals. Leaving it off the Python list
        // was a review finding, so the Swift list starts with it on.
        #expect(throws: DocumentError.self) {
            _ = try DocumentRecord.body(name: DocumentRecord.identityDocument,
                                        text: nil, key: key)
        }
        #expect(DocumentRecord.sealedUnderConnectionsKey("composio-identity"))
        #expect(DocumentRecord.sealedUnderConnectionsKey("connection/x"))
        #expect(DocumentRecord.sealedUnderConnectionsKey("telegram-app"),
                "the Telegram app keys are sealed under moe:connections on both sides")
        #expect(!DocumentRecord.sealedUnderConnectionsKey("soul"))
        #expect(!DocumentRecord.sealedUnderConnectionsKey("profile/people.md"))
    }

    @Test("every other document's removal is untouched")
    func memoryRemovalsAreUnchanged() throws {
        // §13.5's empty `text_enc` is on the wire, in the vectors, and none of
        // those documents is a credential. Changing it here would have been a
        // wire change for four names that did not need one.
        let body = try DocumentRecord.body(name: "profile/people.md", text: nil, key: key)
        #expect(body["bytes"]?.intValue == 0)
        #expect(body["text_enc"]?.stringValue == "")
        #expect(DocumentRecord.parse(record(body), key: key)?.removed == true)
    }

    // MARK: - What a sealed tombstone is

    @Test("a sealed removal needs the key and keeps the four body keys")
    func removalBodyShape() throws {
        let body = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        guard case .object(let fields) = body else { Issue.record("not an object"); return }
        #expect(Set(fields.keys) == DocumentRecord.bodyKeys)
        #expect(body["bytes"]?.intValue == 0)
        let sealed = try #require(body["text_enc"]?.stringValue)
        #expect(!sealed.isEmpty, "an empty seal is the shape that needs no key")
        #expect(ThreadCrypto.open(sealed, with: key) ==
                DocumentRecord.removalText(name: "connection/supabase"))
        #expect(ThreadCrypto.open(sealed, with: other) == nil)
    }

    @Test("the plaintext is canonical, and names the document")
    func removalTextIsCanonical() {
        #expect(DocumentRecord.removalText(name: "connection/supabase")
                == #"{"moe:removed":true,"name":"connection/supabase","v":1}"#)
        // The binding: the seal alone proves only that the key exists
        // somewhere, and `name` travels in the body's cleartext.
        #expect(DocumentRecord.isRemovalText(
            name: "connection/supabase",
            DocumentRecord.removalText(name: "connection/supabase")))
        #expect(!DocumentRecord.isRemovalText(
            name: "connection/cloudflare",
            DocumentRecord.removalText(name: "connection/supabase")))
    }

    @Test("what a removal may not say")
    func isRemovalTextRefusals() {
        let name = "connection/supabase"
        #expect(!DocumentRecord.isRemovalText(name: name, nil))
        #expect(!DocumentRecord.isRemovalText(name: name, "not json"))
        #expect(!DocumentRecord.isRemovalText(name: name, "[]"))
        #expect(!DocumentRecord.isRemovalText(name: name, #"{"name":"connection/supabase"}"#))
        #expect(!DocumentRecord.isRemovalText(
            name: name, #"{"moe:removed":false,"name":"connection/supabase"}"#))
        #expect(!DocumentRecord.isRemovalText(name: name, #"{"moe:removed":true}"#))
        // A newer writer's extra field is tolerated: refusing one would make
        // every older Mac reject a revocation it should honour.
        #expect(DocumentRecord.isRemovalText(
            name: name,
            #"{"moe:removed":true,"name":"connection/supabase","v":1,"why":"unlinked"}"#))
    }

    @Test("a name with a quote in it does not break the plaintext")
    func removalTextEscapes() throws {
        // `removalText` is written by hand because the byte order is a wire
        // contract, so the escaping is this function's own problem. The name
        // rule would reject this before it ever became a path, which is
        // exactly why a malformed seal here would be found late.
        let name = #"connection/a"b\c"#
        let text = DocumentRecord.removalText(name: name)
        let parsed = try JSONSerialization.jsonObject(
            with: #require(text.data(using: .utf8))) as? [String: Any]
        #expect(parsed?["name"] as? String == name)
        #expect(DocumentRecord.isRemovalText(name: name, text))
    }

    // MARK: - What the two languages have to agree on

    @Test("a sealed removal reads as removed, with or without the key")
    func parseSealedRemoval() throws {
        let body = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        let withKey = try #require(DocumentRecord.parse(record(body), key: key))
        #expect(withKey.removed)
        #expect(withKey.text == DocumentRecord.removalText(name: "connection/supabase"))

        // No key: still a removal. `bytes` decides, in both languages — which
        // is the whole reason an older reader still de-configures on one.
        let without = try #require(DocumentRecord.parse(record(body), key: nil))
        #expect(without.removed)
        #expect(without.text == nil)
    }

    @Test("the sha of a removal is the sha of what was opened")
    func removalShaMatchesPython() throws {
        // The F6 disagreement. This used to be `sha256(of: "")` for every
        // `bytes: 0` record; Python's `Document.sha256` hashes the opened
        // plaintext, so once a tombstone HAD a plaintext the two sides wrote
        // different shas into their `documents.json` for one record.
        let body = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        let text = DocumentRecord.removalText(name: "connection/supabase")
        #expect(DocumentRecord.parse(record(body), key: key)?.sha256
                == DocumentRecord.sha256(of: text))
        // The literal, pinned in BOTH languages — the same constant is
        // asserted by `test_sealed_tombstone.py`. This is the only thing that
        // makes "the two agree" a fact rather than two functions that happen
        // to have been written on the same afternoon. There is no vector for
        // the new shape yet (see the note in LEDGER-WIRE §15.1), so this pair
        // of literals is standing in for one.
        #expect(DocumentRecord.sha256(of: text)
                == "b2cfa7563d57e81bb36e9a9259826a438734e4fe83300356fd2357fdb14824f5")

        // The old shape is unchanged: nothing opened, so the empty string.
        let old = try DocumentRecord.body(name: "profile/people.md", text: nil, key: key)
        #expect(DocumentRecord.parse(record(old), key: key)?.sha256
                == DocumentRecord.sha256(of: ""))
    }

    @Test("two seals of one removal are one removal")
    func twoSealsOneSha() throws {
        let a = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        let b = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        #expect(a["text_enc"]?.stringValue != b["text_enc"]?.stringValue,
                "a fixed nonce would be a worse bug")
        #expect(DocumentRecord.parse(record(a), key: key)?.sha256
                == DocumentRecord.parse(record(b), key: key)?.sha256)
    }

    // MARK: - Through the ledger

    @Test("a removal appended to a ledger is the newest of its name")
    func appendRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealed-tombstone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let ledger = Ledger(directory: directory, device: "mac-1")

        try DocumentRecord.append(name: "connection/supabase", text: #"{"server":{}}"#,
                                  to: ledger, key: key)
        #expect(DocumentRecord.latest(name: "connection/supabase",
                                      in: ledger, key: key)?.removed == false)

        try DocumentRecord.appendRemoval(name: "connection/supabase", to: ledger, key: key)
        let latest = try #require(DocumentRecord.latest(name: "connection/supabase",
                                                        in: ledger, key: key))
        #expect(latest.removed)
        #expect(DocumentRecord.isRemovalText(name: "connection/supabase", latest.text))
    }

    @Test("a sealed removal is not a plaintext record")
    func removalIsNotPlaintext() throws {
        // §13.3: a plaintext record never leaves the Mac and is refused by the
        // edge. If a tombstone counted as one the revocation would not travel.
        let body = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        #expect(record(body).carriesPlaintext == false)
    }
}
