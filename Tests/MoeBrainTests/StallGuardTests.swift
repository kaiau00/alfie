import Testing
@testable import MoeBrain

/// docs/FIXABLE-FAILURES.md bug 9. The positive case is the brain's own final
/// reply on 2026-09-23 at 21:39:09Z (stop_reason end_turn, no tool call after
/// it); the negatives are real closing lines from the same transcripts, each
/// a turn correctly handed back to the person.
struct StallGuardTests {

    static let stalled = "Good, the browser's loading Google Flights now — one sec while I set the Hanoi to Kunming search for around October 30th."

    @Test func theReplyThatStoppedTheFlightSearch() {
        #expect(StallGuard.promise(in: Self.stalled) == Self.stalled.dropLast().description)
    }

    /// The same reply as it sits at the end of a longer answer.
    @Test func onlyTheClosingSentenceIsRead() {
        let reply = "Found three options on Skyscanner.\n\nThe cheapest is VietJet at $142. " + Self.stalled
        #expect(StallGuard.promise(in: reply) != nil)
        // …and a promise earlier in the reply, followed by the result, is fine.
        let done = "One sec while I check. Right — the cheapest is VietJet at $142."
        #expect(StallGuard.promise(in: done) == nil)
    }

    @Test func anOfferThatWaitsOnThePersonIsNotAStall() {
        #expect(StallGuard.promise(in: "If you mean something else — Wi-Fi, a specific app — tell me which and I'll check.") == nil)
    }

    @Test func aQuestionIsNotAStall() {
        #expect(StallGuard.promise(in: "want me to kick off the research now?") == nil)
        #expect(StallGuard.promise(in: "Let me check one thing first — is that the 30th or the 31st?") == nil)
    }

    @Test func otherPromisesOfImminentWork() {
        for line in ["Let me pull up your calendar.",
                     "Hang on while I open Mail.",
                     "Okay — I'll now fill in the form.",
                     "Give me a minute to go through the thread.",
                     "Checking the Hanoi flights now.",
                     "**Let me look that up.**",
                     // Missed by the first version (review, 2026-09-23)
                     "I'll get started on that.",
                     "Working on it.",
                     "Starting the search.",
                     "Okay, I'm going to open the booking page now."] {
            #expect(StallGuard.promise(in: line) != nil, "\(line)")
        }
    }

    @Test func reportsAndHandBacksAreNotStalls() {
        for line in ["Done — the event is on your calendar for Friday at 3.",
                     "Let me know if you want the return leg too.",
                     "It took one second to load, so the page is fine.",
                     "Happy to dig further if that helps.",
                     "Once you've picked one, I'll book it.",
                     "Say the word and I'll send it.",
                     // False positives in the first version (review, 2026-09-23)
                     "Your flight is booked. Let me summarise: VietJet, 10:05, $142.",
                     "Let me be honest: I can't see your bank balance.",
                     "Let me put it this way — Tuesday is cheaper.",
                     "Don't let me forget to remind you about the visa.",
                     "Hang on to the confirmation email in case they ask for it.",
                     "Done. I'll now stop.",
                     "Let me explain why the fare jumped.",
                     "Looking at your calendar, you're free on Friday afternoon from two until six.",
                     ""] {
            #expect(StallGuard.promise(in: line) == nil, "\(line)")
        }
    }

    @Test func theNoteIsABackgroundNoteThatQuotesThePromise() {
        let note = StallGuard.note(for: "one sec while I set the search")
        #expect(note.hasPrefix("(Background note, not from the person"))
        #expect(note.contains("\"one sec while I set the search\""))
        #expect(note.contains("Carry on and do it now, or say plainly why you can't."))
    }
}
