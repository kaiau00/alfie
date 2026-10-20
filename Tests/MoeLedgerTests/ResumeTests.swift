import Foundation
import Testing
import MoeChat
@testable import MoeLedger

/// Resuming a thread, which is the bug this slice exists to fix.
///
/// Reopening a conversation used to put the turns on screen and then call
/// `bridge.reset()`: the person saw the thread and the brain had never heard
/// of it. The seam that can be tested without the app is what the brain is
/// handed — a session id and, when that session has not been told this thread,
/// the thread itself. These tests assert exactly that hand-off.
struct ResumeTests {

    private func fixture() -> (ConversationLedger, ConversationStore) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-resume-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let ledger = Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test")
        return (ConversationLedger(ledger: ledger, store: store), store)
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func conversation() -> ConversationStore.Conversation {
        ConversationStore.Conversation(
            startedAt: start, updatedAt: start.addingTimeInterval(60),
            turns: [
                .init(role: .you, text: "book the Tuesday flight to Lisbon", at: start),
                .init(role: .moe, text: "Booked — TP1234, 09:15.",
                      at: start.addingTimeInterval(30), tools: ["Searching flights"]),
                .init(role: .you, text: "add it to my calendar", at: start.addingTimeInterval(60)),
            ])
    }

    // MARK: The hand-off

    @Test func aResumedThreadCarriesItsHistoryToTheBrain() throws {
        let (ledger, _) = fixture()
        let convo = conversation()

        let resume = ledger.resume(thread: convo.id, brain: "hermes/claude-code/opus",
                                   knownTurns: convo.turns, startedAt: convo.startedAt,
                                   now: start.addingTimeInterval(86_400))
        let priming = try #require(resume.priming,
                                   "a thread the brain has never served must arrive with it")

        // Every turn, in order, attributed.
        #expect(priming.contains("book the Tuesday flight to Lisbon"))
        #expect(priming.contains("Booked — TP1234, 09:15."))
        #expect(priming.contains("add it to my calendar"))
        let them = try #require(priming.range(of: "Them: book the Tuesday"))
        let you = try #require(priming.range(of: "You: Booked"))
        #expect(them.lowerBound < you.lowerBound)

