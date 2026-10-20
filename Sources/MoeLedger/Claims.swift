import Foundation
import CryptoKit

/// Memory, as records.
///
/// §1.5 declared a `claim` kind and slice 1 carried it without writing one
/// (§12). This is what writes it, and what reads it back under §3.1's claim
/// rules. The store is the ledger; `~/.hermes/memories/MEMORY.md` and
/// `USER.md` are a digest of it, projected by the `claimstore` Hermes plugin
/// (`moe-home/hermes-plugins/claimstore/`), which is the sole writer of those
/// two files.
///
/// **The one number both sides must agree on is `Claim.id`.** The plugin
/// mints it in Python and this file mints it in Swift, and two devices that
/// learn the same fact converge only because those two implementations return
/// the same twelve characters. A disagreement there is not a crash: it is two
/// halves of one memory that never notice each other, which is the worst
/// failure this design has. `moe-home/hermes-plugins/claimstore/tests/
/// claim-conformance.json` is a shared vector file both languages assert
/// against, so a drift in either fails a test rather than being discovered by
/// a person whose Mac forgot something.
///
/// **A claim body deliberately has no `thread` field.** `ConversationProjector`
/// indexes threads by `body["thread"]` and removes the file of a thread that
/// has a tombstone and nothing surviving; §13.1's eighth finding is about
/// exactly what happens the day a `claim` names a thread. Memory is not filed
/// under a conversation, so it does not have to be.
///
/// **The words are sealed** (LEDGER-WIRE §13.4) with the `moe:memory` key
/// (§13.2), exactly as a turn's are with its thread's: `enc` and `text_enc`
/// in place of `text`. Everything the rules operate on — `op`, the claim id,
/// `target`, `key`, `source` — stays in the clear, so a reader without the
/// key can still count a claim and match its asserts to its retracts; what
/// it cannot do is say what the claim says, and it does not try.
public enum Claim {

