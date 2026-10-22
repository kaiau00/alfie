import AppKit
import Foundation
import Sparkle

/// Auto-updates, and the switch that keeps them out of the way of anyone who
/// never asked for them.
///
/// Sparkle is compiled into every build, but it is *started* only when the
/// build was made with an appcast URL and a public key — `build.sh` writes
/// `SUFeedURL` and `SUPublicEDKey` into Info.plist from `MOE_SPARKLE_FEED_URL`
/// and `MOE_SPARKLE_PUBLIC_KEY`, and omits both keys when those are empty.
/// A build from a plain checkout therefore has no feed, no updater and no
/// "Check for Updates…" item, and behaves exactly as it did before Sparkle
/// existed.
///
/// The gate is not decoration. `SPUStandardUpdaterController.startUpdater()`
/// documents that a misconfigured app "is logged and an alert is shown to the
/// user (after a few seconds) to contact the developer" — so starting the
/// updater on a build with no feed would put a support dialog in front of
/// every developer and every person running an unreleased build. Checking
/// first is the only way to get silence.
@MainActor
enum Updates {

    /// The live controller, or nil on a build with no feed. Held for the
    /// lifetime of the app: it owns the scheduled check, and the
    /// "Check for Updates…" item targets it.
    private(set) static var controller: SPUStandardUpdaterController?

    /// The updater's delegate, alive for as long as the controller is.
    private static let stagedUpdate = StagedUpdateDelegate()

    /// Starts Sparkle if this build carries an appcast URL and a public key.
    /// Returns the controller so the caller can hang a menu item off it, or
    /// nil, which means "say nothing about updates anywhere".
    @discardableResult
    static func start() -> SPUStandardUpdaterController? {
        if let controller { return controller }
        guard let feed = configuredFeedURL(), publicKey() != nil else {
            Log.write("updates: no SUFeedURL/SUPublicEDKey in this build — Sparkle stays off")
            return nil
        }
        // `startingUpdater: false` then `startUpdater()`, rather than the
        // one-line initialiser, so the order is explicit: everything that
        // could make Sparkle complain has been checked above this line.
        // `updaterDelegate` is how a downloaded update reaches the island
        // (docs/DEFAULTS.md row 47). Sparkle holds it weakly
        // (SPUStandardUpdaterController.h: "you are responsible for keeping
        // them alive"), so it is a static here, not a temporary.
        let c = SPUStandardUpdaterController(startingUpdater: false,
                                             updaterDelegate: stagedUpdate,
                                             userDriverDelegate: nil)
        c.startUpdater()
        // Silent updates (docs/DEFAULTS.md row 46). Info.plist already says
        // so (SUEnableAutomaticChecks, SUAutomaticallyUpdate), but those are
        // only defaults: a Mac that once answered Sparkle's "check
        // automatically?" question, or ran a build that asked before
        // installing, keeps that answer in its preferences, and there is no
        // switch in Settings to change it back. Setting both here makes every
        // copy behave the same. The update is downloaded quietly and put in
        // place when Moe next quits. Nothing here relaunches the app on its
        // own: once the download is staged, `StagedUpdateDelegate` hands the
        // island a "Restart to update" that only the person presses (row 47).
        c.updater.automaticallyChecksForUpdates = true
        c.updater.automaticallyDownloadsUpdates = true
        controller = c
        Log.write("updates: Sparkle started against \(feed)")
        return c
    }

    /// "Check for Updates…", or nil when this build has no feed. Sparkle
    /// enables and disables the item itself once it is targeted at
    /// `checkForUpdates(_:)` — it knows when a check is already running.
    static func menuItem() -> NSMenuItem? {
        guard let controller else { return nil }
        // …and not on a Mac that only runs Moe. Settings › About hides the
        // same button behind the same predicate, and an item that survives
        // here would make that hiding a lie — the app menu is the first
        // place a Mac user looks for "Check for Updates…", so leaving it
        // would have been the half-fix that reads as a bug.
        //
        // Sparkle itself is untouched: `start()` above has already run, the
        // scheduled check still happens, and a new release is still offered
        // to everybody. What goes is the way to ask, not the answer.
        guard BuildInfo.isMaintainerMac else { return nil }
        let item = NSMenuItem(title: "Check for Updates…",
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = controller
        return item
    }

    // MARK: - What the bundle says

    /// The feed URL, only if it is a real https URL. An http feed would let
    /// anyone on the network choose which appcast Moe reads; Sparkle's
    /// signature check would still catch a forged *download*, but a plaintext
    /// feed is not something to ship, so it is treated as unconfigured.
    private static func configuredFeedURL() -> URL? {
        guard let raw = string(for: "SUFeedURL"),
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private static func publicKey() -> String? { string(for: "SUPublicEDKey") }

    /// A bundle key that is present *and* not blank. Both halves matter: an
    /// empty string is exactly what a release built with the environment
    /// variables unset would leave behind if build.sh wrote the keys
    /// unconditionally, and Sparkle would treat that as a broken app.
    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Ready to install (docs/DEFAULTS.md row 47)

/// Tells the island when Sparkle has downloaded an update and is holding it
/// to install on quit.
///
/// Row 46 made updates silent: downloaded in the background, installed when
/// Moe quits. But Moe starts at login and rarely quits, so an update could sit
/// staged for weeks. Row 47: once it is ready, the island asks the person to
/// restart — never an automatic restart.
///
/// The path is `SPUUpdaterDelegate`'s
/// `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`
/// (Sparkle 2.9.6, SPUUpdaterDelegate.h): "Called when an update is scheduled
/// to be silently installed on quit after downloading the update
/// automatically." Returning YES takes control: Sparkle shows no UI of its
/// own for it, and "when the opportunity arrives, you can invoke
/// `immediateInstallHandler` to install the update and relaunch the
/// application"; "Sparkle will always attempt to install the update when the
/// app terminates" either way, so quitting normally still installs it.
///
/// Not the standard user driver's gentle reminders
/// (`supportsGentleScheduledUpdateReminders`,
/// `standardUserDriverShouldHandleShowingScheduledUpdate`): those are for an
/// update Sparkle is about to *offer* in its own window, and they carry no
/// install block — with automatic downloads on, a staged update never reaches
/// them.
@MainActor
final class StagedUpdateDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Log.write("updates: \(item.displayVersionString) downloaded and staged — the island will ask to restart")
        UpdateReadyNotice.shared.stage(version: item.displayVersionString, install: immediateInstallHandler)
        return true
    }
}

/// "Should the island ask to restart for the update, right now?" — pure, so it
/// can be tested without Sparkle, a clock or a Conductor.
enum UpdateReadyPolicy {
    /// "Later" asks again after this long, or at the next launch — whichever
    /// comes first. The next launch needs nothing here: quitting installs the
    /// update, and a dismissal lives only in memory.
    static let askAgainAfter: TimeInterval = 24 * 60 * 60

