import Foundation
import CryptoKit
import MoeChat

/// Turns records back into the threads a person sees.
///
/// This is the projection half of §1: `~/.moe/conversations/*.json` is not
/// truth, it is what the ledger says rendered into the shape the app reads.
/// Deleting the whole directory and rebuilding it must be a repair, not a
/// loss — `rebuildAll` is that repair.
public struct ConversationProjector {

    public let ledger: Ledger
    public let store: ConversationStore
    /// What can be read. A thread with no key here is a thread whose words
    /// are gone — see `ThreadKeyring`.
    public let keyring: ThreadKeyring

    public init(ledger: Ledger, store: ConversationStore, keyring: ThreadKeyring) {
        self.ledger = ledger
        self.store = store
        self.keyring = keyring
    }

    // MARK: - Records from a conversation

    /// The body of a `turn` record. Everything needed to put the turn back on
    /// screen exactly as it was, including the thread's own start time — a
    /// projection that invented a start time would not be the same thread.
    ///
    /// What the person said and what Moe did are sealed with the thread's
    /// key; everything the ledger orders by is left in the clear, because a
    /// record whose place in the chain could not be read without a key would
    /// take the whole thread's ordering down with it when that key is
    /// destroyed — and destroying a key must cost the words, nothing else.
    ///
    /// So: `text` and `tools` are sealed. `thread`, `turn_id`, `role`, `at`
    /// and `thread_started_at` are not. That is a real disclosure and worth
    /// stating: whoever holds the ledger without the key learns that a thread
    /// exists, how many turns it has, who spoke and when — but not one word.
    public static func turnBody(thread: String, startedAt: Date,
                                turn: ConversationStore.StoredTurn,
                                source: String, key: SymmetricKey?) throws -> JSONValue {
        var body: [String: JSONValue?] = [
            "thread": .string(thread),
            "thread_started_at": .string(LedgerRecord.timestamps.string(from: startedAt)),
            "turn_id": .string(turn.id),
            "role": .string(turn.role.rawValue),
            "at": .string(LedgerRecord.timestamps.string(from: turn.at)),
            "source": .string(source),
        ]
        let tools = turn.tools.flatMap { $0.isEmpty ? nil : $0 }
        // A file's name and where it lives say as much as the words do, so
        // attachments are sealed with them, as one blob like the tools.
        let attachments = try turn.attachments.flatMap { $0.isEmpty ? nil : $0 }
            .map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        if let key {
            body["enc"] = .string(ThreadCrypto.scheme)
            body["text_enc"] = .string(try ThreadCrypto.seal(turn.text, with: key))
            if let tools {
                // One blob rather than one per tool: a sealed list of five
                // things should not announce that it has five things in it.
                let encoded = try JSONSerialization.data(withJSONObject: tools)
                body["tools_enc"] = .string(
                    try ThreadCrypto.seal(String(decoding: encoded, as: UTF8.self), with: key))
            }
            if let attachments {
                body["attachments_enc"] = .string(try ThreadCrypto.seal(attachments, with: key))
            }
        } else {
            // Only for records written before there were keys, and for tests
            // that are about something else.
            body["text"] = .string(turn.text)
            body["tools"] = tools.map { .array($0.map(JSONValue.string)) }
            body["attachments"] = attachments.map(JSONValue.string)
        }
        return .of(body)
    }

    /// The turns of `conversation` that the ledger does not have yet.
    ///
    /// Identity is the turn id the app minted, not the text: a turn edited in
    /// place is the same turn, and a person saying the same thing twice is two.
    public func missingTurns(of conversation: ConversationStore.Conversation)
        -> [ConversationStore.StoredTurn] {
        let known = Set(turnRecords(thread: conversation.id).compactMap { $0.body["turn_id"]?.stringValue })
        return conversation.turns.filter { !known.contains($0.id) }
    }

    // MARK: - Projecting