    /// Whitespace, enumerated rather than asked for.
    ///
    /// `Character.isWhitespace` and Python's `str.split()` do not agree —
    /// Python treats the C1 separators as whitespace and Swift does not, and
    /// Swift's `Character` folds `\r\n` into one grapheme that is in neither
    /// set. Either would be a claim id that differs across the two runtimes
    /// for one sentence in a million, which is precisely the failure that
    /// must not be possible. So the set is written out, matched character for
    /// character by `store.py:_WHITESPACE`, and applied to unicode scalars.
    static let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0b}", "\u{0c}"]

    /// Collapse whitespace runs to single spaces and trim.
    ///
    /// Deliberately weak: "the same fact" means "the same words". Case,
    /// punctuation and accents all still make a different claim, because a
    /// normaliser clever enough to merge them is also clever enough to merge
    /// two facts that were never the same one.
    public static func normalise(_ text: String) -> String {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if whitespace.contains(scalar) {
                if !current.isEmpty { parts.append(String(current)); current = String.UnicodeScalarView() }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { parts.append(String(current)) }
        return parts.joined(separator: " ")
    }

    /// Length of the truncated sha256 used as a claim id. Twelve hex chars is
    /// 48 bits — negligible collision risk at personal scale, and short
    /// enough to read aloud in a bug report.
    public static let idLength = 12

    /// The content address of `text` within `target`.
    ///
    /// `sha256(target + "\n" + normalise(text))`, truncated. Scoped by target
    /// so the same sentence filed as a user-profile fact and as an agent note
    /// are two claims — they mean different things and are retracted
    /// independently.
    ///
    /// Mirrored exactly by `claimstore.store.claim_id`.
    public static func id(target: String, text: String) -> String {
        let canonical = "\(target)\n\(normalise(text))"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(idLength))
    }

    public enum Op {
        public static let assert = "assert"
        public static let retract = "retract"
    }

    /// The source name a person's own statement carries.
    public static let userSource = "user"
    /// Sources that also count as the person: a caller that has a real signal
    /// the human asked, and says which surface it came from.
    public static let userSourcePrefix = "user:"

    /// Whether an assert from `source` may undo a retraction (§3.1's tombstone
    /// amendment). Mirrored exactly by `claimstore.store.revives`.
    ///
    /// **Only the person. Not the model, not a crawl, not a background pass.**
    /// This started wider — a memory-tool write carries `hermes:<origin>` and
    /// it was tempting to read that as "the user told the Mac to remember it
    /// again", which is §3.1's own worked example. It is not. Hermes produces
    /// exactly three `write_origin` values — `assistant_tool` (the default,
    /// and precisely the model deciding on its own initiative),
    /// `background_review` and `side_question` — and **none of them means a
    /// person asked for anything.** Accepting them meant that a fact somebody
    /// deleted about themselves could be silently restored by the assistant
    /// noticing it again, with nobody in the loop. That is the worst thing
    /// this design could do, and it is worth losing a convenience to make
    /// impossible.
    ///
    /// So the rule is narrow and the burden is on the caller: a source counts
    /// as the person only when it says so, which a writer may claim only when
    /// it actually has that signal — a Memory pane edit, an explicit "yes,
    /// remember that again". Everything else that re-states a deleted fact
    /// becomes a `pendingRevival` and is asked about rather than applied.
    public static func revives(source: String) -> Bool {
        source == userSource || source.hasPrefix(userSourcePrefix)
    }

    /// One live memory fact, as the projection sees it.
    public struct Live: Equatable, Sendable {
        public let id: String
        public let target: String
        /// The topic this claim is a reading of. Two claims sharing a key are
        /// two answers to one question, which is what §3.1's last two rules
        /// are about. Defaults to the claim's own id, so a claim with no
        /// topic can only ever contend with itself.
        public let key: String
        public let source: String
        public let text: String
        /// The ledger record that asserted it — kept so `moe memory why` and
        /// a failing test can name the record rather than the sentence.
        public let recordID: String
    }

    /// Two or more sources with different readings of one topic. §3.1: the
    /// genuine disagreement, and the one case that gets a model. Nothing is
    /// dropped for want of one — every reading here is also in `live`.
    public struct Disagreement: Equatable, Sendable {
        public let target: String
        public let key: String
        public let readings: [Live]
        public var sources: [String] { readings.map(\.source) }
    }

    /// A fact somebody deleted, re-stated afterwards by something that is not
    /// the person, *knowing* it had been deleted.
    ///
    /// This is not a bug and not an error: a crawl re-derives what it derived
    /// before, and the model notices the same thing twice. §3.1 says such an
    /// assert does not revive, and this build agrees — but "does not revive"
    /// used to mean the record was written and then silently ignored forever,
    /// and a person who typed a fact back into `MEMORY.md` by hand vanished
    /// into the same hole.
    ///
    /// So the third answer, which is this product's posture everywhere else:
    /// **ask**. The claim stays out of the digest, the record stays in the
    /// ledger, and it surfaces here so Moe can say "you deleted that before,
    /// want me to remember it again?" Answering yes is a `user`-sourced
    /// assert, which revives it by the ordinary rule. Nothing here restores
    /// anything, and nothing here drops anything.
    ///
    /// Only asserts causally *after* a tombstone appear. One that is
    /// concurrent with it was written by somebody who had not heard, and
    /// there is nothing to ask them about.
    public struct PendingRevival: Equatable, Sendable {
        public let claim: Live
        /// The retraction it came after. What "you deleted that before" points at.
        public let retractedBy: String
        public var id: String { claim.id }
        public var text: String { claim.text }
        public var source: String { claim.source }
    }

    /// A claim that is there and cannot be read: sealed, and this reader
    /// holds no key that opens it (LEDGER-WIRE §13.4). It is counted — the id, the slot
    /// and the source are in the clear — and nothing else: not projected,
    /// not superseded, not asked about, and never retracted on the person's
    /// behalf. It becomes an ordinary `Live` the moment the courier delivers
    /// the key and `resolve` runs again.
    public struct Unreadable: Equatable, Sendable {
        public let id: String
        public let target: String
        public let key: String
        public let source: String
        public let recordID: String
    }

    /// What `resolve` produces: what the digest should show, what it should
    /// ask about, and what it is deliberately leaving out.
    public struct Projection: Equatable, Sendable {
        public var live: [Live]
        public var disagreements: [Disagreement]
        /// Readings a newer statement from the same source replaced. Still in
        /// the ledger — §3.2: the projection is opinionated, the ledger is not.
        public var superseded: [Live]
        /// Deleted facts something has re-stated since. Questions, not entries.
        public var pendingRevivals: [PendingRevival]
        /// Claims that would be live if this reader could open them. Present,
        /// counted, and shown to nobody until the key arrives (§13.4).
        public var unreadable: [Unreadable] = []

        public var texts: [String] { live.map(\.text) }
    }

    // MARK: - The record

    /// The body of a `claim` record.
    ///
    /// `text` is the writer's own text, stripped but not collapsed: a memory
    /// entry a person typed across two lines stays across two lines when it
    /// is projected back. Only the *id* is computed from the collapsed form,
    /// which is what makes reformatting free and rewording deliberate.
    ///
    /// With `sealedWith` the text goes in as `enc`/`text_enc` under that key
    /// — the `moe:memory` key, §13.4 — and never as `text`. Without it the
    /// text is written in the clear, which is what claims looked like before
    /// the memory key existed and is still what a ledger on one machine may
    /// hold; such a record is `carriesPlaintext` and never leaves the
    /// machine (§13.3).
    public static func body(op: String, id: String, target: String, key: String?,
                            source: String, text: String?,
                            sealedWith memoryKey: SymmetricKey? = nil) throws -> JSONValue {
        var fields: [String: JSONValue?] = [
            "op": .string(op),
            "claim": .string(id),
            "target": .string(target),
            "key": key.map { JSONValue.string($0) },
            "source": .string(source),
        ]
        if let text {
            if let memoryKey {
                fields["enc"] = .string(ThreadCrypto.scheme)
                fields["text_enc"] = .string(try ThreadCrypto.seal(text, with: memoryKey))
            } else {
                fields["text"] = .string(text)
            }
        }
        return .of(fields)
    }

    /// A claim read out of a record, or nil for a record that is not one this
    /// build understands. Never throws — an unreadable claim is one fact
    /// missing from a digest, not a memory that fails to load.
    struct Parsed {
        let op: String
        let id: String
        let target: String
        let key: String
        let source: String
        /// The words, for an assert: opened from `text_enc` with the memory
        /// key, or taken from `text` when the record is in the clear. Nil
        /// for a retract, which has none, and for an assert that is sealed
        /// and will not open with what this reader holds — *present but
        /// unreadable* (§13.4), which `resolve` counts and never shows.
        let text: String?
        var readable: Bool { text != nil }
    }

    static func parse(_ record: LedgerRecord, key memoryKey: SymmetricKey? = nil) -> Parsed? {
        guard record.kind == LedgerRecord.Kind.claim,
              let op = record.body["op"]?.stringValue,
              op == Op.assert || op == Op.retract,
              let id = record.body["claim"]?.stringValue, !id.isEmpty,
              let target = record.body["target"]?.stringValue, !target.isEmpty
        else { return nil }
        var text: String?
        if op == Op.assert {
            if let sealed = record.body["text_enc"]?.stringValue {
                // An empty `text_enc` is malformed, not sealed: no key
                // will ever open zero bytes, so it can never become
                // readable, and counting it as "present but unreadable" for
                // ever would be a claim that exists for nobody. Python's
                // reader (`claimstore`) treats it as absent — not a claim —
                // and this must agree with it record for record, or the
                // two halves of one memory count different things. (A
                // `document` is the opposite by design: its empty
                // `text_enc` is the removal marker, §13.5.)
                guard !sealed.isEmpty else { return nil }
                // Sealed. Whether it opens is a property of this reader,
                // not of the record: a `text` that stays nil here is "not
                // yet", never "not a claim".
                if let opened = ThreadCrypto.open(sealed, with: memoryKey) {
                    // An assert of nothing, as in the clear.
                    guard !opened.isEmpty else { return nil }
                    text = opened
                }
            } else {
                guard let plain = record.body["text"]?.stringValue, !plain.isEmpty else { return nil }
                text = plain
            }
        }
        return Parsed(op: op, id: id, target: target,
                      key: record.body["key"]?.stringValue ?? id,
                      source: record.body["source"]?.stringValue ?? "unknown",
                      text: text)
    }
}

