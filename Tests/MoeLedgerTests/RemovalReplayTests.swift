import Foundation
import Testing
import CryptoKit
@testable import MoeLedger

/// The Mac's half of LEDGER-WIRE §15.3 — replay.
///
/// §15.1 made composing a `connection/*` removal take `moe:connections`. It
/// did nothing about **copying** one: every enrolled device has the ledger,
/// so the removal a machine carried out could be aimed at that connection
/// again after a re-grant, and the grant it superseded could be written back
/// over the one it is running on (§18.12's clobber, induced).
///
/// **The scope is "a body this machine applied cannot be applied again"**,
/// and not a word wider — a machine that never applied a removal cannot
/// refuse a copy of it, and the body currently in force is exempt by
/// construction. §15.3 states all of it; nothing here should be read as
/// claiming more. Note also that `appendRemoval` has no production caller in
/// either language yet: §15.1 and §15.3 have never met a live revocation.
///
/// **The closing rule lives on the machine**, in
/// `moeledger/connections.py::_replayed`, because that is where the applier
/// is: `DocumentRecord` has no production reader on the Mac (the direction
/// gate makes a credential travel Mac → away machine only). What lives here
/// is the half the rule *stands on*, and it is the writer's:
///
/// * a document has two identities — its plaintext (`sha256`, which
///   credential) and its seal (`sealFingerprint`, which act of sealing) —
///   and the reader needs both, so `parse` must surrender both;
/// * **every write seals afresh.** Two removals of one connection have the
///   same plaintext by design and must have different seals, because that
///   difference is the only thing telling a second genuine revocation apart
///   from a replay of the first. A deterministic seal here would turn the
///   machine's defence into a silent refusal of a real revocation, which is
///   the outcome §15.1 refuses in its own docstring.
///
/// So these are falsifiers for the Mac not breaking the machine — the
/// direction that has no test on the machine's side, because nothing there
/// can run Swift.
@Suite("Replay of a sealed body (LEDGER-WIRE §15.3)")
struct RemovalReplayTests {

