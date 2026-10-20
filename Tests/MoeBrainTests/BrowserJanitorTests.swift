import Foundation
import Testing
@testable import MoeBrain

/// Old Chrome for Testing builds and Chrome's on-device model are swept; the
/// build Hermes launches and anything a live process uses never are.
struct BrowserJanitorTests {

    /// The owner's Mac, 2026-09-25: four builds, the newest one running.
    static let measured = ["chrome-153.0.8010.36", "chrome-153.0.8010.47",
                           "chrome-153.0.8010.52", "chrome-154.0.8037.57"]
    static let root = "/Users/x/.agent-browser/browsers"

    @Test("every build older than the newest complete one goes")
    func olderGo() {
        let stale = BrowserJanitor.staleBuilds(entries: Self.measured, root: Self.root,
                                               processTable: "") { _ in true }
        #expect(stale == ["chrome-153.0.8010.36", "chrome-153.0.8010.47", "chrome-153.0.8010.52"])
    }

    @Test("versions compare as numbers, not text: 99 is older than 154")
    func numericOrder() {
        let stale = BrowserJanitor.staleBuilds(entries: ["chrome-154.0.1.1", "chrome-99.0.9.9"],
                                               root: Self.root, processTable: "") { _ in true }
        #expect(stale == ["chrome-99.0.9.9"])
    }

    @Test("a newest build with no executable (mid-download) does not count; the one before it is kept")
    func incompleteNewest() {
        let stale = BrowserJanitor.staleBuilds(entries: Self.measured, root: Self.root, processTable: "") {
            $0 != "chrome-154.0.8037.57"
        }
        #expect(stale == ["chrome-153.0.8010.36", "chrome-153.0.8010.47"])
    }

    @Test("no complete build at all: nothing goes")
    func noneComplete() {
        #expect(BrowserJanitor.staleBuilds(entries: Self.measured, root: Self.root,
                                           processTable: "") { _ in false }.isEmpty)
    }

    @Test("an old build a process is still running from is kept")
    func runningKept() {
        let table = " 29909 \(Self.root)/chrome-153.0.8010.47/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --headless=new"
        let stale = BrowserJanitor.staleBuilds(entries: Self.measured, root: Self.root,
                                               processTable: table) { _ in true }
        #expect(stale == ["chrome-153.0.8010.36", "chrome-153.0.8010.52"])
    }

    @Test("only chrome-<numbers> entries are considered")
    func onlyVersioned() {
        #expect(BrowserJanitor.version("chrome-154.0.8037.57") == [154, 0, 8037, 57])
        #expect(BrowserJanitor.version("chrome-154.0.8037.57.partial") == nil)
        #expect(BrowserJanitor.version("chromium-1187") == nil)
        #expect(BrowserJanitor.version(".DS_Store") == nil)
    }

    // MARK: - sweep, on a real temp directory

    private func tree() throws -> (root: String, hermes: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("browserjanitor-\(UUID().uuidString)").path
        let root = base + "/browsers", hermes = base + "/hermes"
        let fm = FileManager.default
        for b in Self.measured {
            let exe = BrowserJanitor.executables(in: root + "/" + b)[0]
            try fm.createDirectory(atPath: (exe as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            fm.createFile(atPath: exe, contents: Data("#!/bin/sh\n".utf8),
                          attributes: [.posixPermissions: 0o755])
        }
        let model = hermes + "/browser-profile/chrome/" + BrowserJanitor.onDeviceModelDir + "/2025.8.8.1141"
        try fm.createDirectory(atPath: model, withIntermediateDirectories: true)
        fm.createFile(atPath: model + "/weights.bin", contents: Data(count: 1024))
        return (root, hermes)
    }

    @Test("sweep removes the old builds and the model when no driven browser runs")
    func sweepIdle() throws {
        let (root, hermes) = try tree()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }

        let line = BrowserJanitor.sweep(browsersRoot: root, hermesHome: hermes,
                                        processTable: "  1 /sbin/launchd\n")

        let left = try FileManager.default.contentsOfDirectory(atPath: root)
        #expect(left == ["chrome-154.0.8037.57"])
        #expect(!FileManager.default.fileExists(
            atPath: hermes + "/browser-profile/chrome/" + BrowserJanitor.onDeviceModelDir))
        #expect(FileManager.default.fileExists(atPath: hermes + "/browser-profile/chrome"),
                "the profile itself (the person's sign-ins) stays")
        #expect(line?.contains("chrome/OptGuideOnDeviceModel") == true)
    }

    @Test("with the driven browser running, the model is left for next time")
    func sweepBusy() throws {
        let (root, hermes) = try tree()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let table = "38391 \(root)/chrome-154.0.8037.57/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --user-data-dir=\(hermes)/browser-profile/chrome --headless=new\n"

        BrowserJanitor.sweep(browsersRoot: root, hermesHome: hermes, processTable: table)

        #expect(FileManager.default.fileExists(
            atPath: hermes + "/browser-profile/chrome/" + BrowserJanitor.onDeviceModelDir + "/2025.8.8.1141/weights.bin"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["chrome-154.0.8037.57"])
    }
}