/// Writes `claim` records, and reads them back under §3.1.
///
/// A thin thing on purpose: the ledger already does durability, ordering and
/// causality, and every rule in here is about *memory* rather than about
/// records.
public struct ClaimLedger {

    public let ledger: Ledger
    /// The `moe:memory` key (LEDGER-WIRE §13.2). With it, every assert this writes is
    /// sealed and every sealed assert it reads is opened; without it, writes
    /// are in the clear — local-only, §13.3 — and sealed claims are counted
    /// as `unreadable` rather than shown. Optional because a reader on a
    /// device the courier has not yet reached is a real state, not an error,
    /// and because the conformance vectors are in the clear by design.
    public let key: SymmetricKey?
    /// Whether a write says what it had already seen. The device's own `prev`
    /// chain covers its own history for free; this adds the other devices'
    /// heads, which is what makes "I knew about your retraction when I wrote
    /// this" expressible at all — and §3.1's tombstone amendment turns
    /// entirely on it.
    public var namesFrontier: Bool

    public init(ledger: Ledger, key: SymmetricKey? = nil, namesFrontier: Bool = true) {
        self.ledger = ledger
        self.key = key
        self.namesFrontier = namesFrontier
    }

    /// The last record of every device other than this one. `prev` already
    /// carries our own, and naming it twice would only make records longer.
    public func frontier() -> [String] {
        var last: [String: LedgerRecord] = [:]
        for record in ledger.all() where record.device != ledger.device {
            last[record.device] = record
        }
        return last.values.map(\.id).sorted()
    }

    private func after(_ explicit: [String]?) -> [String] {
        if let explicit { return explicit }
        return namesFrontier ? frontier() : []
    }

