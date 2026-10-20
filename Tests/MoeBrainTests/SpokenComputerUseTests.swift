import Foundation
import Testing
@testable import MoeBrain

/// What Moe says while it is driving your Mac.
///
/// Every screen action used to speak the same six words. Measured from a real
/// session on 2026-09-04: eight `computer_use` calls in seventy-six seconds,
/// each announced "Working on your Mac", while the owner watched and could not
/// tell a screenshot from a click, progress from a loop, or a working agent
/// from a stuck one. His words: "it just says working on your Mac a thousand
/// times. It doesn't actually say what it's doing."
///
/// Hermes now sends the action in the step label; these turn it into English.
struct SpokenComputerUseTests {

    func say(_ label: String) -> String? {
        SpokenStep.phrase(tool: "computer_use", label: label)
    }

    // MARK: The eight calls from that session

    @Test func lookingAtAnApp() {
        #expect(say("looking in Freeform") == "Looking at Freeform")
    }

    @Test func choosingAMenuItemNamesTheItemNotThePath() {
        // "Choosing Insert > Media…" is not a sentence anyone says out loud.
        #expect(say("menu Insert > Media… in Freeform") == "Choosing Media…")
        #expect(say("menu Edit > Find > Select All in Notes") == "Choosing Select All")
    }

    @Test func clickingNamesTheAppNotTheCoordinates() {
        // Coordinates read aloud are noise; which app it landed in is not.
        #expect(say("click (953, 59) in Freeform") == "Clicking in Freeform")
        #expect(say("click element 28 in Freeform") == "Clicking in Freeform")
        #expect(say("double click (10, 20) in Notes") == "Clicking in Notes")
    }

    @Test func typingDoesNotReadTheTextAloud() {
        // The text may be a path, a password field's neighbour, anything.
        let said = say("typing '/tmp/stick_person.svg.png' in Freeform")
        #expect(said == "Typing in Freeform")
        #expect(!(said!.contains("stick_person")))
    }

    @Test func aShortcutIsNotSpelledOut() {
        // "cmd shift g" is noise in a spoken sentence.
        let said = say("pressing cmd+shift+g in Freeform")
        #expect(said == "Using a shortcut in Freeform")
        #expect(!(said!.contains("cmd")))
    }

    @Test func verifyingSaysSo() {
        #expect(say("checking it worked in Freeform") == "Checking that worked")
    }

    @Test func discoveryIsPlainEnglish() {
        #expect(say("list windows") == "Seeing what's open")
        #expect(say("list apps") == "Seeing what's open")
        #expect(say("focused element") == "Checking what's in focus")
    }

    @Test func aBatchSaysItIsSeveralThings() {
        #expect(say("2 steps: invoke_menu, verify_state")
                == "Doing a few things on your Mac")
    }

    @Test func switchingAppsNamesTheApp() {
        #expect(say("switching to Freeform") == "Switching to Freeform")
    }

    // MARK: Honesty

    @Test func anActionWithNoAppNamedDoesNotInventOne() {
        #expect(say("click (10, 20)") == "Clicking")
        #expect(say("typing 'x'") == "Typing")
        #expect(say("looking at the screen") == "Looking at your screen")
    }

    @Test func anUnknownActionFallsBackRatherThanGuessing() {
        // The old default for everything is now only the remainder.
        #expect(say("zoom region 1 2 3 4") == "Working on your Mac")
    }

    @Test func theSameLabelAlwaysSaysTheSameThing() {
        // Spoken progress is compared against itself turn to turn; a phrase
        // that drifts reads as two different actions.
        #expect(say("looking in Freeform") == say("looking in Freeform"))
    }

    @Test func everyPhraseOpensWithAGerundSoStillCanPrefixIt() {
        // The contract the rest of SpokenStep relies on.
        for label in ["looking in Freeform", "menu File > New in Notes",
                      "click (1, 2) in Notes", "typing 'x' in Notes",
                      "pressing cmd+s in Notes", "checking it worked in Notes",
                      "list windows", "2 steps: capture, click",
                      "scrolling down in Notes"] {
            let said = say(label)!
            let first = said.components(separatedBy: " ").first!
            #expect(first.hasSuffix("ing") || first == "Seeing" || first == "Doing",
                    "\(label) → \(said)")
        }
    }
}