    let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))

    private func record(_ body: JSONValue) -> LedgerRecord {
        LedgerRecord(kind: LedgerRecord.Kind.document, at: Date(), device: "dev",
                     seq: 1, prev: nil, after: [], body: body)
    }

    // MARK: - The property the machine's defence stands on

    @Test("two revocations of one connection are one plaintext and two seals")
    func removalsShareAPlaintextAndNotASeal() throws {
        let first = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        let second = try DocumentRecord.removalBody(name: "connection/supabase", key: key)

        // One plaintext: the tombstone names the document and nothing else,
        // so the machine records the same `sha256` for both. A memory keyed
        // on THAT would refuse the second, real revocation — silently, which
        // is worse than the replay it was closing.
        #expect(DocumentRecord.parse(record(first), key: key)?.sha256
                == DocumentRecord.parse(record(second), key: key)?.sha256)

        // Two seals: the freshness is the GCM nonce inside the sealed bytes,
        // and it is what lets the machine tell the two acts apart.
        let a = DocumentRecord.parse(record(first), key: key)?.seal
        let b = DocumentRecord.parse(record(second), key: key)?.seal
        #expect(a != nil && b != nil)
        #expect(a != b, "a deterministic seal makes a real revocation look like a replay")
        #expect(DocumentRecord.sealFingerprint(a) != DocumentRecord.sealFingerprint(b))
    }

    @Test("two writes of one credential are one plaintext and two seals")
    func grantsShareAPlaintextAndNotASeal() throws {
        let text = #"{"server":{"url":"https://mcp.example.com/u/abc"}}"#
        let first = try DocumentRecord.body(name: "connection/supabase", text: text, key: key)
        let second = try DocumentRecord.body(name: "connection/supabase", text: text, key: key)

        // The same pair, for a grant. The plaintext identity is what stops a
        // re-publication of the credential in force being read as a new grant
        // and rewriting a token the machine has since refreshed (§18.12); the
        // seal identity is what stops an OLD one coming back over it.
        #expect(DocumentRecord.parse(record(first), key: key)?.sha256
                == DocumentRecord.parse(record(second), key: key)?.sha256)
        #expect(DocumentRecord.parse(record(first), key: key)?.seal
                != DocumentRecord.parse(record(second), key: key)?.seal)
    }

    // MARK: - The reader surrenders both identities

    @Test("parse carries the seal verbatim")
    func parseCarriesTheSeal() throws {
        let body = try DocumentRecord.body(name: "connection/supabase",
                                           text: #"{"server":{}}"#, key: key)
        let document = DocumentRecord.parse(record(body), key: key)
        #expect(document?.seal == body["text_enc"]?.stringValue)

        // And with no key at all: the seal is cleartext on the wire, so a
        // reader that cannot OPEN a document can still tell whether it has
        // already acted on those exact bytes. That is what makes the memory
        // work on a device waiting for its key.
        let blind = DocumentRecord.parse(record(body), key: nil)
        #expect(blind?.text == nil)
        #expect(blind?.seal == body["text_enc"]?.stringValue)
    }

    @Test("a sealed tombstone carries a seal and the old shape does not")
    func onlyTheSealedShapeHasASeal() throws {
        let sealed = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        #expect(DocumentRecord.parse(record(sealed), key: key)?.seal != nil)

        // §13.5's removal is `text_enc: ""` — a constant, which is the hole
        // §15.1 closed. It is not an identity of anything, and hashing it
        // would give every unsealed removal in the tenant one shared
        // fingerprint. `soul` and the profile still write this shape.
        let old = try DocumentRecord.body(name: "profile/people.md", text: nil, key: key)
        #expect(old["text_enc"]?.stringValue == "")
        #expect(DocumentRecord.parse(record(old), key: key)?.seal == nil)
        #expect(DocumentRecord.sealFingerprint("") == nil)
        #expect(DocumentRecord.sealFingerprint(nil) == nil)
    }

    // MARK: - The two languages agree on the identity function

    @Test("the seal fingerprint is the same function in both languages")
    func fingerprintMatchesPython() throws {
        // The same literal is asserted by `tests/test_removal_replay.py`, the
        // way `removalText`'s sha is — the only thing that makes "the two
        // agree" a fact rather than two functions written on one afternoon.
        // `"AAAA"` is the junk seal §15.2 was measured with, so it is already
        // a literal both suites recognise.
        #expect(DocumentRecord.sealFingerprint("AAAA")
                == "63c1dd951ffedf6f7fd968ad4efa39b8ed584f162f46e715114ee184f8de9201")
        // A fingerprint is of the ciphertext, never of the plaintext: the two
        // hashes mean opposite things and reaching for the wrong one would be
        // wrong in a way that looks right.
        let body = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        let document = DocumentRecord.parse(record(body), key: key)
        #expect(DocumentRecord.sealFingerprint(document?.seal) != document?.sha256)
    }

    // MARK: - Nothing about the wire changed

    @Test("the body a revocation writes is byte-for-byte what it always was")
    func theWireIsUnchanged() throws {
        // §15.3 is closed by a memory on the reader, not by a wire change,
        // and that is the whole compatibility story: an older reader meets
        // bytes it already understands. Pinned here so a later attempt to put
        // a nonce or a counter in the plaintext has to argue with the reason
        // this one did not.
        let body = try DocumentRecord.removalBody(name: "connection/supabase", key: key)
        guard case .object(let fields) = body else { Issue.record("not an object"); return }
        #expect(Set(fields.keys) == DocumentRecord.bodyKeys)
        #expect(body["bytes"]?.intValue == 0)
        #expect(DocumentRecord.removalText(name: "connection/supabase")
                == #"{"moe:removed":true,"name":"connection/supabase","v":1}"#)
        #expect(DocumentRecord.removalVersion == 1)
    }
}
