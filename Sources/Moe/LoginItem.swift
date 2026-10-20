import Foundation
import MoeErase
import ServiceManagement

/// Moe as a login item — the thing that starts it when the Mac signs in.
///
/// `Config.launchAtLogin` is the intent and this is the only place that acts
/// on it. macOS keeps its own switch for the same thing in System Settings ›
/// Login Items, and once the person has touched that, theirs wins: so the
/// config is applied **once**, on the first launch that carries it, and never
/// re-asserted. Re-registering on every launch would quietly undo a "no" the
/// person gave in System Settings, which is the one thing a login item must
/// never do. `set(_:)` is the explicit path for a switch in Settings, which
/// may register or unregister as often as the person asks.
///
/// **When "once" happens** (docs/DEFAULTS.md row 30: "set at the end of
/// onboarding so it is not a surprise"). The first registration is made when
/// the person finishes the welcome, whose last screen shows the switch — not
/// at app launch. Launch applies it only for a Mac that finished the welcome
/// before this rule existed, and never on the launch that follows *Erase Memoe
/// from this Mac*: that erase takes Moe out of Login Items and then opens the
/// app again with an empty home, and a launch that registered would put Moe
/// straight back — so a person who erased and dragged Moe to the Bin still
/// found it in Login Items (the review, 2026-09-15). `shouldApply` is that
/// decision with nothing in it that touches macOS, so it can be tested.
///
/// The marker is written only when macOS took the change. A registration that
/// failed — a copy run from the disk image, say — is tried again next time
/// instead of being remembered as done.
///
/// A developer build (bundle id ending in `.dev`) never registers: Moe Dev
/// quits at launch when the real Moe is running, and a workbench that fights
/// the real app for the login slot is the wrong kind of realism.
enum LoginItem {
    /// One file, so "applied once" survives a config.json rewrite.
    static var marker: URL { Config.homeDir.appendingPathComponent(".login-item-applied") }

    static var isDeveloperBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }

    /// What macOS currently says, as a word for logs and the Permissions pane.
    static var status: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// The two moments the config's intent may be applied.
    enum Moment: Equatable {
        /// App launch. `onboarded` is `Onboarding.done`; `erased` is a
        /// `MacEraseNote` in the home, which only the launch after an erase has.
        case launch(onboarded: Bool, erased: Bool)
        /// The person finished the welcome — Take me to Connections, or Not
        /// now on its last screen.
        case welcomeFinished
    }

    /// Whether to apply the config's intent now. Pure: no file, no macOS.
    static func shouldApply(_ moment: Moment, markerPresent: Bool) -> Bool {
        guard !markerPresent else { return false }
        switch moment {
        case .welcomeFinished:
            return true
        case .launch(let onboarded, let erased):
            // A Mac that finished the welcome before registration moved
            // there. Not one still in it, and never the relaunch an erase
            // opens — whatever else that launch finds in the home.
            return onboarded && !erased
        }
    }

    /// Only an outcome macOS accepted counts as applied.
    static func isApplied(_ outcome: String) -> Bool {
        outcome == "registered" || outcome == "unregistered"
    }

    /// The launch moment for this Mac, read from the home.
    static func launchMoment(home: URL = Config.homeDir, onboarded: Bool) -> Moment {
        .launch(onboarded: onboarded,
                erased: FileManager.default.fileExists(atPath: MacEraseNote.url(in: home).path))
    }

    /// Apply the config's intent if the moment allows it and it has never been
    /// applied on this Mac. Returns what it did, so a test can assert the side
    /// effect. `registrar` is `set(_:)` in the app; a test hands in a recorder,
    /// so nothing here reaches ServiceManagement from a test process.
    @discardableResult
    static func applyOnce(_ config: Config, at moment: Moment, home: URL = Config.homeDir,
                          developerBuild: Bool = LoginItem.isDeveloperBuild,
                          registrar: (Bool) -> String = { LoginItem.set($0) }) -> String {
        guard !developerBuild else { return "skipped (developer build)" }
        let marker = home.appendingPathComponent(".login-item-applied")
        let present = FileManager.default.fileExists(atPath: marker.path)
        if present { return "already applied" }
        guard shouldApply(moment, markerPresent: present) else {
            if case .launch(_, let erased) = moment, erased { return "not now (the launch after an erase)" }
            return "not now (the welcome is not finished)"
        }
        let outcome = registrar(config.launchAtLogin)
        if isApplied(outcome) {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try? Data().write(to: marker)
        }
        return outcome
    }

    /// Register or unregister now. The person asked, so no marker check.
    @discardableResult
    static func set(_ on: Bool) -> String {
        guard !isDeveloperBuild else { return "skipped (developer build)" }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            Log.write("login item: \(on ? "on" : "off") — macOS says \(status)")
            return on ? "registered" : "unregistered"
        } catch {
            Log.write("login item: could not \(on ? "register" : "unregister") — \(error.localizedDescription)")
            return "failed: \(error.localizedDescription)"
        }
    }
}
