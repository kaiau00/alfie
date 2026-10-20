import Foundation
import CryptoKit

/// One record in the ledger — the whole of what is true, in the shape
/// `docs/ONE-AGENT.md` §1.5 specifies.
///
///     {"id":"b3f0c1…","kind":"turn","at":"2026-08-31T09:14:02Z",
///      "device":"mac-9f3c","seq":41,"prev":"a91e…","after":["c72d…"],
///      "body":{…}}
///
/// `id` is the hash of everything else, so replaying a record twice is a
/// no-op and two devices that saw the same thing agree on what to call it.
/// `seq`/`prev` chain one device's own writes, so a truncated file is
/// detectable rather than silent. `after` is what this author had already
/// seen when it wrote — the only ordering signal that survives two clocks.
public struct LedgerRecord: Equatable, Sendable {

    /// Deliberately a string, not an enum. A build that meets a kind from a
    /// newer version must skip it and keep reading, not fail to decode the
    /// file (§8, "records from a newer version").
    public var kind: String
    public var id: String
    public var at: Date
    public var device: String
    public var seq: Int
    public var prev: String?
    public var after: [String]
    public var body: JSONValue

    /// The author's Ed25519 signature over `signedBytes`, when one is known
    /// (docs/LEDGER-WIRE.md §12.1). A **sidecar**, not a field: it is not in
    /// the canonical form, not in the id, not on the `.jsonl` line, and not
    /// part of equality — two copies of one record are the same record
    /// whether or not one of them travelled with its signature. It rides
    /// here rather than in a wrapper type so every path that carries a
    /// record can carry its signature without a second set of types; the
    /// only things that read it are the transports and `SyncClient`.
    public var signature: Data?

    /// Kinds this build understands. Anything else is carried, not read.
    public enum Kind {
        public static let turn = "turn"
        /// A thread the person deleted. Turns before it are suppressed; a
        /// turn after it revives the thread, because continuing to talk in a
        /// thread is a clearer intent than the deletion that preceded it.
        public static let threadDelete = "thread.delete"
        /// One memory fact, asserted or retracted (LEDGER-WIRE §13.4;
        /// `Claims.swift`). Its `text` is sealed with the `moe:memory` key.
        public static let claim = "claim"
        /// A whole file the machine must hold a current copy of — the
        /// persona, the profile, the disabled-skills list (§13.5;
        /// `DocumentRecord`). Latest in ledger order wins; no merge.
        public static let document = "document"

        /// Work the machine cannot do itself, queued for the Mac
        /// (docs/LEDGER-WIRE.md §14). It names a thread — it was asked for in
        /// a conversation, and is sealed under that conversation's key — but
        /// it is machinery, not something the person said: everything that
        /// renders a thread filters to `turn`.
        public static let intent = "intent"

        /// What the Mac did about an `intent`, naming it by record id.
        public static let intentResult = "intent.result"
    }

    /// Where this record sits among ones it has no causal relationship with.
    var key: Ledger.SortKey { Ledger.SortKey(at: at, device: device, seq: seq) }

    /// Everything this record's author had already seen, as far as the
    /// record says: what it named, plus its own previous write, which its
    /// author had certainly seen.
    var parents: [String] { after + [prev].compactMap { $0 } }

    public init(kind: String, at: Date, device: String, seq: Int,
                prev: String?, after: [String], body: JSONValue) {
        self.kind = kind
        self.at = at
        self.device = device
        self.seq = seq
        self.prev = prev
        self.after = after
        self.body = body
        self.id = ""
        self.id = Self.hash(of: self)
    }

    /// Everything but the sidecar. See `signature`.
    public static func == (a: LedgerRecord, b: LedgerRecord) -> Bool {
        a.id == b.id && a.kind == b.kind && a.at == b.at && a.device == b.device
            && a.seq == b.seq && a.prev == b.prev && a.after == b.after && a.body == b.body
    }

    /// Decoded from disk, keeping whatever id the writer gave it — an older
    /// reader must not "correct" a record it does not fully understand.
    private init(id: String, kind: String, at: Date, device: String, seq: Int,
                 prev: String?, after: [String], body: JSONValue) {
        self.id = id; self.kind = kind; self.at = at; self.device = device
        self.seq = seq; self.prev = prev; self.after = after; self.body = body
    }

    // MARK: - Wire form

