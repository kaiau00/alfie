import Foundation
import Testing
@testable import MoeBrain

/// One turn from the live log, kept because a peer session and I disagreed
/// about it and the disagreement is worth pinning down in a test.
///
/// It appeared in `~/.moe/logs/moe.log` with no `ack:` line beside it, and
/// the first explanation offered was that `InstantAck` had returned nil from
/// its own intent or social rules. It does not: it returns "Yeah, setting
/// that up." The turn went unacknowledged because the build running at the
/// time did not contain `InstantAck` at all — the binary had none of its
/// phrases in it, and the acks in the log an hour earlier came from a
/// different build.
///
/// So this exists to stop that being re-diagnosed from the log alone. The
/// separate question — *should* a forty-second rambling note be acknowledged
/// — is answered yes here, and deliberately: the person asked for two things
/// to be done ("add this to my notes", "find out why"), which is work, and
/// going quiet on a long request is exactly the silence the ack exists to
/// fill. Length is not a reason to stay quiet; having nothing honest to say
/// is, and there is something honest to say here.
struct AckRegressionTests {

    /// Verbatim from the log at 2026-09-03T16:00:08Z.
    static let liveTurn = """
    Add to my notes. I was testing Mo. I told it to open my calendar, check \
    the logs. It was September 3rd at around 11:57 a.m. And it opened my \
    calendar and then pressed the link. And then my Chrome opened correctly \
    but then it didn't know the link opened and it kept trying to like open \
    the link like open it again and didn't know and then I just kept opening \
    my calendar and opening the link and it it it kinda got lost. Find out \
    why I got lost and I didn't understand what was going on. Add this to my \
    notes
    """

    @Test func aLongRamblingNoteIsStillAWorkRequest() {
        let phrase = InstantAck.phrase(for: Self.liveTurn)
        #expect(phrase != nil, "a turn opening \"Add to my notes\" is a request to do something")
    }

    @Test func itIsAcknowledgedAsSomethingBeingMadeNotAsAResult() {
        for v in 0..<6 {
            guard let line = InstantAck.phrase(for: Self.liveTurn, variant: v)?.lowercased() else { continue }
            #expect(!line.contains("added") && !line.contains("done"),
                    "\(line) claims the note was written")
        }
    }

    /// Length alone must not decide it: the same opening in three words gets
    /// the same treatment as the same opening in a hundred.
    @Test func theShortFormOfTheSameRequestBehavesTheSameWay() {
        #expect(InstantAck.phrase(for: "Add this to my notes") != nil)
    }
}
