import Foundation
import Testing
@testable import MoeIsland

/// Both gates, one corpus.
///
/// `Tests/vectors/machinery-notices.json` is read by this suite AND by
/// `moe-home/hermes-plugins/moe-screen/tests/test_moe_screen.py`. That is the
/// point of it: the Python and Swift rules are two copies of one thing, and
/// the first time they were written they disagreed four ways — Swift had no
/// gateway-lifecycle rule, Python did not know `❗` or loose spacing or
/// `Cron job '…'` — while each suite asserted only against its own copy and
/// both passed. Adding a string to one suite instead of to this file puts
/// that hole straight back.
struct MachineryNoticeTests {

    struct Corpus: Decodable {
        let seen: [String]      // strings a person really was shown
        let hermes: [String]    // verbatim from the Hermes source
        let shape: [String]     // the rule is the shape, not the reason
        let traces: [String]    // what Moe's own plumbing narrates about itself
        let keep: [String]      // a person's words, never machinery
    }

    static let corpus: Corpus? = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Tests/vectors/machinery-notices.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Corpus.self, from: data)
    }()

    @Test func theCorpusIsWhereBothSuitesExpectIt() {
        #expect(Self.corpus != nil,
                "Tests/vectors/machinery-notices.json is missing or malformed; the Python suite reads it too.")
    }

    /// Six sentences that reached the island, warning sign and all.
    @Test func everySentenceAPersonWasShownIsDropped() throws {
        for text in try #require(Self.corpus).seen {
            #expect(MachineryNotice.isJobFailure(text), "should be dropped: \(text)")
        }
    }

    /// Ten more read out of Hermes's own source rather than waited for.
    /// `Cron job '…' was interrupted` is the one that matters: one word from
    /// the six above, and it fires on every gateway restart.
    @Test func everyNoticeHermesCanSendIsDropped() throws {
        for text in try #require(Self.corpus).hermes {
            #expect(MachineryNotice.isJobFailure(text), "should be dropped: \(text)")
        }
    }

    /// No mark, verb, or job name is special. Adding one more kind of failure
    /// upstream must not need a change here — that is how the last four got in.
    @Test func theShapeIsTheWholeRule() throws {
        for text in try #require(Self.corpus).shape {
            #expect(MachineryNotice.isJobFailure(text), "should be dropped: \(text)")
        }
    }

    /// The 2026-09-14 family: a tool id, a plug-in directory, an iteration
    /// counter, a slash command. The owner's own Telegram thread carried these
    /// and he asked "why does it show this technical stuff?" — each had walked
    /// past a list of sentences, so the answer is four shapes rather than six
    /// more sentences. The last two entries are a tool and a plug-in that do
    /// not exist: the rule has to hold for the one nobody has written yet.
    @Test func moesOwnPlumbingNeverNarratesItself() throws {
        for text in try #require(Self.corpus).traces {
            #expect(MachineryNotice.isJobFailure(text), "should be dropped: \(text)")
        }
    }

    /// And it says WHICH shape, so a failure names the rule it broke instead
    /// of sending its reader to the patterns to work it out.
    @Test func theShapeNamesItself() {
        #expect(MachineryNotice.notMoesWords("📧 gmail_status...") == "tool name")
        #expect(MachineryNotice.notMoesWords("🧠 moe-ledger — recalled 2 memories") == "plug-in name")
        #expect(MachineryNotice.notMoesWords("Send `/busy queue` to wait.") == "slash command")
        #expect(MachineryNotice.notMoesWords("↪ Redirected current run (iteration 1/60).") == "loop counter")
        #expect(MachineryNotice.notMoesWords("🧠 brand-new-plugin — recalled 9 memories") == "memory indicator")
        #expect(MachineryNotice.notMoesWords("Your dentist is at 9.") == nil)
    }

    /// The counter shape wants its fraction BRACKETED, and that is what keeps
    /// it off a person's sentences. Hermes always brackets its own
    /// (`status_detail = " (" + parts + ")"`), and an earlier cut of the rule
    /// that took a bare `<word> N/M` refused all three of these.
    @Test func aFractionInASentenceIsNotALoopCounter() {
        #expect(MachineryNotice.notMoesWords("Your flight is 2/3 full.") == nil)
        #expect(MachineryNotice.notMoesWords("We're on page 4/10 of the contract.") == nil)
        #expect(MachineryNotice.notMoesWords("It's 9/15 today and the invoice is due 10/1.") == nil)
        #expect(MachineryNotice.notMoesWords("↪ Resumed run (step 2/9)") == "loop counter")
    }

    /// A person's words are never machinery, whatever they mention. The
    /// island exists for these.
    @Test func aMessageForAPersonIsLeftAlone() throws {
        for text in try #require(Self.corpus).keep {
            #expect(!MachineryNotice.isJobFailure(text), "should be shown: \(text)")
        }
    }

    /// 2026-09-30 10:45: a resumed chat's silent turn became a Heads-up whose
    /// whole text was "noop". A bare silence token, in any dress, is nothing.
    @Test func aBareSilenceTokenIsSilence() {
        for text in ["noop", "NOOP", " noop.\n", "`noop`", "\"noop\"", "no-op", "[SILENT]",
                     "NO_REPLY", "(no response)", "", "   \n"] {
            #expect(MachineryNotice.isSilence(text), "should be silence: \(text)")
        }
    }

    /// Only the WHOLE text. A sentence that mentions a token is a sentence.
    @Test func aSentenceMentioningATokenIsNotSilence() {
        for text in ["noop is what the log said", "Silent auction is at 7.", "No response from Dan yet.",
                     "Call Mum"] {
            #expect(!MachineryNotice.isSilence(text), "should be shown: \(text)")
        }
    }
}
