import Foundation
import Testing
@testable import Moe

/// The island shows Moe's words, never the brain's log line.
///
/// The case that wrote this file, from the owner's Mac on 2026-09-15: he
/// typed "Oh yeah, you can open it", and what appeared where Moe's reply goes
/// was `another turn is still running for session 1e495ecf-d44; try again`.
/// He typed "you do it" and got the same string again.
struct TurnErrorTests {

    @Test("the string the owner actually read never reaches the island again")
    func theIncident() {
        let raw = "another turn is still running for session 1e495ecf-d44; try again"
        let words = TurnError.personWords(raw)
        #expect(words == TurnError.busy)
        #expect(!words.contains("1e495ecf"))
        #expect(!words.contains("session"))
    }

    @Test("a session still being set up is the same thing to the person")
    func stillStarting() {
        let raw = "session 1e495ecf-d44 is still being set up by another request; try again"
        #expect(TurnError.personWords(raw) == TurnError.busy)
    }

    @Test("any message naming an internal session id is replaced, not shown")
    func identifiersNeverTravel() {
        // The guard is on the identifier, not on the sentence: a message
        // nobody has written yet is caught by the same rule.
        #expect(TurnError.personWords("registry key session 9f2b-11ac vanished") == TurnError.generic)
        #expect(TurnError.namesASession("session 1e495ecf-d44"))
        #expect(TurnError.namesASession("for session 90e485b1-7c4; try again"))
    }

    @Test("prose about sessions is prose")
    func proseIsLeftAlone() {
        #expect(!TurnError.namesASession("Your session expired — sign in again."))
        #expect(TurnError.personWords("Your session expired — sign in again.")
                == "Your session expired — sign in again.")
    }

    @Test("the work limit keeps its own sentence")
    func workLimitStillWins() {
        let words = TurnError.personWords("claude turn exceeded 1802s")
        #expect(words.contains("Settings › Brain"))
        #expect(words != TurnError.generic)
    }

    @Test("an ordinary failure Alfie can act on passes through unchanged")
    func humanErrorsPassThrough() {
        let raw = "OAuth access token is invalid"
        #expect(TurnError.personWords(raw) == raw)
    }
}
