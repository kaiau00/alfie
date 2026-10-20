import AppKit
import Foundation
import MoeErase

/// A build that is not the installed Moe must not be able to BE Moe.
///
/// Every guard written on 2026-09-03 asks whether an install should be
/// allowed, and all of them worked: the receipts show each later install
/// going to Moe Dev, and `/Applications/Memoe.app` was never replaced by
/// anything older. The owner's Moe still went backwards, because nobody
/// installed anything.
///
/// A build was launched straight out of `~/moe/dist/Memoe.app` — a worktree's
/// build directory, made on 2026-09-02, carrying no `MoeCommit` at all — and
/// it took the Dock, the menu bar and the hotkeys. It could, because its
/// `CFBundleIdentifier` is `com.memoe.app`: to macOS that IS Moe. Same
/// icon, same name, same everything, and for a day and a half it was the
/// only Moe running on the Mac while the correct one sat installed and
/// unopened. There is no way to see this from the outside, which is why it
/// was diagnosed as "my app went back to an old version" about thirty times.
///
/// So the identity is checked where every such build must pass, in the
/// binary itself: a bundle claiming the release identifier has to be at
/// `/Applications/Memoe.app`. Not a warning — a refusal, because a warning in
/// a log is what the last thirty of these had.
///
/// **What this cannot do.** A build made before this code existed does not
/// contain it, and will still launch and still take the Dock. That is the
/// honest limit: this stops the next one, not the ones already lying in
/// somebody's `dist/`. `scripts/install.sh` and `scripts/catch-up.sh` guard
/// the other route.
enum RunningFromHere {

    static let releaseIdentifier = MacEraseIdentity.releaseBundleID
    static let installedPath = "/Applications/Memoe.app"

    /// Quits, loudly and with an explanation, when this bundle claims to be
    /// the real Moe from somewhere that is not where the real Moe lives.
    ///
    /// Returns normally in every legitimate case, and deliberately errs that
    /// way: a `swift build` binary has no bundle identifier and is not
    /// pretending to be anything, and Moe Dev has its own identifier, which
    /// is the entire point of it.
    static func enforce() {
        guard let id = Bundle.main.bundleIdentifier, id == releaseIdentifier else { return }

        let here = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let installed = URL(fileURLWithPath: installedPath)
            .resolvingSymlinksInPath().path
        guard here != installed else { return }

        // MOE_ALLOW_UNINSTALLED exists for one case: running the real
        // bundle under a debugger or a test harness, on purpose, by
        // someone who typed it. It is written to the log either way, so a
        // session that reaches for it leaves a record — the same shape as
        // MOE_ALLOW_STALE, and for the same reason.
        if let why = ProcessInfo.processInfo.environment["MOE_ALLOW_UNINSTALLED"],
           why != "1", !why.isEmpty {
            Log.write("running uninstalled from \(here) — allowed: \(why)")
            return
        }

        let message = """
        This is a build of Moe from

            \(here)

        It is not the Moe installed on this Mac, but it carries the same \
        identifier, so macOS would give it the same Dock icon, menu bar and \
        shortcuts as the real one — and there would be no way to tell them \
        apart. That is how an old build spends a day pretending to be your Moe.

        To test a change, install Moe Dev: ./scripts/install.sh
        To update the real Moe:            ./scripts/catch-up.sh
        """
        Log.write("refusing to run: this bundle claims \(releaseIdentifier) "
                  + "but lives at \(here), not \(installed)")
        FileHandle.standardError.write(Data((message + "\n").utf8))

        // An alert as well as the log, when there is a session to show it
        // in: whoever launched this is looking at a screen, and the log is
        // exactly where the last thirty of these went unread.
        if NSApp != nil, !isHeadless {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "This is not the installed Moe"
            alert.informativeText = message
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        Log.flush()
        exit(2)
    }

    /// No window server, no alert — a CI machine or an ssh session, where a
    /// modal would hang forever with nobody to click it.
    private static var isHeadless: Bool {
        ProcessInfo.processInfo.environment["MOE_HEADLESS"] == "1"
            || NSApplication.shared.activationPolicy() == .prohibited
    }
}
