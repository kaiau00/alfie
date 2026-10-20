import Foundation
import Testing
@testable import MoeErase

// What an erase says afterwards (MacEraseNote), and that nothing it could not
// remove goes unsaid. Everything against a FakeHome; nothing real is touched.

/// Removes for real, except the paths it is told to refuse — and those it
/// refuses the way macOS does. The error is the one `FileManager.removeItem`
/// threw on 2026-09-11 for a folder holding a `chflags uchg` file, measured
/// on this Mac: NSCocoaErrorDomain 513 (NSFileWriteNoPermissionError) over
/// NSPOSIXErrorDomain 1 (EPERM), "“lockdir” couldn’t be removed because you
/// don’t have permission to access it."
final class RefusingFiles: MacEraseFileOps {
    let suffixes: [String]
    var attempted: [String] = []
    init(refusing suffixes: [String]) { self.suffixes = suffixes }

    static func eperm(_ url: URL) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSFilePathErrorKey: url.path,
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” couldn’t be removed because you don’t have permission to access it.",
        ])
    }

    func removeItem(at url: URL) throws {
        attempted.append(url.path)
        if suffixes.contains(where: { url.path.hasSuffix($0) }) { throw Self.eperm(url) }
        try FileManager.default.removeItem(at: url)
    }
}

/// A keychain whose delete fails for one service.
final class FailingKeychain: MacEraseKeychainAccess {
    let failing: String
    init(failing: String) { self.failing = failing }
    func present(_ entry: MacEraseKeychainEntry) -> Bool { entry.service == failing }
    func deleteAll(_ entry: MacEraseKeychainEntry) -> Result<Int, MacEraseScopeError> {
        entry.service == failing ? .failure(.init("security exited 51 after 0 deleted")) : .success(0)
    }
}

@Suite("After an erase: what could not be removed is said, and CuaDriver stays gone")
struct MacEraseNoteTests {
    static let cuaSentence = "One thing Moe couldn't remove: CuaDriver, in your Applications folder — macOS only lets you do that. Drag it to the Bin."

    func release(_ fake: FakeHome, files: MacEraseFileOps, keychain: MacEraseKeychainAccess = MemoryKeychain([]),
                 relaunch: @escaping () -> Void = {}) throws -> MacErase {
        MacErase(scope: try scope(fake, MacEraseIdentity.releaseBundleID), keychain: keychain, commands: Recorder(),
                 uid: 501, selfPID: 107, files: files, signature: FakeSigner.trycua, relaunch: relaunch)
    }

    @Test("macOS refuses CuaDriver's app: the rest still goes, nothing claims it went, and the next launch is told")
    func appNotAllowed() throws {
        let fake = try FakeHome()
        try fake.populate()
        try fake.cuaDriver()
        try fake.cuaDriverData()
        let files = RefusingFiles(refusing: ["/Applications/CuaDriver.app"])
        let home = try scope(fake, MacEraseIdentity.releaseBundleID).moeHome
        var atRelaunch: MacEraseNote?
        let erase = try release(fake, files: files, relaunch: { atRelaunch = MacEraseNote.read(from: home) })
        let report = erase.eraseAndRelaunch()

        // Tried, refused, and reported as refused — not as removed, not as absent.
        #expect(files.attempted.contains { $0.hasSuffix("/Applications/CuaDriver.app") })
        let app = report.outcomes.first { $0.0.kind == "app" }?.1
        if case .notAllowed = app {} else { Issue.record("the app's outcome is \(String(describing: app))") }
        #expect(!report.ok)
        #expect(report.failures.count == 1, "\(report.text)")
        #expect(report.text.contains("NOT ALLOWED app"))
        #expect(fake.exists("Applications/CuaDriver.app/Contents/Info.plist"))

        // Everything else still went.
        for gone in [".hermes", ".moe", ".local/bin/hermes", ".cua-driver", "Library/Caches/cua-driver",
                     "Library/Application Support/CuaDriver", ".local/bin/cua-driver",
                     "Library/Application Support/Moe/config.json", "Library/Application Support/Moe/memory",
                     "Library/Application Support/FluidAudio", "Library/LaunchAgents/com.moe.jobs.plist"] {
            #expect(!fake.exists(gone), "\(gone) survived an erase that only failed on CuaDriver's app")
        }
        for kept in FakeHome.survivors { #expect(fake.exists(kept), "\(kept) was removed") }

        // The note was in the fresh home before the relaunch, in the person's words.
        let note = try #require(atRelaunch, "no note before the relaunch")
        #expect(note.text == Self.cuaSentence)
        #expect(note.leftovers.count == report.failures.count)
        #expect(note.reveal.count == 1 && note.reveal[0].path.hasSuffix("/Applications/CuaDriver.app"))
        #expect(!note.cuaDriverRemoved, "a note that says CuaDriver went, when it did not")
        #expect(!MacEraseNote.holdsDriverInstall(note, onboarded: false))
        // The home holds the note and nothing else: the next launch is still a first run.
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == [MacEraseNote.fileName])

        // Shown once: the first launch takes it, and nothing is left to show again.
        #expect(MacEraseNote.take(from: home, onboarded: false)?.text == Self.cuaSentence)
        #expect(MacEraseNote.read(from: home) == nil)
        #expect(MacEraseNote.take(from: home, onboarded: false) == nil)
    }

