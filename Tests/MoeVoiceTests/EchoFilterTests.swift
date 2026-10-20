import Foundation
import Testing
@testable import MoeVoice

struct EchoFilterTests {

    let spoken = "Your next meeting is at three with the platform team, and after that you are free until five."

    @Test func aFragmentOfWhatMoeSaidIsEcho() {
        #expect(EchoFilter.isEcho("with the platform team and after that", of: spoken))
        #expect(EchoFilter.isEcho("You're next meeting is at three", of: spoken))
    }

    @Test func aRealInterjectionIsNot() {
        #expect(!EchoFilter.isEcho("no wait, cancel that", of: spoken))
        #expect(!EchoFilter.isEcho("what about tomorrow", of: spoken))
    }

    @Test func shortInterjectionsNeverMatchByWindow() {
        // "at three" appears verbatim, but two words are not an echo.
        #expect(!EchoFilter.isEcho("at three", of: spoken))
    }

    @Test func emptyIsNotEcho() {
        #expect(!EchoFilter.isEcho("", of: spoken))
        #expect(!EchoFilter.isEcho("hello", of: ""))
    }

    @Test func similarityIsSymmetricEnough() {
        let a = EchoFilter.similarity("kitten sitting", "sitting kitten")
        #expect(a > 0.5 && a < 1.0)
        #expect(EchoFilter.similarity("same", "same") == 1.0)
    }

    @Test func aShortReplyComesBackMangledAndStillCounts() {
        // Measured on this Mac: Moe said "Sure, take your time.", the
        // microphone gave the recogniser "Sugar take me", and Moe answered
        // itself. That pair scores 0.69 — under the ordinary bar, which is
        // why a short transcript is judged against a lower one.
        #expect(!EchoFilter.isEcho("Sugar take me", of: "Sure, take your time."))
        #expect(EchoFilter.isEcho("Sugar take me", of: "Sure, take your time.", threshold: 0.6))
    }

    @Test func aRealInterjectionSurvivesTheLowerBar() {
        // The lower bar must not eat someone actually interrupting.
        #expect(!EchoFilter.isEcho("no wait, the other one", of: "Sure, take your time.", threshold: 0.6))
        #expect(!EchoFilter.isEcho("stop", of: "Sure, take your time.", threshold: 0.6))
        #expect(!EchoFilter.isEcho("what about Thursday", of: "I moved it to half two.", threshold: 0.6))
    }
}
