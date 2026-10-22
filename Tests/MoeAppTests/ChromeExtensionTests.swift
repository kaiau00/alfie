import Foundation
import Testing
import MoeBrain
@testable import Moe

/// Connections › Chrome (ticket #13). The reports below are what
/// `configure-hermes.py --chrome-extension-status` printed on 2026-09-24
/// against a throwaway Chrome for Testing 154 with the Memoe extension
/// loaded unpacked and a scratch Hermes home — measured, then quoted.
@MainActor
@Suite(.serialized)
struct ChromeExtensionTests {
    static let measuredNotInstalled = #"{"connected": false, "enabled": false, "error": null, "extension": null, "host_installed": false, "source": "/Users/x/.hermes/hermes-agent/extensions/chrome", "warnings": []}"#
    static let measuredOff = #"{"connected": false, "enabled": false, "error": null, "extension": null, "host_installed": true, "source": "/Users/x/.hermes/hermes-agent/extensions/chrome", "warnings": []}"#
    static let measuredWaiting = #"{"connected": false, "enabled": true, "error": null, "extension": null, "host_installed": true, "source": "/Users/x/.hermes/hermes-agent/extensions/chrome", "warnings": []}"#
    static let measuredConnected = #"{"connected": true, "enabled": true, "error": null, "extension": {"extensionId": "ljblhmlmgflmbffbfelamefleikodmjh", "fileAccess": true, "protocol": 1, "version": "0.2.1"}, "host_installed": true, "source": "/Users/x/.hermes/hermes-agent/extensions/chrome", "warnings": [{"code": "file_access_on", "text": "Alfie's Chrome extension is allowed to open files on this Mac. Alfie never uses that; turn it off in Chrome › Extensions › Alfie › \"Allow access to file URLs\"."}]}"#