    /// Record `text` as true for `target`.
    ///
    /// Returns nil, appending nothing, when the claim is already live and
    /// says the same thing: the log records changes of belief, not
    /// repetitions of one. Note that "already live" is this device's reading
    /// — a second device asserting the same fact does append a record, and
    /// the two converge because the *claim* id is the same even though the
    /// two records are not.
    @discardableResult
    public func assert(_ text: String, target: String = "memory", key: String? = nil,
                       source: String, after explicit: [String]? = nil,
                       at: Date? = nil) throws -> LedgerRecord? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let id = Claim.id(target: target, text: text)
        let projection = resolve(target: target)
        if let standing = projection.live.first(where: { $0.id == id }),
           standing.text == text, standing.key == (key ?? standing.key) {
            return nil
        }
        return try ledger.append(
            kind: LedgerRecord.Kind.claim,
            body: try Claim.body(op: Claim.Op.assert, id: id, target: target, key: key,
                                 source: source, text: text, sealedWith: self.key),
            after: after(explicit), at: at)
    }

    /// Retract by content. Nil when nothing matches, so a retraction is never
    /// a record that retracts nothing.
    @discardableResult
    public func retract(_ text: String, target: String = "memory",
                        source: String, after explicit: [String]? = nil,
                        at: Date? = nil) throws -> LedgerRecord? {
        try retract(id: Claim.id(target: target, text: text), target: target,
                    source: source, after: explicit, at: at)
    }

    /// Nil, too, for a claim this reader cannot open: an unreadable claim is
    /// never retracted on the person's behalf (LEDGER-WIRE §13.4). It is in none of the
    /// three lists below, so nothing here has to say so twice.
    @discardableResult
    public func retract(id: String, target: String = "memory",
                        source: String, after explicit: [String]? = nil,
                        at: Date? = nil) throws -> LedgerRecord? {
        let projection = resolve(target: target)
        guard let standing = projection.live.first(where: { $0.id == id })
                ?? projection.superseded.first(where: { $0.id == id })
                // A claim awaiting an answer can be retracted too — that is
                // what "no, forget it" is, and it must land as a record
                // rather than as the question quietly going away.
                ?? projection.pendingRevivals.first(where: { $0.id == id })?.claim
        else { return nil }
        return try ledger.append(
            kind: LedgerRecord.Kind.claim,
            body: try Claim.body(op: Claim.Op.retract, id: id, target: target,
                                 key: standing.key, source: source, text: nil),
            after: after(explicit), at: at)
    }

    /// "Yes, remember that again."
    ///
    /// The other half of `Claim.PendingRevival`, and the only thing in this
    /// file that turns a question into an entry. It is an ordinary assert with
    /// a `user` source, so it revives by the ordinary rule and nothing here
    /// needs a special case — the point is that a caller has to *say* the
    /// person answered, and can only honestly say it after asking.
    @discardableResult
    public func confirmRevival(_ pending: Claim.PendingRevival,
                               surface: String = "",
                               after explicit: [String]? = nil,
                               at: Date? = nil) throws -> LedgerRecord? {
        let source = surface.isEmpty ? Claim.userSource : Claim.userSourcePrefix + surface
        return try ledger.append(
            kind: LedgerRecord.Kind.claim,
            body: try Claim.body(op: Claim.Op.assert, id: pending.id,
                                 target: pending.claim.target, key: pending.claim.key,
                                 source: source, text: pending.text, sealedWith: key),
            after: after(explicit) + [pending.claim.recordID], at: at)
    }

    // MARK: - §3.1, the claim half

    /// Every claim record for `target`, in ledger order.
    public func records(target: String) -> [LedgerRecord] {
        ledger.all().filter { record in
            Claim.parse(record, key: key).map { $0.target == target } ?? false
        }
    }

    /// Every target the ledger holds a claim for, in ledger order.
    public func targets() -> [String] {
        var seen: [String] = []
        var known = Set<String>()
        for record in ledger.all() {
            guard let claim = Claim.parse(record, key: key),
                  known.insert(claim.target).inserted else { continue }
            seen.append(claim.target)
        }
        return seen
    }

    /// §3.1's claim rules, applied.
    ///
    /// In the order the section states them:
    ///
    /// 1. **Same record, twice** — the ledger's own content addressing;
    ///    nothing here has to do anything about it.
    /// 2. **Causally ordered records** — `Ledger.ordered` has already placed
    ///    them, and `Ledger.causallyAfter` is what the rules below ask.
    /// 3. **Retraction, with the causal amendment** — a retraction suppresses
    ///    every assert of the same claim that is causally before it or
    ///    concurrent with it; an assert causally *after* it revives the claim
    ///    only when its source is the person. A crawl re-deriving a fact
    ///    somebody deleted must not bring it back, and the person saying it
    ///    again must.
    /// 4. **Same source, same topic key** — last write wins, and both stay in
    ///    the ledger. The loser is reported in `superseded`.
    /// 5. **Different sources, same topic key** — both readings stay live and
    ///    a `Disagreement` is raised. Nothing is silently dropped for want of
    ///    a model.
    ///
    /// Two things about this are decisions rather than transcriptions of the
    /// section, and both are written up in `docs/ONE-AGENT.md` §14.2 rather
    /// than buried here: "last" in rule 4 is *last in ledger order*, and
    /// rules 4 and 5 are applied to every pair of live readings of a topic
    /// rather than only to the concurrent ones.
    ///
    /// **Sealed claims this reader cannot open** (LEDGER-WIRE §13.4) take part in rule 3
    /// — the id is in the clear, so a retraction still finds them — and in
    /// nothing after it. One that would otherwise stand is reported in
    /// `unreadable`: counted, never projected, never asked about (there are
    /// no words to ask with), and rules 4 and 5 are not applied to it,
    /// because a slot cannot be superseded or disputed by a reading nobody
    /// can read. Where the same claim has both a sealed copy this reader
    /// cannot open and a copy it can, the words are the same words by
    /// construction — one id, one normalised sentence — so the claim is
    /// live under the readable copy's text.
    public func resolve(target: String) -> Claim.Projection {
        let ordered = ledger.all()
        var position: [String: Int] = [:]
        for (index, record) in ordered.enumerated() { position[record.id] = index }

        var asserts: [String: [(LedgerRecord, Claim.Parsed)]] = [:]
        var retracts: [String: [LedgerRecord]] = [:]
        var idOrder: [String] = []
        for record in ordered {
            guard let claim = Claim.parse(record, key: key), claim.target == target else { continue }
            if asserts[claim.id] == nil && retracts[claim.id] == nil { idOrder.append(claim.id) }
            if claim.op == Claim.Op.assert {
                asserts[claim.id, default: []].append((record, claim))
            } else {
                retracts[claim.id, default: []].append(record)
            }
        }

        // The causal-after set of each retraction, computed once per
        // retraction rather than once per pair.
        var afterRetraction: [String: Set<String>] = [:]
        for (_, records) in retracts {
            for record in records where afterRetraction[record.id] == nil {
                afterRetraction[record.id] = Ledger.causallyAfter(record, in: ordered)
            }
        }

        var standing: [Claim.Live] = []
        var pending: [Claim.PendingRevival] = []
        var unreadable: [Claim.Unreadable] = []
        for id in idOrder {
            guard let entries = asserts[id] else { continue }
            let tombstones = retracts[id] ?? []
            var survivors: [(LedgerRecord, Claim.Parsed)] = []
            for entry in entries {
                // The tombstone this assert came after, if it came after them
                // all. Nil means at least one retraction it is causally before
                // or concurrent with, which suppresses it outright: whoever
                // wrote it had not heard, and there is nothing to ask them.
                var knewAbout: String?
                var suppressed = false
                for tombstone in tombstones {
                    guard afterRetraction[tombstone.id]?.contains(entry.0.id) == true else {
                        suppressed = true
                        break
                    }
                    knewAbout = tombstone.id
                }
                if suppressed { continue }
                if let knewAbout, !Claim.revives(source: entry.1.source) {
                    // Causally after every retraction, but not the person. It
                    // does not revive — and it is not silently discarded
                    // either. It becomes a question (§14.3) — or, with no
                    // words to ask with, an unreadable claim (§13.4).
                    guard let text = entry.1.text else {
                        unreadable.append(Claim.Unreadable(
                            id: id, target: target, key: entry.1.key,
                            source: entry.1.source, recordID: entry.0.id))
                        continue
                    }
                    pending.append(Claim.PendingRevival(
                        claim: Claim.Live(id: id, target: target, key: entry.1.key,
                                          source: entry.1.source, text: text,
                                          recordID: entry.0.id),
                        retractedBy: knewAbout))
                    continue
                }
                survivors.append(entry)
            }
            // The newest surviving reading of this exact sentence. Several
            // devices asserting one fact is convergence, not conflict — they
            // all carry the same id and the same words.
            guard let winner = survivors.max(by: {
                position[$0.0.id, default: 0] < position[$1.0.id, default: 0]
            }) else { continue }
            // One id is one sentence, so any readable survivor's words are
            // the winner's words. None readable: present, counted, unshown.
            guard let text = winner.1.text
                    ?? survivors.compactMap(\.1.text).first else {
                unreadable.append(Claim.Unreadable(
                    id: id, target: target, key: winner.1.key,
                    source: winner.1.source, recordID: winner.0.id))
                continue
            }
            standing.append(Claim.Live(id: id, target: target, key: winner.1.key,
                                       source: winner.1.source, text: text,
                                       recordID: winner.0.id))
        }
        standing.sort { position[$0.recordID, default: 0] < position[$1.recordID, default: 0] }

        // Topic keys. A key with one reading is the ordinary case and costs
        // nothing; the rules only bite where two readings meet.
        var order: [String] = []
        var byKey: [String: [Claim.Live]] = [:]
        for claim in standing {
            if byKey[claim.key] == nil { order.append(claim.key) }
            byKey[claim.key, default: []].append(claim)
        }

        var live: [Claim.Live] = []
        var superseded: [Claim.Live] = []
        var disagreements: [Claim.Disagreement] = []
        for key in order {
            let readings = byKey[key] ?? []
            guard readings.count > 1 else { live += readings; continue }

            // Rule 4, per source: one source with two readings of one topic
            // is a source that changed its mind, and the newer reading is the
            // better one.
            var newestBySource: [String: Claim.Live] = [:]
            var sourceOrder: [String] = []
            for reading in readings {
                if let previous = newestBySource[reading.source] {
                    superseded.append(previous)
                } else {
                    sourceOrder.append(reading.source)
                }
                newestBySource[reading.source] = reading
            }
            let kept = sourceOrder.compactMap { newestBySource[$0] }
            live += kept
            // Rule 5: what is left is one reading per source, and more than
            // one source left means they disagree.
            if kept.count > 1 {
                disagreements.append(Claim.Disagreement(target: target, key: key, readings: kept))
            }
        }
        live.sort { position[$0.recordID, default: 0] < position[$1.recordID, default: 0] }
        superseded.sort { position[$0.recordID, default: 0] < position[$1.recordID, default: 0] }
        // Newest question first: one claim re-stated three times is one
        // question, about the most recent time somebody said it.
        var newestPending: [String: Claim.PendingRevival] = [:]
        for item in pending {
            let standing = newestPending[item.id]
            if standing == nil || position[standing!.claim.recordID, default: 0]
                < position[item.claim.recordID, default: 0] {
                newestPending[item.id] = item
            }
        }
        // A claim that is live again is not a question. The person may have
        // answered yes, or said it themselves; either way there is nothing
        // left to ask, and an outstanding question about a fact Moe currently
        // remembers would be worse than no question at all.
        let liveIDs = Set(live.map(\.id))
        let questions = newestPending.values
            .filter { !liveIDs.contains($0.id) }
            .sorted {
                position[$0.claim.recordID, default: 0] < position[$1.claim.recordID, default: 0]
            }
        // Oldest first, like everything else here; one entry per claim, so
        // "counted" means counted once however many devices asserted it —
        // and not at all for a claim that is live under a readable copy.
        var seenUnreadable = Set<String>()
        let counted = unreadable
            .sorted { position[$0.recordID, default: 0] < position[$1.recordID, default: 0] }
            .filter { !liveIDs.contains($0.id) && seenUnreadable.insert($0.id).inserted }
        return Claim.Projection(live: live, disagreements: disagreements,
                                superseded: superseded, pendingRevivals: questions,
                                unreadable: counted)
    }
}

