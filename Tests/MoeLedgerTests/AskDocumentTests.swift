import Foundation
import Testing
import MoeChat
@testable import MoeLedger

/// docs/AWAY-HANDOFF.md: the ask the Mac is working on, sealed for the
/// machine as the `task/inflight` document at turn start, withdrawn at the
/// end. Under `moe:memory`, so a Mac with no memory key — never enrolled,
/// nothing to cover it — publishes nothing and says so.
struct AskDocumentTests {

    private func fixture() -> (ConversationLedger, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-ask-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let ledger = Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test")
        return (ConversationLedger(ledger: ledger, store: store), root)
    }

    @Test("the name is the one the machine's document reader knows")
    func name() {
        #expect(ConversationLedger.askDocument == "task/inflight")
    }

    @Test("no memory key, nothing published — and no error")
    func noKey() throws {
        let (led, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try led.publishAsk("{\"task\":\"t\"}") == false)
        #expect(led.ledger.records(kind: LedgerRecord.Kind.document).isEmpty)
    }

    @Test("with the key: sealed on the ledger under the name, readable with the key, gone after the withdrawal")
    func sealedThenWithdrawn() throws {
        let (led, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try #require(try led.keyring.memoryKey(peerBook: nil))
        let json = "{\"task\":\"t1\",\"thread\":\"TH\",\"text\":\"find me a cheap backpack\"}"
        #expect(try led.publishAsk(json) == true)
        let records = led.ledger.records(kind: LedgerRecord.Kind.document)
        #expect(records.count == 1)
        // Nothing of the words is in the clear on the record.
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: records[0].body.anyValue), as: UTF8.self)
        #expect(!raw.contains("backpack"))
        let doc = try #require(DocumentRecord.latest(name: ConversationLedger.askDocument, in: led.ledger, key: key))
        #expect(doc.text == json && !doc.removed)
        #expect(try led.publishAsk(nil) == true)
        let after = try #require(DocumentRecord.latest(name: ConversationLedger.askDocument, in: led.ledger, key: key))
        #expect(after.removed)
    }
}
