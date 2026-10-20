import Foundation
import Testing
import MoeChat
@testable import MoeLedger

/// Slice 3 puts a second kind of record inside a thread.
///
/// A `turn` and an `intent` (docs/LEDGER-WIRE.md §14) now share a thread id,
/// because an intent is queued *in a conversation* and is sealed under that
/// conversation's key. Everything that reads a thread must therefore know
/// which records are the conversation and which are the machinery behind it.
/// The projector already filters to `turn`, so this holds today — these are
/// the tests that fail the day someone widens that filter and a person's
/// transcript grows a line they never said.
struct IntentProjectionTests {

    private func fixture() -> (ConversationLedger, ConversationStore, Ledger) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-intent-projection-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let ledger = Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test")
        return (ConversationLedger(ledger: ledger, store: store), store, ledger)
    }

    private func conversation(id: String) -> ConversationStore.Conversation {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return ConversationStore.Conversation(
            id: id, startedAt: start, updatedAt: start.addingTimeInterval(30),
            turns: [
                .init(role: .you, text: "what's in my Notes about the deck?", at: start),
                .init(role: .moe, text: "Your Notes are on your Mac; I've queued it.",
                      at: start.addingTimeInterval(30)),
            ])
    }

    /// The body a machine writes (§14.2): what kind of thing is pending is in
    /// the clear, the person's words are not.
    private func intentBody(thread: String) -> JSONValue {
        .object([
            "thread": .string(thread),
            "runtime": .string("mac"),
            "connector": .string("notes"),
            "verb": .string("pull"),
            "expires": .string("2026-09-06T09:12:44.000Z"),
            "enc": .string("aes-gcm-256.v1"),
            "text_enc": .string("bm90IHJlYWxseSBzZWFsZWQsIGJ1dCBzaGFwZWQgbGlrZSBpdA=="),
        ])
    }

    @Test func anIntentInAThreadIsNotPartOfTheConversation() throws {
        let (ledger, store, raw) = fixture()
        let thread = UUID().uuidString
        try ledger.save(conversation(id: thread))
        _ = try raw.append(kind: LedgerRecord.Kind.intent, body: intentBody(thread: thread))

        _ = try ledger.reproject(threads: [thread])

        let projected = try #require(store.load(id: thread))
        #expect(projected.turns.count == 2)
        #expect(projected.turns.allSatisfy { !$0.text.contains("notes") })
    }

    /// The reverse of the same rule: a rebuild from nothing but records must
    /// not invent a conversation out of machinery. A thread whose only record
    /// is an intent is not a conversation the person ever had.
    @Test func aThreadOfNothingButIntentsProjectsNoConversation() throws {
        let (ledger, store, raw) = fixture()
        let thread = UUID().uuidString
        _ = try raw.append(kind: LedgerRecord.Kind.intent, body: intentBody(thread: thread))
        _ = try raw.append(kind: LedgerRecord.Kind.intentResult, body: .object([
            "thread": .string(thread),
            "intent": .string("0123456789abcdef0123456789abcdef"),
            "state": .string("done"),
            "enc": .string("aes-gcm-256.v1"),
            "text_enc": .string("c2VhbGVkIG91dHB1dA=="),
        ]))

        _ = try ledger.rebuild()

        #expect(store.load(id: thread) == nil)
    }

    /// §13.3 covers every kind, and §14's payload is the person's words. An
    /// intent written the wrong way must be caught by the same rule that
    /// catches an unsealed turn — this is what stops it reaching the network.
    @Test func anIntentCarryingPlaintextIsRefusedLikeAnyOtherRecord() {
        let sealed = LedgerRecord(kind: LedgerRecord.Kind.intent, at: Date(), device: "mac-test",
                                  seq: 1, prev: nil, after: [],
                                  body: intentBody(thread: "t"))
        #expect(!sealed.carriesPlaintext)

        let plain = LedgerRecord(kind: LedgerRecord.Kind.intent, at: Date(), device: "mac-test",
                                 seq: 2, prev: nil, after: [],
                                 body: .object([
                                     "thread": .string("t"),
                                     "runtime": .string("mac"),
                                     "connector": .string("notes"),
                                     "verb": .string("pull"),
                                     "text": .string("read the note about my salary"),
                                 ]))
        #expect(plain.carriesPlaintext)
    }
}
