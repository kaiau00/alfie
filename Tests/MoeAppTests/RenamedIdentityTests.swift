import Foundation
import Testing
@testable import Moe

/// docs/FIXABLE-FAILURES.md bug 8: since the rename (fcd320e9) the bundle id
/// is `com.memoe.app`, and two checks still asked for `com.moe.`.
///
/// The identifiers below are measured, not taken from the code under test:
///
///     $ /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Applications/Memoe.app/Contents/Info.plist
///     com.memoe.app
///     $ /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "/Applications/Memoe Dev.app/Contents/Info.plist"
///     com.memoe.app.dev
///
/// and the labels from `launchctl list` on the owner's Mac, 2026-09-23:
/// `com.moe.jobs`, `com.memoe.app`, `com.memoe.app.dev`,
/// `com.moe.worktree-snapshot`, `com.moe.marketing.week`.
struct RenamedIdentityTests {

    /// "Reset and ask again" (PermissionsPane), "Fix" (onboarding) and
    /// `AccessibilityWatch.fix()` all go through `resetAccessibilityAndAsk`,
    /// which returned before running `tccutil` whenever this was nil.
    @Test func theResetReachesTccutilForMemoeAndMemoeDev() {
        #expect(PushToTalk.tccResetTarget(bundleID: "com.memoe.app") == "com.memoe.app")
        #expect(PushToTalk.tccResetTarget(bundleID: "com.memoe.app.dev") == "com.memoe.app.dev")
    }

    /// The button itself, driven: it reaches `tccutil` with this app's id and
    /// asks again. Before the fix it returned before either.
    @MainActor
    @Test func resetAndAskAgainRunsTccutilAndAsks() {
        for id in ["com.memoe.app", "com.memoe.app.dev"] {
            var ran: [[String]] = []
            var asked = 0
            PushToTalk.resetAccessibilityAndAsk(bundleID: id,
                                                tccutil: { ran.append($0); return 0 },
                                                askAgain: { asked += 1 })
            #expect(ran == [["reset", "Accessibility", id]], "\(id)")
            #expect(asked == 1, "\(id)")
        }
    }

    @MainActor
    @Test func resetAndAskAgainLeavesOtherAppsAlone() {
        var ran = 0
        PushToTalk.resetAccessibilityAndAsk(bundleID: "com.apple.Safari",
                                            tccutil: { _ in ran += 1; return 0 },
                                            askAgain: {})
        #expect(ran == 0)
    }

    /// Only ever this app's own grants.
    @Test func theResetNeverTargetsAnotherApp() {
        #expect(PushToTalk.tccResetTarget(bundleID: nil) == nil)
        #expect(PushToTalk.tccResetTarget(bundleID: "com.apple.Safari") == nil)
        #expect(PushToTalk.tccResetTarget(bundleID: "com.trycua.driver") == nil)
        #expect(PushToTalk.tccResetTarget(bundleID: "com.memoe.app.evil") == nil)
    }

    /// `Launchd.loadedLabels()` filters `launchctl list` through this, and
    /// Settings › Background reads Moe Dev's job state from it.
    @Test func launchdSeesTheRenamedLabels() {
        for label in ["com.moe.jobs", "com.memoe.app", "com.memoe.app.dev.jobs",
                      "com.moe.sync", "com.moe.assistant"] {
            #expect(Launchd.isOurs(label: label), "\(label)")
        }
        for label in ["com.apple.Finder", "com.memoeapp", "application.com.memoe.app.119660615.119660621"] {
            #expect(!Launchd.isOurs(label: label), "\(label)")
        }
    }
}