// MARK: - Documents (LEDGER-WIRE §13.5)

/// Whole files, as records.
///
/// The persona (`SOUL.md`, `~/.moe/CLAUDE.md`), the learned profile and its
/// two sidecars, the list of skills the person switched off: files that one
/// side owns and the other must hold a current copy of. They are not facts
/// and get none of the claim rules — **the latest record in ledger order
/// wins, and there is no merge.** A crawl rewrites a profile file wholesale;
/// that is a document, not a set of assertions (CLOUD-PLAN §11.1).
///
/// The body is `{name, bytes, enc, text_enc}`, sealed with the `moe:memory`
/// key (§13.2) exactly as a claim's text is. **Nothing about the words is in
/// the clear** — not even a hash of them. The first cut carried `sha256` of
/// the plaintext so a reader could compare a file without opening a record;
/// it was dropped because a hash of a small dictionary is the dictionary:
/// `hermes/skills-disabled` has a few hundred possible values, and the hash
/// of `SOUL.md` says "still the unchanged default" to anybody holding the
/// edge's rows. GCM already authenticates the ciphertext, so a reader that
/// wants the hash opens the record and hashes what came out (`Document.sha256`).
/// A `document` never carries a `thread`.
public enum DocumentRecord {

    /// The most a document may be (§13.5). The profile files are a few KB; a
    /// larger one is the caller's to skip and log, and `body` refuses it.
    public static let maxBytes = 256 * 1024

