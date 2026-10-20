import Foundation
import Testing
@testable import MoeBrain

/// Which app Moe is driving, so something can say so.
///
/// Nothing published this before, which is why nothing could show it. The
/// owner watched Moe pull him back to Freeform, pressed stop twice, and had no
/// way to tell whether anything was still running: the island said the same
/// thing either way, the spoken step said "Working on your Mac" for every
/// action, and the helper process called itself "thinking" while idle at 1%
/// CPU. Three symptoms, one cause — no state signal.
///
/// The detection lives on Conductor (the app target). What is testable without
/// an app is the rule, which is the same shape SpokenStep uses on the same
/// labels — plus the AppleScript route, which drives the screen through the
/// terminal tool and was invisible to every control until it was found.
struct DrivingAppTests {

    /// Mirrors `Conductor.isBrowserTool`: Moe's own browser is a run of its
    /// own — `browser_exec` and every `browser_*`, by prefix, so a tool
    /// Hermes adds under that name tomorrow is covered.
    func browserTool(_ tool: String) -> Bool {
        tool == "browser_exec" || tool.hasPrefix("browser_")
    }

    @Test func theBrowserToolsAreARunOfTheirOwn() {
        for t in ["browser_exec", "browser_navigate", "browser_click", "browser_type", "browser_vault_fill"] {
            #expect(browserTool(t), Comment(rawValue: t))
        }
        for t in ["web_search", "web_extract", "terminal", "computer_use", "browserless"] {
            #expect(!browserTool(t), Comment(rawValue: t))
        }
    }

    /// Mirrors `Conductor.appBeingDriven`.
    func driven(tool: String, detail: String) -> String? {
        if tool == "computer_use" {
            if let r = detail.range(of: " in ", options: .backwards) {
                let app = detail[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !app.isEmpty { return app }
            }
            return "your Mac"
        }
        guard tool == "terminal" || tool == "execute_code" else { return nil }
        let lower = detail.lowercased()
        guard lower.contains("osascript") || lower.contains("open -a") else { return nil }
        guard lower.contains("activate") || lower.contains("keystroke")
                || lower.contains("key code") || lower.contains("click menu item")
                || lower.contains("open -a") else { return nil }
        if let m = detail.range(of: #"application[ ]+"([^"]+)""#, options: .regularExpression) {
            let inner = detail[m]
            if let q = inner.range(of: #""([^"]+)""#, options: .regularExpression) {
                return String(inner[q]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return "your Mac"
    }

    // MARK: computer_use

    @Test func theAppNameComesOutOfTheStepLabel() {
        #expect(driven(tool: "computer_use", detail: "click (953, 59) in Freeform") == "Freeform")
        #expect(driven(tool: "computer_use", detail: "menu Insert > Media… in Freeform") == "Freeform")
        #expect(driven(tool: "computer_use", detail: "looking in Google Chrome") == "Google Chrome")
    }

    @Test func aScreenWideActionStillCountsAsDriving() {
        // No app named, but it is still Moe on the screen.
        #expect(driven(tool: "computer_use", detail: "list windows") == "your Mac")
        #expect(driven(tool: "computer_use", detail: "looking at the screen") == "your Mac")
    }

    // MARK: the AppleScript route — screen driving through the terminal tool

    @Test func anAppleScriptActivateCounts() {
        // This is what kept pulling him back to Freeform, and no control saw
        // it because it is not the computer_use tool.
        #expect(driven(tool: "terminal",
                       detail: "osascript -e 'tell application \"Freeform\" to activate'")
                == "Freeform")
    }

    @Test func systemEventsTypingAndClickingCount() {
        for cmd in ["osascript -e 'tell application \"System Events\" to keystroke \"x\"'",
                    "osascript -e 'tell process \"Freeform\" to key code 123'",
                    "osascript -e 'tell process \"Notes\" to click menu item \"New\"'"] {
            #expect(driven(tool: "terminal", detail: cmd) != nil, "\(cmd)")
        }
    }

    @Test func openDashAcounts() {
        #expect(driven(tool: "terminal", detail: "open -a Freeform") == "your Mac")
    }

    // MARK: what is NOT driving

    @Test func anOrdinaryCommandIsNotDriving() {
        #expect(driven(tool: "terminal", detail: "ls -la /tmp") == nil)
        #expect(driven(tool: "terminal", detail: "git status") == nil)
    }

    @Test func anOsascriptThatDoesNotTouchTheScreenIsNotDriving() {
        // Reading the calendar is not driving anything.
        #expect(driven(tool: "terminal",
                       detail: "osascript -e 'tell application \"Calendar\" to get name of calendars'")
                == nil)
    }

    @Test func otherToolsAreNeverDriving() {
        for t in ["web_search", "gmail_pull", "memory", "read_file"] {
            #expect(driven(tool: t, detail: "anything at all in Freeform") == nil, "\(t)")
        }
    }
}
