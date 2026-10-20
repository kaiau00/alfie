import Foundation
import Testing
@testable import MoeBrain

/// What Moe says before it knows anything.
///
/// The whole risk in an instant ack is that it is *wrong* — spoken with
/// confidence a fifth of a second after you finish talking, and about work
/// that has not started. So these tests are mostly about restraint: what must
/// never be acknowledged, and what an ack must never claim.
struct InstantAckTests {

    private func ack(_ s: String, _ v: Int = 0) -> String? {
        InstantAck.phrase(for: s, variant: v)
    }

    // MARK: - It says something when there is work

    @Test func workRequestsAreAcknowledged() {
        for turn in [
            "create a cron that runs every morning",
            "set up a reminder for Friday",
            "make me a note about the pulse call",
            "add milk to the shopping list",
            "schedule a call with Eli tomorrow",
            "write up what we decided",
            "check my calendar for today",
            "what's on my calendar",
            "look through my mail for anything from the bank",
            "find the file I was editing yesterday",
            "open Xcode",
            "delete that reminder",
            "reply to Eli",
            "rename the branch to voice-speed",
            "how many meetings do I have",
            "can you sort out the deploy",
        ] {
            #expect(ack(turn) != nil, "should acknowledge: \(turn)")
        }
    }

    @Test func theAddressIsSteppedPastToFindTheVerb() {
        // "Hey Moe" is how the turn is opened, not what is being asked.
        #expect(ack("hey Moe create a cron for the morning digest") != nil)
        #expect(ack("ok Moe check my mail") != nil)
        #expect(ack("so, uh, find that email from Eli") != nil)
    }

    // MARK: - It stays quiet when there is not

    @Test func socialTurnsGetNoAck() {
        // These get an ordinary reply, and "on it" in front of one would be
        // absurd. Every one of them is a real line from the log.
        for turn in [
            "thanks", "thanks Moe", "cool", "nice one", "ok", "okay great",
            "yeah", "yep", "no", "hi", "hey Moe", "good morning",
            "busy day", "wow", "never mind", "stop", "that's all",
            "goodbye", "alright", "sorry",
        ] {
            #expect(ack(turn) == nil, "should stay quiet: \(turn)")
        }
    }

    @Test func aTurnWithNoVerbOfItsOwnGetsNoAck() {
        // Nothing here says what is being asked for, so there is nothing
        // honest to restate.
        #expect(ack("the one from yesterday") == nil)
        #expect(ack("Eli") == nil)
        #expect(ack("mm hmm") == nil)
        #expect(ack("") == nil)
        #expect(ack("   ") == nil)
    }

    @Test func aVerbDeepInsideASentenceIsNotTheRequest() {
        // The user is quoting somebody else's instruction, not giving one.
        // Acking "deleting that" here would be an account of the wrong thing.
        #expect(ack("the mail from Eli says the branch should be deleted") == nil)
        #expect(ack("apparently nobody remembered to write it down") == nil)
    }

    // MARK: - What an ack may never claim

    @Test func noAckClaimsAnOutcome() {
        // An ack is spoken before the work starts and must stay true if the
        // work fails. Nothing may report a result.
        let done = ["done", "sent", "created", "deleted", "saved", "finished",
                    "i've", "i have", "that's set", "all set", "there you go"]
        for turn in Self.everyIntentSample {
            for v in 0..<6 {
                guard let line = ack(turn, v) else { continue }
                let lower = line.lowercased()
                for claim in done {
                    #expect(!lower.contains(claim), "\(line) — claims a result on: \(turn)")
                }
            }
        }
    }

    @Test func sendingIsNeverPromised() {
        // Moe's send gate may still stop and ask. "Sending that" spoken while
        // a dialog waits is a lie, so the draft phrasings promise only that
        // something is being got ready.
        for turn in ["send Eli an email about Friday", "text my wife I'm late",
                     "reply to that message", "forward that to the team"] {
            for v in 0..<6 {
                guard let line = ack(turn, v)?.lowercased() else { continue }
                #expect(!line.contains("sending"), "\(line) — promises delivery")
                #expect(!line.contains("sent"), "\(line) — promises delivery")
            }
        }
    }

    @Test func removalIsNeverPromisedEither() {
        for turn in ["delete that file", "cancel the 3pm", "get rid of that reminder"] {
            for v in 0..<6 {
                guard let line = ack(turn, v)?.lowercased() else { continue }
                #expect(!line.contains("deleting"), "\(line) — promises destruction")
                #expect(!line.contains("removing"), "\(line) — promises destruction")
            }
        }
    }

    // MARK: - How it sounds

    @Test func everyPhraseIsShortSpeakableAndOneSentence() {
        for turn in Self.everyIntentSample {
            for v in 0..<6 {
                guard let line = ack(turn, v) else { continue }
                #expect(line.count <= 34, "too long to be instant: \(line)")
                #expect(line.hasSuffix("."), "not a sentence: \(line)")
                #expect(line.first?.isUppercase == true, "not capitalised: \(line)")
                // Read aloud, these are noise — and the ack's whole job is to
                // sound like a person, not a status line.
                for bad in ["_", "/", "*", ":", "(", ")", "…"] {
                    #expect(!line.contains(bad), "unspeakable character in: \(line)")
                }
            }
        }
    }

    @Test func theVariantRotatesSoTwoTurnsRunningDifferSomewhere() {
        // Not every pair has to differ, but a whole rotation must not be one
        // phrase repeated — that is what made the old progress lines grating.
        let lines = Set((0..<6).compactMap { ack("create a cron", $0) })
        #expect(lines.count >= 3)
    }

    @Test func anyVariantIndexIsSafe() {
        // The caller keeps a counter that only ever goes up.
        #expect(ack("create a cron", 0) != nil)
        #expect(ack("create a cron", 999_999) != nil)
        #expect(ack("create a cron", -7) != nil)
        #expect(ack("create a cron", Int.min + 1) != nil)
    }

    @Test func caseAndPunctuationDoNotMatter() {
        // Transcripts arrive with and without capitals and full stops.
        #expect(ack("Create a cron.") != nil)
        #expect(ack("CHECK MY MAIL") != nil)
        #expect(ack("check my mail?") != nil)
    }

    /// One turn per intent, for the properties that must hold of all of them.
    private static let everyIntentSample = [
        "create a cron that runs every morning",   // create
        "rename the branch to voice-speed",        // change
        "send Eli an email about Friday",          // draft
        "delete that reminder",                    // remove
        "check my calendar for today",             // look
        "open Xcode",                              // start
        "can you sort out the deploy",             // work
    ]
}