        // Framed as memory rather than as a document, which is the whole
        // difference between remembering the conversation and reading it.
        #expect(priming.contains("your own memory"))
        #expect(priming.contains("yesterday"))
    }

    @Test func aSessionThatHasServedTheThreadIsGivenNothingBack() throws {
        let (ledger, _) = fixture()
        let brain = "hermes/claude-code/opus"
        var convo = conversation()

        // First open: the whole thread goes over, and the brain says so.
        let first = ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                                  startedAt: convo.startedAt)
        #expect(first.priming != nil)
        first.onDelivered?()

        // Turns taken while that session is live are known to have reached it.
        convo.turns.append(.init(role: .moe, text: "Added, 09:15 Tuesday.",
                                 at: start.addingTimeInterval(90)))
        try ledger.save(convo, session: BrainSession.id(thread: convo.id, brain: brain))

        // Reopening it now must not replay the conversation into a session
        // that already has it — that is how a thread ends up doubled.
        let again = ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                                  startedAt: convo.startedAt)
        #expect(again.priming == nil)
        #expect(again.sessionID == BrainSession.id(thread: convo.id, brain: brain))
    }

    @Test func onlyWhatTheSessionHasNotSeenIsSentToIt() throws {
        let (ledger, _) = fixture()
        let brain = "hermes/claude-code/opus"
        var convo = conversation()
        ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                      startedAt: convo.startedAt).onDelivered?()

        // Something else appends to the thread — the app was closed, or on the
        // day this has a second appender, another runtime.
        convo.turns.append(.init(role: .you, text: "and a hotel near the office",
                                 at: start.addingTimeInterval(120)))
        try ledger.record(convo)

        let resume = ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                                   startedAt: convo.startedAt)
        let priming = try #require(resume.priming)
        #expect(priming.contains("and a hotel near the office"))
        #expect(!priming.contains("book the Tuesday flight to Lisbon"))
    }

    @Test func turnsTakenAfterTheSessionRotatedAreSentOnAtTheNextResume() throws {
        let (ledger, _) = fixture()
        let brain = "hermes/claude-code/opus"
        var convo = conversation()
        let session = BrainSession.id(thread: convo.id, brain: brain)
        ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                      startedAt: convo.startedAt).onDelivered?()

        // Something rotated the session under us — a turn stopped mid-thought,
        // or memory reloaded. Both wipe the Hermes session and keep the thread,
        // so what is said next lands somewhere the derived session cannot see.
        convo.turns.append(.init(role: .you, text: "make it the evening flight instead",
                                 at: start.addingTimeInterval(120)))
        try ledger.save(convo, session: "some-other-session")

        let resume = ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                                   startedAt: convo.startedAt)
        #expect(resume.sessionID == session)
        let priming = try #require(resume.priming, "a half-remembered thread is the bug, not the fix")
        #expect(priming.contains("make it the evening flight instead"))
        #expect(!priming.contains("book the Tuesday flight to Lisbon"))
    }

    @Test func primingThatWasNeverDeliveredIsSentAgain() throws {
        let (ledger, _) = fixture()
        let brain = "hermes/claude-code/opus"
        let convo = conversation()

        // Opened, and the priming dropped before it went anywhere: the person
        // clicked a second thread before the gateway was ready, or quit.
        // abandonLocked(), stop() and a failed start all empty the queue.
        let dropped = ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                                    startedAt: convo.startedAt)
        #expect(dropped.priming != nil)

        // Coming back to it must not find a thread Moe believes it told the
        // model about. Recording a send that never happened is permanent
        // amnesia on that thread, which is this slice's own bug made durable.
        let again = ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                                  startedAt: convo.startedAt)
        #expect(again.priming == dropped.priming)
    }

    @Test func aSaveWithNoReplyBehindItConfirmsNothing() throws {
        let (ledger, _) = fixture()
        let brain = "hermes/claude-code/opus"
        let convo = conversation()

        // Filing a thread on the way out proves nothing about what the brain
        // holds — the turn may still have been sitting in the queue.
        try ledger.save(convo)
        #expect(ledger.resume(thread: convo.id, brain: brain, knownTurns: convo.turns,
                              startedAt: convo.startedAt).priming != nil)
    }

    @Test func changingTheModelStartsANewSessionThatIsToldTheThread() throws {
        let (ledger, _) = fixture()
        let convo = conversation()
        let onOpus = ledger.resume(thread: convo.id, brain: "hermes/claude-code/opus",
                                   knownTurns: convo.turns, startedAt: convo.startedAt)
        let onSonnet = ledger.resume(thread: convo.id, brain: "hermes/claude-code/sonnet",
                                     knownTurns: convo.turns, startedAt: convo.startedAt)

        // A warm child keeps the model it was started with, so the session
        // must rotate — and the new one has never heard the conversation.
        #expect(onOpus.sessionID != onSonnet.sessionID)
        #expect(onSonnet.priming?.contains("book the Tuesday flight to Lisbon") == true)
    }

    @Test func aFreshThreadHasNothingToSayToTheBrain() throws {
        let (ledger, _) = fixture()
        let resume = ledger.resume(thread: "th-brand-new", brain: "hermes/test")
        #expect(resume.priming == nil)
        #expect(resume.sessionID == BrainSession.id(thread: "th-brand-new", brain: "hermes/test"))
    }

    // MARK: Session ids

    @Test func aSessionIDIsDerivedStableAndShapedLikeAUUID() {
        let a = BrainSession.id(thread: "th-1", brain: "hermes/x")
        #expect(a == BrainSession.id(thread: "th-1", brain: "hermes/x"))
        #expect(a != BrainSession.id(thread: "th-2", brain: "hermes/x"))
        #expect(a != BrainSession.id(thread: "th-1", brain: "hermes/y"))
        // Hermes's `sessions.id` is free-form text, but everything downstream
        // has always seen a lowercase UUID there and none of it should have
        // to learn that this one is a hash.
        #expect(a.count == 36)
        #expect(a.split(separator: "-").map(\.count) == [8, 4, 4, 4, 12])
        #expect(a.allSatisfy { $0.isHexDigit || $0 == "-" })
    }

    @Test func theSeenSetSurvivesARestart() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-resume-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let dir = root.appendingPathComponent("ledger")
        let convo = conversation()
        let brain = "hermes/test"

        let first = ConversationLedger(ledger: Ledger(directory: dir, device: "mac-test"), store: store)
        let resume = first.resume(thread: convo.id, brain: brain, knownTurns: convo.turns)
        #expect(resume.priming != nil)
        resume.onDelivered?()

        // Moe is quit and reopened. The brain's session id is derived, so
        // Hermes still holds the transcript; priming it again would double it.
        let second = ConversationLedger(ledger: Ledger(directory: dir, device: "mac-test"), store: store)
        #expect(second.resume(thread: convo.id, brain: brain, knownTurns: convo.turns).priming == nil)
    }

    // MARK: Framing

    @Test func aLongThreadIsCappedAndSaysSo() throws {
        // 300 turns is a real thread, and sending all of it is tens of
        // thousands of tokens in one uncached silent turn — paid again every
        // time a model change rotates the session.
        let turns = (0..<300).map { i in
            ConversationStore.StoredTurn(
                role: i % 2 == 0 ? .you : .moe,
                text: String(repeating: "a sentence of about this length. ", count: 4) + "#\(i)",
                at: start.addingTimeInterval(Double(i)))
        }
        let priming = try #require(PrimingTranscript.text(for: turns, now: start))

        #expect(priming.count < PrimingTranscript.ceiling + 1_000)
        // The end of a conversation is what the next reply continues from.
        #expect(priming.contains("#299"))
        #expect(!priming.contains("#0 "))
        // And it says what it left out rather than pretending the thread
        // started where the ceiling did.
        #expect(priming.contains("earlier turns are not repeated here"))
    }

    @Test func aThreadThatFitsIsNotTrimmedAndSaysNothingAboutIt() throws {
        let priming = try #require(PrimingTranscript.text(for: conversation().turns, now: start))
        #expect(!priming.contains("not repeated here"))
    }

    @Test func aThreadWithNothingSaidInItPrimesNothing() {
        #expect(PrimingTranscript.text(for: []) == nil)
        #expect(PrimingTranscript.text(for: [.init(role: .you, text: "   ")]) == nil)
    }

    @Test func howLongAgoIsSaidInWordsAModelCanUse() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PrimingTranscript.elapsed(from: now.addingTimeInterval(-600), to: now) == "earlier today")
        #expect(PrimingTranscript.elapsed(from: now.addingTimeInterval(-86_400), to: now) == "yesterday")
        #expect(PrimingTranscript.elapsed(from: now.addingTimeInterval(-3 * 86_400), to: now) == "3 days ago")
        #expect(PrimingTranscript.elapsed(from: now.addingTimeInterval(-8 * 86_400), to: now) == "last week")
        #expect(PrimingTranscript.elapsed(from: now.addingTimeInterval(-22 * 86_400), to: now) == "3 weeks ago")
    }
}
