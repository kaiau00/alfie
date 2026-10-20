import Foundation
import Testing
@testable import MoeErase

// docs/DEFAULTS.md row 41: "Uninstall Memoe…" is gone, and *Erase Memoe from this
// Mac* is the one way out. Uninstall did two things for a Mac that the erase
// must not lose: it booted out every launchd label Moe has ever written, and it
// took the app out of System Settings › Login Items. Left behind, the first is
// a job re-running a binary that is gone every ten minutes; the second opens
// the erased app at the next login.
//
// Same fake home and recorder as MacEraseTests: nothing here reaches launchctl
// or ServiceManagement.

/// A login item that is a flag in memory.
final class FakeLoginItem: MacEraseLoginItem {
    var registered: Bool
    var failure: String?
    var unregisterCalls = 0
    init(registered: Bool, failure: String? = nil) {
        self.registered = registered
        self.failure = failure
    }
    func isRegistered() -> Bool { registered }
    func unregister() -> String? {
        unregisterCalls += 1
        if let failure { return failure }
        registered = false
        return nil
    }
}

@Suite("Erase is the one exit: background jobs and the login item")
struct MacEraseLoginItemTests {

    /// Exactly what `Uninstall.run()` booted out before it was removed:
    /// `Launchd.jobsLabel` (com.moe.jobs for Moe), `Launchd.supersededLabels`,
    /// the pre-Hermes bot and the open-at-login job.
    static let uninstallLabels = ["com.moe.jobs", "com.moe.sync", "com.moe.digest", "com.moe.bot", "com.memoe.app"]

    static func index(_ plan: MacErasePlan, where match: (MacEraseItem) -> Bool) -> Int? {
        plan.remove.firstIndex(where: match)
    }

    @Test("the plan stops every job Uninstall stopped and takes Moe out of Login Items, before the home goes")
    func planHasJobsAndLoginItem() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let rec = Recorder()
        rec.loaded = Set(Self.uninstallLabels)
        let login = FakeLoginItem(registered: true)
        let erase = MacErase(scope: s, keychain: nil, commands: rec, uid: 501, loginItem: login, relaunch: {})

        let plan = erase.plan()
        for label in Self.uninstallLabels {
            #expect(plan.remove.contains { item in
                if case .launchd(let l, _, let loaded) = item { return l == label && loaded }
                return false
            }, "the erase plan does not boot out \(label)")
        }
        #expect(plan.remove.contains(.loginItem(bundleID: MacEraseIdentity.releaseBundleID)),
                "the erase plan does not take Moe out of Login Items")

        // Both before Moe's home is removed: a job firing, or a login opening
        // the app, mid-erase would write the home again.
        let home = try #require(Self.index(plan) { if case .path(let u, _) = $0 { return u == s.moeHome }; return false })
        let login0 = try #require(Self.index(plan) { if case .loginItem = $0 { return true }; return false })
        let jobs0 = try #require(Self.index(plan) { if case .launchd = $0 { return true }; return false })
        #expect(login0 < home)
        #expect(jobs0 < home)

        let report = erase.run(plan)
        #expect(report.ok, "\(report.text)")
        for label in Self.uninstallLabels {
            #expect(rec.calls.contains(["/bin/launchctl", "bootout", "gui/501/\(label)"]), "\(label) was not booted out")
        }
        #expect(login.unregisterCalls == 1)
        #expect(!login.registered)
    }

    @Test("no login item is listed when macOS has none, or when no login item was handed in")
    func noLoginItem() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let off = FakeLoginItem(registered: false)
        let planned = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 501, loginItem: off, relaunch: {}).plan()
        #expect(!planned.remove.contains { if case .loginItem = $0 { return true }; return false })
        let without = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 501, relaunch: {}).plan()
        #expect(!without.remove.contains { if case .loginItem = $0 { return true }; return false })
        #expect(off.unregisterCalls == 0)
    }

    @Test("a login item macOS refuses to remove is a failure the person is told about, not a silent success")
    func refusedUnregister() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let login = FakeLoginItem(registered: true, failure: "Operation not permitted")
        let erase = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 501, loginItem: login, relaunch: {})
        let report = erase.run(erase.plan())
        #expect(!report.ok)
        #expect(report.failures.contains { $0.0 == .loginItem(bundleID: MacEraseIdentity.releaseBundleID) })
    }

    @Test("a login item step for another identity is refused at run time")
    func otherIdentityRefused() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.devBundleID)
        let login = FakeLoginItem(registered: true)
        let dev = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 501, loginItem: login, relaunch: {})
        let forged = MacErasePlan(scope: s, remove: [.loginItem(bundleID: MacEraseIdentity.releaseBundleID)], left: [])
        let report = dev.run(forged)
        #expect(!report.ok)
        #expect(login.unregisterCalls == 0)
    }
}