    static let timestamps: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Everything but `id`, which is a hash of exactly this.
    private var unsignedFields: [String: Any] {
        var out: [String: Any] = [
            "kind": kind,
            "at": Self.timestamps.string(from: at),
            "device": device,
            "seq": seq,
            "after": after,
            "body": body.anyValue,
        ]
        if let prev { out["prev"] = prev }
        return out
    }

    public var jsonObject: [String: Any] {
        var out = unsignedFields
        out["id"] = id
        return out
    }

    /// The §11 `Record` object: the file form plus `sig` when the record
    /// carries its signature. This is what crosses the network; the file
    /// form is what does not carry `sig` (§12.1).
    public var wireObject: [String: Any] {
        var out = jsonObject
        if let signature { out["sig"] = signature.base64EncodedString() }
        return out
    }

    /// The bytes the id is the hash of: the canonical form of §1.2.
    public var canonicalBytes: Data {
        (try? JSONSerialization.data(withJSONObject: unsignedFields,
                                     options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// What the author signs (§12.1): `"moe.record.v1"` ‖ `\0` ‖ the
    /// canonical bytes. The domain prefix is what stops a signature over a
    /// record being replayed as a signature over anything else that happens
    /// to serialise to the same bytes.
    public static let signatureDomain = Data("moe.record.v1\u{0}".utf8)

    public var signedBytes: Data { LedgerRecord.signatureDomain + canonicalBytes }

    /// A record whose words are in the clear: a string `text` in the body
    /// and no `text_enc`, whatever the kind (LEDGER-WIRE §13.3). Such a
    /// record is fine on one machine — it is what turns written before the
    /// keyring existed and claims written before the memory key existed
    /// look like — and must never cross a network (§12.2): a client does
    /// not push it and does not adopt it from a pull, and the edge refuses
    /// it.
    ///
    /// The rule used to be `kind == turn`. A sealed `claim` and a `document`
    /// carry their words the same way a turn does, and a plaintext one of
    /// either is the same disclosure; guarding on the kind would have let
    /// every kind but one through.
    public var carriesPlaintext: Bool {
        body["text_enc"] == nil && body["text"]?.stringValue != nil
    }

    /// One line of the `.jsonl` file. Sorted keys and no escaped slashes so
    /// the bytes are a function of the record and nothing else.
    public func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject,
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Nil for a line that is not a record this build can read at all —
    /// a torn write, a hand edit, a truncated file. Never throws: one bad
    /// line must not cost the rest of the ledger.
    public static func decode(line: Data) -> LedgerRecord? {
        guard let any = try? JSONSerialization.jsonObject(with: line),
              let obj = any as? [String: Any],
              let id = obj["id"] as? String,
              let kind = obj["kind"] as? String,
              let atText = obj["at"] as? String,
              let at = parse(timestamp: atText),
              let device = obj["device"] as? String,
              let seq = obj["seq"] as? Int
        else { return nil }
        let body = (obj["body"]).flatMap { JSONValue(any: $0) } ?? .object([:])
        let after = (obj["after"] as? [String]) ?? []
        return LedgerRecord(id: id, kind: kind, at: at, device: device, seq: seq,
                            prev: obj["prev"] as? String, after: after, body: body)
    }

    /// Fractional seconds are written but must not be required: a record
    /// hand-written or produced by another runtime may not have them.
    static func parse(timestamp: String) -> Date? {
        if let d = timestamps.date(from: timestamp) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: timestamp)
    }

    // MARK: - Identity

    /// Whether this record's id really is the hash of the rest of it.
    ///
    /// Nothing on one machine needs to ask: a record read from disk keeps the
    /// id its writer gave it, and that is deliberate (§8, a newer version's
    /// records must survive an older reader). It matters the moment records
    /// cross a network. A server that accepted a record whose id was not its
    /// content would let one device choose another's ids, and since the id is
    /// the primary key and replay is a no-op, a chosen id is a way to stop a
    /// real record from ever landing. `MoeCloud`'s push checks this at the
    /// door and its pull checks it again on arrival — the second time as a
    /// check on the transport, since a body that came back subtly different
    /// from the one that went in would fail here and nowhere else.
    public var isContentAddressed: Bool { id == LedgerRecord.hash(of: self) }

    /// sha256 over the canonical form of everything but the id, truncated to
    /// 128 bits. Content-addressed: the same record written twice, on either
    /// machine, is the same record and replaying it changes nothing.
    static func hash(of record: LedgerRecord) -> String {
        let canonical = (try? JSONSerialization.data(
            withJSONObject: record.unsignedFields,
            options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }
            .joined().prefix(32).description
    }
}