    // MARK: - Documents sealed under `moe:connections` (§15, §15.1)

    /// `connection/<name>`, and the one document that is one of these in
    /// every respect but its name.
    public static let connectionPrefix = "connection/"
    public static let identityDocument = "composio-identity"
    /// Moe's Telegram application keys (`api_id`/`api_hash`), Mac → machine,
    /// so the machine can sign in as a second device of the person's own
    /// Telegram (slice E3). Never the session file — a session live in two
    /// places is AUTH_KEY_DUPLICATED and both are logged out. Applied on
    /// the machine by `moeledger.telegramapp`.
    public static let telegramAppDocument = "telegram-app"

    /// Whether `name` is sealed under `moe:connections` rather than
    /// `moe:memory` — the documents whose removal must carry a key.
    ///
    /// One list, consulted by `body`'s refusal and by `removalBody`, exactly
    /// as `moeledger.connections.sealed_under_connections_key` is on the
    /// machine. Two lists is how `composio-identity` was left off the first
    /// version of the Python refusal.
    public static func sealedUnderConnectionsKey(_ name: String) -> Bool {
        name.hasPrefix(connectionPrefix) || name == identityDocument || name == telegramAppDocument
    }

    /// The version of the sealed tombstone's plaintext (LEDGER-WIRE §15.1).
    /// Inside the seal, never beside it: a version an attacker can edit
    /// without the key is not a version, it is a downgrade switch.
    public static let removalVersion = 1

    /// The plaintext a `connection/*` removal is sealed over — canonical, so
    /// two writers produce the same bytes and so the same `sha256`.
    ///
    /// **It names the document.** `name` travels in the body's cleartext, so
    /// without the binding the seal would prove only that the key exists
    /// somewhere: a device with no key could lift the blob off a legitimate
    /// removal of one connection and revoke every other with it.
    ///
    /// Written by hand rather than through `JSONEncoder` because the bytes
    /// are a wire format shared with Python's
    /// `connections.removal_text` — keys sorted, no spaces — and an encoder's
    /// idea of ordering is not part of that contract.
    public static func removalText(name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"moe:removed\":true,\"name\":\"\(escaped)\",\"v\":\(removalVersion)}"
    }