    @Test("every target that fails is named — paths, the keychain, CuaDriver's alike — and the rest still goes")
    func everyFailureIsNamed() throws {
        let fake = try FakeHome()
        try fake.populate()
        try fake.cuaDriver()
        try fake.cuaDriverData()
        let files = RefusingFiles(refusing: ["/.hermes", "/Library/Application Support/FluidAudio"])
        let erase = try release(fake, files: files, keychain: FailingKeychain(failing: "moe-child-oauth"))
        let report = erase.eraseAndRelaunch()
        let note = try #require(MacEraseNote.read(from: erase.scope.moeHome))

        #expect(report.failures.count == 3, "\(report.text)")
        #expect(note.leftovers.count == report.failures.count)
        #expect(Set(note.leftovers.map(\.target)) == Set(report.failures.map { $0.0.target }))
        #expect(note.text.hasPrefix("3 things Moe couldn't remove:\n"), "\(note.text)")
        #expect(note.text.contains("• ~/.hermes — macOS only lets you do that. Drag it to the Bin."), "\(note.text)")
        #expect(note.text.contains("• the keychain item moe-child-oauth (security exited 51"), "\(note.text)")
        #expect(note.reveal.count == 2)
        // CuaDriver's app did go here, and the note says so.
        #expect(note.cuaDriverRemoved)
        #expect(!fake.exists("Applications/CuaDriver.app"))
        #expect(!fake.exists(".cache/fluidaudio"))
        #expect(fake.exists(".hermes/.env"))
    }

    @Test("a clean erase that removed CuaDriver: nothing to show, and no reinstall until setup is done")
    func cleanEraseHoldsTheDriverInstall() throws {
        let fake = try FakeHome()
        try fake.populate()
        try fake.cuaDriver()
        try fake.cuaDriverData()
        let erase = try release(fake, files: LocalFileOps())
        let report = erase.eraseAndRelaunch()
        #expect(report.ok, "\(report.text)")
        let home = erase.scope.moeHome
        let note = try #require(MacEraseNote.read(from: home))
        #expect(note.leftovers.isEmpty && note.text.isEmpty && note.reveal.isEmpty)
        #expect(note.cuaDriverRemoved)
        #expect(note.identity == MacEraseIdentity.releaseBundleID)

        #expect(MacEraseNote.holdsDriverInstall(note, onboarded: false))
        #expect(!MacEraseNote.holdsDriverInstall(note, onboarded: true))
        #expect(!MacEraseNote.holdsDriverInstall(nil, onboarded: false))

        // The first launch after it: the hold stays on disk for configure-hermes.
        #expect(MacEraseNote.take(from: home, onboarded: false) == note)
        #expect(MacEraseNote.holdsDriverInstall(MacEraseNote.read(from: home), onboarded: false))
        // Once setup is done, the file goes.
        _ = MacEraseNote.take(from: home, onboarded: true)
        #expect(!FileManager.default.fileExists(atPath: MacEraseNote.url(in: home).path))
    }

    @Test("nothing failed and no CuaDriver: no note, and the home stays gone")
    func nothingToSay() throws {
        let fake = try FakeHome()
        try fake.populate()
        let erase = try release(fake, files: LocalFileOps())
        #expect(erase.eraseAndRelaunch().ok)
        #expect(!fake.exists("Library/Application Support/Moe"))
    }

    @Test("Moe Dev leaves CuaDriver, so its erase never holds Moe's driver install")
    func devNeverHolds() throws {
        let fake = try FakeHome()
        try fake.populate()
        try fake.cuaDriver()
        let dev = MacErase(scope: try scope(fake, MacEraseIdentity.devBundleID), keychain: nil, commands: Recorder(),
                           uid: 501, selfPID: 107, signature: FakeSigner.trycua, relaunch: {})
        #expect(dev.eraseAndRelaunch().ok)
        #expect(MacEraseNote.read(from: dev.scope.moeHome) == nil)
        #expect(fake.exists("Applications/CuaDriver.app/Contents/Info.plist"))
    }

    @Test("the note is never written through a link where the home was")
    func neverThroughALink() throws {
        let fake = try FakeHome()
        try fake.populate()
        let erase = try release(fake, files: LocalFileOps())
        let elsewhere = fake.url("Documents/elsewhere", dir: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: erase.scope.moeHome)
        try FileManager.default.createSymbolicLink(at: erase.scope.moeHome, withDestinationURL: elsewhere)
        let report = MacEraseReport(outcomes: [(.path(fake.url(".hermes"), why: "x"), .notAllowed("no"))])
        #expect(erase.leaveNote(for: report) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test("a removal error is .notAllowed for EPERM/EACCES in every wrapping, .failed otherwise, never .removed")
    func classifiesRemovalErrors() {
        let url = URL(fileURLWithPath: "/x/CuaDriver.app")
        for e in [RefusingFiles.eperm(url), NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                  NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))] {
            if case .notAllowed = MacErase.outcome(ofRemovalError: e) {} else { Issue.record("\(e) was not .notAllowed") }
        }
        let busy = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                           userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))])
        if case .failed = MacErase.outcome(ofRemovalError: busy) {} else { Issue.record("EBUSY was not .failed") }
    }

    @Test("configure-hermes.py skips the driver install on exactly the variable the app sets")
    func skipEnvMatchesTheScript() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(contentsOf: repo.appendingPathComponent("moe-home/hermes/configure-hermes.py"),
                                encoding: .utf8)
        #expect(script.contains("SKIP_DRIVER_ENV = \"\(MacEraseNote.skipDriverEnv)\""))
        #expect(script.contains("if os.environ.get(SKIP_DRIVER_ENV):"))
    }
}