    @Test func theRowSaysOneOfItsStatesFromTheStatusLine() throws {
        func state(_ json: String, staged: Bool = true) -> ChromeLaneState {
            ChromeLaneState.from(ChromeLaneReport.parse("written: noise\n" + json), staged: staged)
        }
        #expect(state(Self.measuredNotInstalled) == .notInstalled)
        #expect(state(Self.measuredOff) == .off)
        #expect(state(Self.measuredWaiting) == .waiting)
        #expect(state(Self.measuredConnected) == .connected)
        #expect(state(Self.measuredWaiting, staged: false) == .notInstalled,
                "a host with no folder for Load unpacked is not installed")
        #expect(ChromeLaneState.from(nil, staged: true) == .notInstalled)
        #expect(ChromeLaneState.waiting.word == "Installed, not connected")
        #expect(ChromeLaneState.connected.word == "Connected")
        #expect(ChromeLaneState.notInstalled.word == "Not installed")
    }

    @Test func theFileAccessWarningIsShownOnlyWhenConnectedAndPresent() throws {
        let on = ChromeExtensionModel(demo: try #require(ChromeLaneReport.parse(Self.measuredConnected)))
        #expect(on.fileAccessWarning?.contains("Allow access to file URLs") == true)
        let clean = Self.measuredConnected.replacingOccurrences(
            of: #"[{"code": "file_access_on""#, with: #"[{"code": "other""#)
        #expect(ChromeExtensionModel(demo: try #require(ChromeLaneReport.parse(clean))).fileAccessWarning == nil)
    }

    final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var opened: [URL] = []
        var revealed: [URL] = []
        var failInstall = false
        var chrome = true
        var matches = true
        var status = ChromeExtensionTests.measuredWaiting
        let lock = NSLock()
    }

    static func model(_ r: Recorder) -> ChromeExtensionModel {
        ChromeExtensionModel(seams: .init(
            configure: { args in
                r.lock.lock(); defer { r.lock.unlock() }
                r.calls.append(args)
                if args.first == "--install-chrome-extension", r.failInstall {
                    return .failure(.init(message: "this Hermes has no extensions/chrome"))
                }
                return .success(args == ["--chrome-extension-status"] ? r.status : "written: ok")
            },
            stagedExists: { true },
            chromeInstalled: { r.chrome },
            stagedMatches: { _ in r.matches },
            openInChrome: { r.opened.append($0); return true },
            revealInFinder: { r.revealed.append($0) }))
    }

    @Test func setUpStagesWritesTheHostTurnsTheFlagOnAndOpensChrome() async throws {
        let r = Recorder()
        let m = Self.model(r)
        await m.setUp()
        #expect(r.calls == [
            ["--install-chrome-extension", ChromeExtension.stagedFolder.path],
            ["--set-chrome-extension", "on"],
            ["--chrome-extension-status"],
        ])
        #expect(r.opened == [URL(string: "chrome://extensions")!])
        #expect(r.revealed == [ChromeExtension.stagedFolder])
        #expect(m.state == .waiting)
        // The extension says hello: the next poll turns the row green.
        r.status = Self.measuredConnected
        await m.refresh()
        #expect(m.state == .connected)
    }

    @Test func aFailedInstallNeverTurnsTheLaneOn() async throws {
        let r = Recorder()
        r.failInstall = true
        let m = Self.model(r)
        await m.setUp()
        #expect(r.calls == [["--install-chrome-extension", ChromeExtension.stagedFolder.path]])
        #expect(r.opened.isEmpty)
        #expect(m.note.contains("extensions/chrome"))
    }

    @Test func turningItOffWritesTheFlagOffAndSaysWhereToRemoveIt() async throws {
        let r = Recorder()
        r.status = Self.measuredOff
        let m = Self.model(r)
        await m.setEnabled(false)
        #expect(r.calls == [["--set-chrome-extension", "off"], ["--chrome-extension-status"]])
        #expect(m.state == .off)
        #expect(m.note.contains("remove it there"))
        await m.setEnabled(true)
        #expect(r.calls.dropFirst(2).first == ["--set-chrome-extension", "on"])
    }

    /// Review, 2026-09-24: install-host's mkdir(parents=True) made Chrome's own
    /// folder on a Mac with no Chrome. Nothing may run before the check.
    @Test func withoutChromeSetUpDoesNothingAndSaysInstallChromeFirst() async {
        let r = Recorder()
        r.chrome = false
        let m = Self.model(r)
        await m.setUp()
        #expect(r.calls.isEmpty, "no install-host, no flag, no status")
        #expect(r.opened.isEmpty && r.revealed.isEmpty)
        #expect(m.note.hasPrefix("Install Google Chrome first"))
    }

    @Test func aStagedExtensionThatDiffersFromThePinnedOneSaysUpdateAvailable() async {
        let r = Recorder()
        r.status = Self.measuredConnected
        r.matches = false
        let m = Self.model(r)
        await m.refresh()
        #expect(m.state == .connected)
        #expect(m.needsUpdate)
        #expect(m.word == "Update available")
        // Update is Set up: it stages again from the pinned Hermes.
        await m.setUp()
        #expect(r.calls.contains(["--install-chrome-extension", ChromeExtension.stagedFolder.path]))
        r.matches = true
        #expect(!m.needsUpdate)
        #expect(m.word == "Connected · one thing to check")
    }

    @Test func theDigestSeesAChangedFileAndIgnoresWhereTheFolderIs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chrome-digest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func tree(_ name: String, _ bg: String) throws -> URL {
            let d = root.appendingPathComponent(name)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(#"{"version": "0.2.1"}"#.utf8).write(to: d.appendingPathComponent("manifest.json"))
            try Data(bg.utf8).write(to: d.appendingPathComponent("background.js"))
            return d
        }
        let a = try tree("a", "one"), b = try tree("b", "one"), c = try tree("c", "two")
        #expect(ChromeExtension.treeDigest(a) != nil)
        #expect(ChromeExtension.treeDigest(a) == ChromeExtension.treeDigest(b))
        #expect(ChromeExtension.treeDigest(a) != ChromeExtension.treeDigest(c))
        #expect(ChromeExtension.treeDigest(root.appendingPathComponent("missing")) == nil)
    }

    @Test func theStoreURLIsOneConstantAndNotLiveYet() {
        #expect(ChromeExtension.storeURL == nil, "flip this when the unlisted listing is live")
        #expect(ChromeExtension.extensionID == "ljblhmlmgflmbffbfelamefleikodmjh")
    }
}