    /// Whether `text` — the *opened* plaintext of a `bytes: 0` document — is
    /// a removal authorised for this exact document.
    ///
    /// Beside the constructor deliberately. §18.18's critical was two
    /// predicates about one field drifting apart; a verifier that could
    /// disagree with what the writer seals would be that bug with a new
    /// field. Unknown extra keys are tolerated, so a newer writer can add one
    /// without every older reader refusing its revocations.
    public static func isRemovalText(name: String, _ text: String?) -> Bool {
        guard let text,
              let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any],
              let removed = object["moe:removed"] as? Bool, removed,
              let named = object["name"] as? String
        else { return false }
        return named == name
    }

    /// The §15.1 body for revoking a document sealed under
    /// `moe:connections`: `bytes: 0` and a `text_enc` that **required the
    /// key to write**.
    ///
    /// `bytes: 0` is untouched on purpose — it is what every reader in both
    /// languages keys on to mean *removed*, so an older one still
    /// de-configures on one of these — and the body keeps exactly
    /// ``bodyKeys``, because the authorisation lives inside the seal.
    ///
    /// This is the only way to write a removal of one of these names:
    /// ``body(name:text:key:)`` refuses `text: nil` for them. Before that
    /// pair existed, `DocumentRecord.append(name:text:nil…)` on the Mac —
    /// *the side that owns revocation* — produced the unsealed shape the
    /// machine now ignores, which is a revocation that silently does nothing.
    ///
    /// **Every call seals afresh, and the machine's anti-replay memory stands
    /// on that** (§15.3). The applier refuses a sealed body **it has itself
    /// applied**, so a revocation the machine carried out cannot be replayed
    /// at it after a re-grant — the memory is of what that machine did, not
    /// of what the ledger holds, and §15.3 states the three limits that
    /// follow from it. A *second, genuine* revocation of the same connection
    /// lands only because it is a second seal. The
    /// plaintext is deliberately identical for both (it names the document
    /// and nothing else); the freshness is the GCM nonce inside the seal. A
    /// writer that made this deterministic — a fixed nonce, a cached body,
    /// re-publishing bytes rather than re-sealing them — would turn the
    /// machine's defence into a silent refusal of a real revocation, which is
    /// the one outcome §15.1 and §15.3 both refuse. `RemovalReplayTests`
    /// is the falsifier.
    public static func removalBody(name: String, key: SymmetricKey) throws -> JSONValue {
        guard !name.isEmpty else { throw DocumentError.badName }
        return .of([
            "name": .string(name),
            "bytes": .int(0),
            "enc": .string(ThreadCrypto.scheme),
            "text_enc": .string(try ThreadCrypto.seal(removalText(name: name), with: key)),
        ])
    }

    /// Write the removal of `name` — the §15.1 sealed tombstone — to `ledger`.
    @discardableResult
    public static func appendRemoval(name: String, to ledger: Ledger, key: SymmetricKey,
                                     after: [String] = [],
                                     at: Date? = nil) throws -> LedgerRecord {
        try ledger.append(kind: LedgerRecord.Kind.document,
                          body: try removalBody(name: name, key: key), after: after, at: at)
    }

    /// The body's key set, exactly. Anything more is something leaking.
    public static let bodyKeys: Set<String> = ["name", "bytes", "enc", "text_enc"]

    /// A document as a reader sees it.
    public struct Document: Equatable, Sendable {
        public let name: String
        public let bytes: Int
        /// The words, opened. Nil when this reader holds no key that opens
        /// them (present but unreadable, as §13.4 says of a claim) and nil
        /// for a removal, which has none; `removed` tells the two apart.
        public let text: String?
        public let recordID: String
        /// `text_enc` verbatim — nil for §13.5's unsealed removal, which is
        /// the empty string and therefore a constant every device can write.
        ///
        /// A document has **two** identities and a reader needs both
        /// (LEDGER-WIRE §15.3). ``sha256`` is over the plaintext and says
        /// *which credential this is*, so two seals of one body are one
        /// credential — that is what stops a re-publication of the document
        /// in force being read as a new grant and rewriting a token the
        /// machine has since refreshed (§18.12). This is over the
        /// **ciphertext** and says *which act of sealing this is*: it is a
        /// different value for every write, because ``ThreadCrypto.seal``
        /// draws a fresh 12-byte GCM nonce and puts it inside the sealed
        /// bytes. A device with no key can copy a sealed body off the ledger
        /// but cannot make one, so a seal a reader has already acted on can
        /// only have come back by being copied — which is how the machine's
        /// applier closes replay, in `moeledger.connections._replayed`.
        public let seal: String?

        /// `bytes: 0` means the file is gone (§13.5). `text_enc` is empty for
        /// a memory document's removal and a sealed token for one under
        /// `moe:connections` (§15.1); `bytes` decides, in both languages.
        public var removed: Bool { bytes == 0 }
        public var readable: Bool { removed || text != nil }
        /// Hex sha256 of the opened plaintext — computed here, never carried
        /// on the wire. Nil while the record is unreadable: there is nothing
        /// to hash.
        ///
        /// **`text ?? ""`, not `""` for every removal.** This used to hash the
        /// empty string whenever `bytes == 0`, which was right while every
        /// tombstone was empty and became a two-language disagreement the
        /// moment §15.1 gave one a plaintext: Python's `Document.sha256`
        /// hashes what it opened, so the two sides would have written
        /// different shas into their `documents.json` for one record, on the
        /// field this wire change just redefined. The old shape still hashes
        /// the empty string, because its `text` is nil.
        public var sha256: String? {
            if removed { return DocumentRecord.sha256(of: text ?? "") }
            return text.map(DocumentRecord.sha256(of:))
        }
    }

    /// Lowercase hex sha256 of `text`'s UTF-8 — what a reader hashes its own
    /// file with to decide whether the record it just opened is already
    /// applied (§13.5's `documents.json`).
    public static func sha256(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What identifies one **act of sealing** — LEDGER-WIRE §15.3, and the
    /// exact value `moeledger.documents.seal_fingerprint` writes into
    /// `documents.json`. Nil for a body with no seal, which is §13.5's
    /// unsealed removal: a constant, and therefore not an identity of
    /// anything.
    ///
    /// It is named rather than left as `sha256(of: seal)` because the two
    /// hashes mean opposite things and a reader that reached for the wrong
    /// one would be wrong in a way that looks right. Pinned in both
    /// languages by the same literal, the way `removalText` is.
    public static func sealFingerprint(_ seal: String?) -> String? {
        guard let seal, !seal.isEmpty else { return nil }
        return sha256(of: seal)
    }

    /// The body of a `document` record: `text` sealed under the memory key,
    /// or a removal when `text` is nil.
    ///
    /// Sealed or nothing. There is no plaintext form of a document, because
    /// nothing on one machine needs one — the file itself is the plaintext
    /// — and a record that carried the persona in the clear would be one
    /// `carriesPlaintext` refuses to push (§13.3).
    public static func body(name: String, text: String?, key: SymmetricKey) throws -> JSONValue {
        guard !name.isEmpty else { throw DocumentError.badName }
        // §15.1. A removal of a document sealed under `moe:connections` is a
        // SEALED tombstone, and this function writes the unsealed one — which
        // needs no key, and which the machine now ignores. This is the obvious
        // call, on the side that owns revocation, with the key already in
        // hand: `append(name:text:nil,…)` reads exactly like a revocation and
        // would have produced one that silently does nothing. Mirrors
        // `moeledger.documents.document_body`'s refusal, and exists for the
        // same reason it does — not to state the rule but to make the wrong
        // call impossible.
        if text == nil, sealedUnderConnectionsKey(name) {
            throw DocumentError.needsSealedRemoval(name)
        }
        let plaintext = text ?? ""
        let bytes = plaintext.utf8.count
        guard bytes <= maxBytes else { throw DocumentError.tooLarge(name, bytes) }
        return .of([
            "name": .string(name),
            "bytes": .int(bytes),
            "enc": .string(ThreadCrypto.scheme),
            // A removal is an empty `text_enc`, not a sealed empty string:
            // the reader must be able to tell "gone" without a key (§13.5).
            "text_enc": .string(bytes == 0 ? "" : try ThreadCrypto.seal(plaintext, with: key)),
        ])
    }

    /// A document read out of a record, or nil for a record that is not one
    /// this build understands. Never throws.
    ///
    /// A stored `sha256` field — what a pre-fix writer put on the wire — is
    /// ignored, not trusted: the hash a reader acts on is always of what it
    /// opened.
    public static func parse(_ record: LedgerRecord, key: SymmetricKey?) -> Document? {
        guard record.kind == LedgerRecord.Kind.document,
              let name = record.body["name"]?.stringValue, !name.isEmpty,
              let bytes = record.body["bytes"]?.intValue, bytes >= 0,
              let sealed = record.body["text_enc"]?.stringValue
        else { return nil }
        // A §15.1 sealed tombstone is `bytes: 0` with a NON-empty `text_enc`,
        // and its plaintext is the authorisation a reader checks with
        // `isRemovalText`. An empty one is §13.5's original removal and there
        // is nothing to open. `removed` still keys on `bytes` alone, so this
        // widens what a reader can see without changing what it decides.
        let text: String? = sealed.isEmpty ? nil : ThreadCrypto.open(sealed, with: key)
        return Document(name: name, bytes: bytes, text: text, recordID: record.id,
                        seal: sealed.isEmpty ? nil : sealed)
    }

    /// Write `text` as the current `name`, or its removal when `text` is nil.
    @discardableResult
    public static func append(name: String, text: String?, to ledger: Ledger,
                              key: SymmetricKey, after: [String] = [],
                              at: Date? = nil) throws -> LedgerRecord {
        try ledger.append(kind: LedgerRecord.Kind.document,
                          body: try body(name: name, text: text, key: key),
                          after: after, at: at)
    }

    /// The current state of every document the ledger holds: the last
    /// record of each name, in ledger order.
    public static func latest(in ledger: Ledger, key: SymmetricKey?) -> [String: Document] {
        var out: [String: Document] = [:]
        for record in ledger.all() {
            guard let document = parse(record, key: key) else { continue }
            out[document.name] = document
        }
        return out
    }

    /// The current state of one document, or nil when the ledger has never
    /// held it. A removed document is returned, with `removed` true: "gone"
    /// and "never existed" are different answers to a reader with a file.
    public static func latest(name: String, in ledger: Ledger, key: SymmetricKey?) -> Document? {
        latest(in: ledger, key: key)[name]
    }
}

public enum DocumentError: Error, CustomStringConvertible {
    case badName
    case tooLarge(String, Int)
    case needsSealedRemoval(String)

    public var description: String {
        switch self {
        case .badName:
            return "ledger: a document needs a name"
        case .needsSealedRemoval(let name):
            return "ledger: \(name) is revoked with a sealed tombstone (LEDGER-WIRE §15.1); "
                + "use DocumentRecord.removalBody(name:key:). An empty text_enc needs no key, "
                + "which is the hole that closes."
        case .tooLarge(let name, let bytes):
            return "ledger: document \(name) is \(bytes) bytes; the most a record carries is "
                + "\(DocumentRecord.maxBytes)"
        }
    }
}