    public func turnRecords(thread: String) -> [LedgerRecord] {
        records(thread: thread).filter { $0.kind == LedgerRecord.Kind.turn }
    }

    /// Everything the ledger holds about one thread, of every kind.
    public func records(thread: String) -> [LedgerRecord] {
        ledger.byThread()[thread] ?? []
    }

    /// Every thread the ledger knows about, in ledger order.
    public func threads() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for record in ledger.all() {
            guard let thread = record.body["thread"]?.stringValue, !seen.contains(thread) else { continue }
            seen.insert(thread)
            out.append(thread)
        }
        return out
    }

    /// The head of a thread as it stands — what a turn written now would name
    /// in `after`.
    ///
    /// The last record of *any* kind, not the last turn. A deletion is part
    /// of the thread's history, and a turn written after one has to say that
    /// it saw it: that is the whole difference between a person carrying on a
    /// conversation they deleted and a second device that never heard about
    /// the deletion writing into it (§3.1, and `surviving` below).
    public func head(thread: String) -> [String] {
        records(thread: thread).last.map { [$0.id] } ?? []
    }

    // MARK: - Tombstones

    /// Which records are causally after `tombstone`, by what the records
    /// themselves say and by nothing else.
    ///
    /// One forward pass from the tombstone's own position. `Ledger.ordered`
    /// places every record after the parents it holds, so a record's parents
    /// are already decided by the time it is reached, and nothing ahead of
    /// the tombstone in that order can be behind it in causality.
    ///
    /// **There is no `seq` comparison here, and there must not be.** An
    /// earlier version of this took "same device, higher `seq`" as proof that
    /// a record had seen the tombstone, on the grounds that a device has
    /// certainly seen its own previous write — following the `prev` chain
    /// across threads in one step. That holds for one writer per chain and
    /// fails in exactly the configuration this slice exists to support: two
    /// runtimes sharing a `~/.moe` share its `device.json`, keep their own
    /// idea of where the chain has got to, and both write `seq` 7. Deciding
    /// whether a deleted conversation comes back on a counter two writers
    /// fork is no better than deciding it on a wall clock, and much harder
    /// for anyone to see. Following `prev` and `after` by id costs a pass
    /// over the ledger and assumes nothing about who wrote it.
    /// Lives on `Ledger` now, because claims ask the same question of the
    /// same records (§14). Kept here as the name the tombstone rule reads by.
    static func causallyAfter(_ tombstone: LedgerRecord,
                              in ordered: [LedgerRecord]) -> Set<String> {
        Ledger.causallyAfter(tombstone, in: ordered)
    }

    /// The turns of a thread that its tombstones have not suppressed.
    ///
    /// §3.1: **a tombstone suppresses only what is causally before it or
    /// concurrent with it, and only something causally after it revives.**
    /// So a turn survives every tombstone or it does not survive at all.
    ///
    /// Slice one read this positionally — the thread was deleted if its last
    /// record in ledger order was a `thread.delete` — and that is the same
    /// answer on one machine and the wrong one on two. A second appender that
    /// never heard about the deletion writes a turn concurrent with it, and
    /// whether the deleted thread comes back then depends on whose wall clock
    /// was ahead, because `at` is what separates concurrent records. §1.5 is
    /// explicit that `at` never decides who wins. Causality is what decides,
    /// and it gives the same answer on both devices and on neither's clock.
    ///
    /// The pass is over the whole ledger rather than over the thread, because
    /// `prev` chains leave the thread — but only for a thread that has
    /// actually been deleted, which is why the guard below is not just an
    /// early return.
    func surviving(_ held: [LedgerRecord]) -> [LedgerRecord] {
        var live = held.filter { $0.kind == LedgerRecord.Kind.turn }
        let tombstones = held.filter { $0.kind == LedgerRecord.Kind.threadDelete }
        guard !tombstones.isEmpty, !live.isEmpty else { return live }
        let ordered = ledger.all()
        for tombstone in tombstones {
            let after = Self.causallyAfter(tombstone, in: ordered)
            live = live.filter { after.contains($0.id) }
            if live.isEmpty { break }
        }
        return live
    }

    /// True for a thread the person deleted and nobody has knowingly written
    /// to since. Its records stay in the ledger; there is simply nothing left
    /// to show.
    ///
    /// A tombstone has to be there. `surviving` starts from turn records, so
    /// a thread with records of some *other* kind and no turns has nothing
    /// surviving — which is not the same statement as "deleted", and the
    /// difference matters because `write` removes a deleted thread's file.
    /// Nothing but `turn` and `thread.delete` names a thread today; the day
    /// a `claim` does, this would otherwise quietly delete its projection.
    ///
    /// And never true for a reserved id (LEDGER-WIRE §13.2). Memory records carry no
    /// `thread`, so nothing files under `moe:memory` on its own; the only
    /// record that could is a `thread.delete` naming it, and that record is
    /// ignored by every reader — here, so that `reproject` and `rebuild` do
    /// not go on to forget the memory key.
    public func isDeleted(thread: String) -> Bool {
        guard !ThreadKeyring.isReserved(thread) else { return false }
        let held = records(thread: thread)
        guard held.contains(where: { $0.kind == LedgerRecord.Kind.threadDelete }) else { return false }
        return surviving(held).isEmpty
    }

    /// Rebuild one thread from records alone.
    ///
    /// Nil when the ledger has nothing for it, when the person's last act on
    /// the thread was to delete it, or when its words cannot be read because
    /// the key is gone. That last case is deletion seen from the other side,
    /// and it is an ordinary answer here: a thread nobody can read is a
    /// thread there is nothing to show, and everything that walks the threads
    /// simply steps over it.
    public func project(thread: String) -> ConversationStore.Conversation? {
        let held = records(thread: thread)
        guard !held.isEmpty else { return nil }
        // A delete suppresses what came before it and what was written
        // without knowing about it; a turn written *knowing* about it revives
        // the thread, because carrying on a conversation is the clearer
        // intent. See `surviving`.
        let live = surviving(held)
        guard !live.isEmpty else { return nil }

        let key = keyring.key(for: thread)
        var turns: [ConversationStore.StoredTurn] = []
        var index: [String: Int] = [:]
        var startedAt: Date?
        for record in live {
            guard let turn = Self.turn(from: record, key: key) else { continue }
            if startedAt == nil,
               let text = record.body["thread_started_at"]?.stringValue,
               let date = LedgerRecord.parse(timestamp: text) {
                startedAt = date
            }
            // A later record for the same turn is a correction of it.
            if let at = index[turn.id] { turns[at] = turn } else {
                index[turn.id] = turns.count
                turns.append(turn)
            }
        }
        guard !turns.isEmpty else { return nil }
        // No sort. `Ledger.ordered` has already put these in causal order and
        // used `at` for the one thing `at` is allowed to decide — separating
        // records that are genuinely concurrent. Re-applying the clock here
        // can only undo that work: a reply and its question are routinely
        // stamped the same second, and a clock that steps backwards (an NTP
        // correction, someone changing the date) would file the newest turn
        // first. The order records were written in is the order they happened.
        return ConversationStore.Conversation(
            id: thread,
            startedAt: startedAt ?? turns[0].at,
            // Display only, and deliberately not `turns.last?.at`: a backwards
            // clock step must not sink a live thread down the session list.
            updatedAt: turns.map(\.at).max() ?? turns[0].at,
            turns: turns)
    }

    /// Nil for a turn that cannot be read: a record this build does not
    /// understand, or one whose key is gone. Both are states, not errors.
    ///
    /// Two shapes are accepted. `text_enc` is sealed and needs the key;
    /// `text` is plaintext, which is what records written before the keyring
    /// existed look like, and they stay readable forever — see §12.
    private static func turn(from record: LedgerRecord,
                             key: SymmetricKey?) -> ConversationStore.StoredTurn? {
        guard let id = record.body["turn_id"]?.stringValue,
              let roleText = record.body["role"]?.stringValue,
              let atText = record.body["at"]?.stringValue,
              let at = LedgerRecord.parse(timestamp: atText)
        else { return nil }

        let text: String
        var tools: [String]?
        var attachmentsJSON: String?
        if let sealed = record.body["text_enc"]?.stringValue {
            guard let opened = ThreadCrypto.open(sealed, with: key) else { return nil }
            text = opened
            if let sealedTools = record.body["tools_enc"]?.stringValue,
               let openedTools = ThreadCrypto.open(sealedTools, with: key),
               let list = try? JSONSerialization.jsonObject(with: Data(openedTools.utf8)) as? [String] {
                tools = list
            }
            attachmentsJSON = record.body["attachments_enc"]?.stringValue
                .flatMap { ThreadCrypto.open($0, with: key) }
        } else if let plain = record.body["text"]?.stringValue {
            text = plain
            tools = record.body["tools"]?.arrayValue?.compactMap(\.stringValue)
            attachmentsJSON = record.body["attachments"]?.stringValue
        } else {
            return nil
        }
        let attachments = attachmentsJSON.flatMap {
            try? JSONDecoder().decode([ChatAttachment].self, from: Data($0.utf8))
        }

        // A role from a later version — the record layer keeps it, so the
        // projection must not be the place a person's words disappear. Shown
        // as a note, which is what an unrecognised speaker is.
        let role = ConversationStore.StoredTurn.Role(rawValue: roleText) ?? .system
        return ConversationStore.StoredTurn(id: id, role: role, text: text, at: at,
                                            tools: (tools?.isEmpty ?? true) ? nil : tools,
                                            attachments: (attachments?.isEmpty ?? true) ? nil : attachments)
    }

    /// Threads the ledger holds records for that nothing can read, and that
    /// the ledger does not say were deleted. Zero is the healthy answer, and
    /// so is zero after a deletion — a deleted thread carries its own record
    /// saying so, and is not counted here.
    public func unreadableThreads() -> [String] {
        threads().filter { thread in
            let held = records(thread: thread)
            let live = surviving(held)
            guard !live.isEmpty else { return false }
            let sealed = live.contains { $0.body["text_enc"] != nil }
            return sealed && !keyring.has(thread: thread)
        }
    }

    // MARK: - Writing the projection

    /// Write one thread's file from the ledger. The projector is the only
    /// thing that writes this directory (§1.3): a second writer is how the
    /// Hermes memory tool's drift detector gets tripped, and the same rule
    /// applies here even though a JSON file cannot complain about it.
    @discardableResult
    public func write(thread: String) throws -> ConversationStore.Conversation? {
        guard let projected = project(thread: thread) else {
            // A deletion that arrived as a *record* — the person deleted this
            // thread on their other device — has to take the file with it.
            // Locally, `ConversationLedger.delete` removes the file itself
            // and this never fires; for a tombstone from a second appender
            // nothing else would, and the person's deleted conversation would
            // sit here in the clear.
            //
            // Only for a thread the ledger says was deleted. A thread that
            // will not project because its *key* is missing must keep its
            // file: a keyring lost by accident must not be the thing that
            // deletes somebody's conversations (§12).
            if isDeleted(thread: thread) { try store.delete(id: thread) }
            return nil
        }
        try store.save(projected)
        return projected
    }

    /// Rebuild every thread the ledger knows about.
    ///
    /// Threads with no records are left exactly as they are. That is what
    /// makes this safe to run on a `~/.moe` that predates the ledger: a
    /// person's existing conversations are prior history, not garbage to be
    /// collected, and this must never be the thing that deletes them.
    @discardableResult
    public func rebuildAll() throws -> Int {
        var written = 0
        for thread in threads() where (try write(thread: thread)) != nil { written += 1 }
        return written
    }
}