    static let sentence = "A new version of Alfie is ready."
    static let restartLabel = "Restart to update"
    static let laterLabel = "Later"

    /// - Parameters:
    ///   - staged: Sparkle has an update downloaded and waiting to install.
    ///   - dismissedAt: when the person last pressed "Later", nil if never.
    ///   - meetingRecording: a meeting is being recorded.
    ///   - voiceBusy: Moe is listening or speaking, or a conversation is open.
    ///   - replyInProgress: a turn is running — thinking, or acting on the Mac.
    static func shouldShow(staged: Bool, dismissedAt: Date?, now: Date,
                           meetingRecording: Bool, voiceBusy: Bool, replyInProgress: Bool) -> Bool {
        guard staged else { return false }
        // Deferred, not dropped: the same question is asked again when the
        // state that blocked it goes away.
        if meetingRecording || voiceBusy || replyInProgress { return false }
        if let dismissedAt {
            let waited = now.timeIntervalSince(dismissedAt)
            // A clock set backwards makes `waited` negative; that is not
            // "dismissed a moment ago" for ever, so it asks.
            if waited >= 0 && waited < askAgainAfter { return false }
        }
        return true
    }
}

// MARK: - The glow (docs/DEFAULTS.md row 47: glow + panel, owner 2026-09-15)

/// What lights the collapsed island's amber glow, and what a tap on it does.
///
/// No new mark. A held nudge already turns the folded island's presence dot
/// full white (`IslandEars.Right.waiting`); an update ready to install is a
/// second reason for that same dot, and the panel it opens holds the notice.
/// (Until 2026-10-15 the dot was an amber halo that breathed.)
///
/// `updateNoticeShowing` is `UpdateReadyNotice.showing(for:)` and nothing
/// else, so the glow lights exactly when the notice would show and goes out
/// with it: during a recorded meeting, while Moe is listening or speaking or
/// working on a reply, for a day after "Later", and when Moe quits to install.
///
/// Not gated on "Let Moe bring things up on its own" (`Config.nudges`). That
/// switch promises Moe will not look at your things and raise them by itself
/// (Settings › Background, doc.md "Speaking up"). A new version of Memoe waiting
/// for a restart is Moe's own housekeeping, not something it noticed about
/// you, so it glows with the switch off too.
enum IslandGlow {
    /// A click on the glow opens the island, where the card is — the
    /// reminder with its Play, the update with Restart, the call with Record
    /// (2026-09-24). It used to play a held reminder aloud, so the same amber
    /// meant "click to hear" for one thing and "click to open" for another.
    static func glows(nudgeHeld: Bool, updateNoticeShowing: Bool, callOffered: Bool = false) -> Bool {
        nudgeHeld || updateNoticeShowing || callOffered
    }
}

/// The staged update, as the island sees it.
@MainActor
final class UpdateReadyNotice: ObservableObject {
    static let shared = UpdateReadyNotice()

    @Published private(set) var staged = false
    @Published private(set) var version: String?
    @Published private(set) var dismissedAt: Date?
    /// Bumped when "Later" runs out, so the views re-ask the policy even when
    /// nothing else about Moe changed in those 24 hours.
    @Published private(set) var askAgainTick = 0

    /// Sparkle's `immediateInstallHandler`. Kept, not consumed: since Sparkle
    /// 2.3 it "can be invoked multiple times in case the application cancels
    /// the termination request".
    private var install: (() -> Void)?
    private var askAgain: Task<Void, Never>?

    func stage(version: String, install: @escaping () -> Void) {
        self.install = install
        self.version = version
        staged = true
    }

    /// Whether the island shows the notice now, from the Conductor's state.
    func showing(for c: Conductor, now: Date = Date()) -> Bool {
        UpdateReadyPolicy.shouldShow(
            staged: staged, dismissedAt: dismissedAt, now: now,
            meetingRecording: c.meeting.isRecording,
            voiceBusy: c.mode == .listening || c.mode == .speaking || c.inConversation || c.dictation != .off,
            replyInProgress: c.mode == .thinking || c.acting || c.drivingApp != nil || c.browsing)
    }

    /// "Restart to update": Sparkle installs and relaunches Moe.
    func restartToUpdate() {
        guard let install else { return }
        Log.write("updates: restarting to install \(version ?? "the update") — the person asked")
        install()
    }

    /// "Later": ask again in 24 hours (or at the next launch).
    func later(now: Date = Date()) {
        dismissedAt = now
        Log.write("updates: restart to update put off for a day")
        askAgain?.cancel()
        askAgain = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UpdateReadyPolicy.askAgainAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.askAgainTick &+= 1
        }
    }
}
