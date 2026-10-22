import Foundation
import Testing
@testable import Moe
import MoeErase

/// docs/DEFAULTS.md row 41 — About & Licences has no "Uninstall Memoe…";
/// *Erase Memoe from this Mac* is the one exit, so the erase the app actually
/// runs has to do what Uninstall did for the Mac: stop every background job
/// and take Moe out of Login Items. The engine's own tests
/// (Tests/MoeEraseTests/MacEraseLoginItemTests.swift) prove the plan does it
/// when handed a login item; this proves the app hands it one.
struct EraseIsTheOneExitTests {

    @Test("row 41 — the erase Alfie runs is handed the real login item")
    func engineHasLoginItem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-one-exit-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Users/person", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try MacEraseScope.resolve(
            bundleID: MacEraseIdentity.releaseBundleID, infoMoeHome: nil, environment: [:],
            realUserHome: home, applications: home.appendingPathComponent("Applications", isDirectory: true),
            debugBuild: false)
        #expect(!scope.scratch)
        // Constructing the engine runs nothing; plan() would ask launchctl, so it is not called.
        let engine = MacEraseRun.engine(scope)
        #expect(engine.loginItem is SystemLoginItem)
    }

    @Test("row 41 — every job Uninstall booted out is on the erase's list")
    func everyUninstallLabel() throws {
        let release = try #require(MacEraseIdentity(bundleID: MacEraseIdentity.releaseBundleID))
        // Launchd.jobsLabel is derived from the running bundle, which under
        // `swift test` is not Moe's — so Moe's value is spelled out.
        for label in ["com.moe.jobs"] + Launchd.supersededLabels + ["com.moe.bot", "com.memoe.app"] {
            #expect(release.launchdLabels.contains(label), "\(label) would outlive the erase")
        }
    }
}
