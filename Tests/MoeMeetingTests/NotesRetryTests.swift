import Foundation
import Testing

@testable import MoeMeeting

/// A brain that answers from a script, one reply per call, and counts.
private actor ScriptedBrain: MeetingBrain {
    private var replies: [Result<String, Error>]
    private(set) var calls = 0

    init(_ replies: [Result<String, Error>]) { self.replies = replies }

    func complete(system: String, user: String) async throws -> String {
        calls += 1
        guard !replies.isEmpty else { throw Fail("asked more times than the script allows") }
        return try replies.removeFirst().get()
    }

    var callCount: Int { calls }
}

private struct Fail: Error, LocalizedError {
    let why: String
    init(_ why: String) { self.why = why }
    var errorDescription: String? { why }
}

private let goodNotes = #"{"title":"T","summary":"S","decisions":[],"action_items":[],"todos":[]}"#

@Suite("Notes retry")
struct NotesRetryTests {

    private func request() -> NotesRequest {
        // No real waiting; the point under test is how many times it asks.
        NotesRequest(system: "s", user: "u", sleep: { _ in })
    }

    @Test("a good answer first time is asked for once")
    func onceIsEnough() async throws {
        let brain = ScriptedBrain([.success(goodNotes)])
        let (reply, attempts) = try await request().run(brain: brain)
        #expect(MeetingNotes.parse(reply) != nil)
        #expect(attempts == 1)
        #expect(await brain.callCount == 1)
    }

    /// The 16:10 meeting on 2026-09-08: the brain's claude-code session had
    /// been retired sixteen minutes earlier, so the request came back in
    /// fifteen seconds with something that was not notes — and that was the
    /// end of an hour-long meeting.
    @Test("a reply that is not notes is asked again, and the second answer is used")
    func retriesAProseReply() async throws {
        let brain = ScriptedBrain([.success("I'm sorry, I can't help with that."), .success(goodNotes)])
        let (reply, attempts) = try await request().run(brain: brain)
        #expect(MeetingNotes.parse(reply) != nil)
        #expect(attempts == 2)
        #expect(await brain.callCount == 2)
    }

    @Test("a thrown error is asked again too — a dead session is replaced on the next request")
    func retriesAnError() async throws {
        let brain = ScriptedBrain([.failure(Fail("the brain answered HTTP 500")), .success(goodNotes)])
        let (_, attempts) = try await request().run(brain: brain)
        #expect(attempts == 2)
        #expect(await brain.callCount == 2)
    }

    @Test("two failures stop there — the transcript is saved either way")
    func givesUpAfterTwo() async throws {
        let brain = ScriptedBrain([.success("nope"), .success("still nope")])
        let (reply, _) = try await request().run(brain: brain)
        #expect(MeetingNotes.parse(reply) == nil)
        #expect(reply == "still nope")
        #expect(await brain.callCount == 2)
    }

    @Test("when every attempt threw, the last error is what comes out")
    func throwsTheLastError() async throws {
        let brain = ScriptedBrain([.failure(Fail("first")), .failure(Fail("second"))])
        await #expect(throws: Error.self) { try await request().run(brain: brain) }
        #expect(await brain.callCount == 2)
    }

    @Test("the record quotes what actually came back")
    func excerptIsUseful() {
        // "the brain's reply was not notes" named nothing at all: not the
        // reply, not whether anything was retried.
        #expect(NotesRequest.excerpt("I cannot\n  do   that") == "\u{201C}I cannot do that\u{201D}")
        #expect(NotesRequest.excerpt("") == "it was empty")
        #expect(NotesRequest.excerpt("   \n ") == "it was empty")
        let long = String(repeating: "word ", count: 200)
        #expect(NotesRequest.excerpt(long).count < 180)
        #expect(NotesRequest.excerpt(long).hasSuffix("\u{2026}\u{201D}"))
    }
}
