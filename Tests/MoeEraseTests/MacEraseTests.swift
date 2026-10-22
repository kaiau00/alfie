import Foundation
import Testing
@testable import MoeErase

// Erase Memoe from this Mac (CLOUD-REMAINING D9.12), against a temporary home.
//
// **Nothing here may touch this Mac.** Every test builds a fake `~` under
// the system temp directory and resolves its scope against THAT, never
// against the real home. launchctl, tccutil and defaults are recorders that
// execute nothing. The keychain is either a recorder or a throwaway keychain
// FILE created in the fake home (`security create-keychain` — measured on
// this Mac to leave the search list and the default keychain alone), and
// every `security` call goes through a wrapper script that refuses — exit
// 97, and a line in a violations file the test reads — any call whose last
// argument is not that file. So even an engine bug that dropped the keychain
// argument could not reach the login keychain: the wrapper would refuse it
// and the test would fail on the violation.

// MARK: - Fixtures

final class FakeHome {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-erase-test-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("Users/person", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // The one thing every test relies on, checked before anything runs.
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        precondition(!home.path.hasPrefix(real + "/Library") && home.path != real,
                     "the fake home must not be the real one")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ relative: String, dir: Bool = false) -> URL {
        home.appendingPathComponent(relative, isDirectory: dir)
    }

    @discardableResult
    func file(_ relative: String, _ text: String = "x") throws -> URL {
        let u = url(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    func exists(_ relative: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url(relative).path)) != nil
    }

    /// Both homes, fully populated, plus everything that must survive.
    func populate() throws {
        // Moe's home and Moe Dev's.
        try file("Library/Application Support/Moe/config.json", "{}")
        try file("Library/Application Support/Moe/memory/notes.md", "what Alfie knows")
        try file("Library/Application Support/Moe/models/whisper/model.bin")
        try file("Library/Application Support/Moe/cloud/credential.json")
        try file("Library/Application Support/Moe/.onboarded", "")
        try file("Library/Application Support/Moe Dev/config.json", "{}")
        try file("Library/Application Support/Moe Dev/memory/notes.md", "dev")
        try FileManager.default.createSymbolicLink(
            at: url(".moe"), withDestinationURL: url("Library/Application Support/Moe", dir: true))
        // Moe's Hermes, with channel sessions and the venv the wrapper names.
        try file(".hermes/.env", "TELEGRAM_BOT_TOKEN=x")
        try file(".hermes/whatsapp/session/creds.json")
        try file(".hermes/hermes-agent/.venv/bin/python")
        try file(".local/bin/hermes", "#!\(url(".hermes/hermes-agent/.venv/bin/python").path)\nimport sys\n")
        try file(".local/bin/uv", "#!/bin/sh\n")
        try file(".local/bin/node", "#!/bin/sh\n")
        // Downloaded models.
        try file("Library/Application Support/FluidAudio/Models/parakeet/x")
        try file(".cache/fluidaudio/Models/kokoro/x")
        // Bundle-scoped Library bits, for both identities.
        for id in ["com.memoe.app", "com.memoe.app.dev"] {
            try file("Library/Caches/\(id)/cache.db")
            try file("Library/HTTPStorages/\(id)/x")
            try file("Library/Preferences/\(id).plist")
            try file("Library/Saved Application State/\(id).savedState/data")
        }
        // launchd plists: both identities', plus the developer's snapshot net.
        for label in ["com.moe.jobs", "com.memoe.app", "com.memoe.app.dev.jobs",
                      "com.moe.worktree-snapshot", "com.other.agent"] {
            try file("Library/LaunchAgents/\(label).plist")
        }
        // Things that are not Moe's and must never go.
        try file(".claude/.credentials.json", "claude code")
        try file(".claude/projects/x/memory.md")
        try file(".codex/auth.json", "chatgpt")
        try file("Moe-backup-2026-09-10-1230/moe-home.tar.gz")
        try file("Documents/my-essay.txt")
        try file("Library/Keychains/login.keychain-db", "stand-in")
        try file("Library/Application Support/SomeOtherApp/data")
        try file(".local/bin/claude", "#!/bin/sh\n")   // Claude Code's command
    }

    static let survivors = [
        ".claude/.credentials.json", ".claude/projects/x/memory.md", ".codex/auth.json",
        "Moe-backup-2026-09-10-1230/moe-home.tar.gz", "Documents/my-essay.txt",
        "Library/Keychains/login.keychain-db", "Library/Application Support/SomeOtherApp/data",
        "Library/LaunchAgents/com.moe.worktree-snapshot.plist", "Library/LaunchAgents/com.other.agent.plist",
        ".local/bin/uv", ".local/bin/node", ".local/bin/claude",
    ]

    /// A CuaDriver.app with a real Info.plist naming `bundleID`, at
    /// `relative` (the fake home's own Applications folder by default —
    /// `scope()` hands that in; the real /Applications is never named here).
    @discardableResult
    func cuaDriver(bundleID: String = "com.trycua.driver",
                   at relative: String = "Applications/CuaDriver.app") throws -> URL {
        let app = url(relative, dir: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "cua-driver",
                                    "CFBundleName": "Cua Driver"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS", isDirectory: true),
                                                withIntermediateDirectories: true)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/cua-driver"))
        return app
    }

    /// What trycua's install.sh and the running driver leave under `~`,
    /// measured on this Mac 2026-09-11 (listed, never deleted): the
    /// `~/.local/bin/cua-driver` link into the app, `~/.cua-driver` (install
    /// records, telemetry id), its pid file in `~/Library/Caches/cua-driver`,
    /// and BrowserProfiles in Caches/CuaDriver and Application Support/CuaDriver.
    func cuaDriverData() throws {
        try file(".cua-driver/.telemetry_id")
        try file(".cua-driver/.release_installed/0.28.0")
        try file("Library/Caches/cua-driver/cua-driver.pid", "14632")
        try file("Library/Caches/CuaDriver/BrowserProfiles/x")
        try file("Library/Application Support/CuaDriver/BrowserProfiles/x")
        try FileManager.default.createDirectory(at: url(".local/bin", dir: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: url(".local/bin/cua-driver"),
            withDestinationURL: url("Applications/CuaDriver.app/Contents/MacOS/cua-driver"))
    }
}

/// launchctl / tccutil / defaults, recorded. `loaded` answers `launchctl print`.
final class Recorder: MacEraseCommands {
    var calls: [[String]] = []
    var loaded: Set<String> = []
    func run(_ executable: String, _ arguments: [String]) -> Int32 {
        calls.append([executable] + arguments)
        if executable.hasSuffix("launchctl"), arguments.first == "print",
           let target = arguments.last, let label = target.split(separator: "/").last {
            return loaded.contains(String(label)) ? 0 : 113
        }
        return 0
    }
    func called(_ tool: String, containing needle: String) -> Bool {
        calls.contains { $0[0].hasSuffix(tool) && $0.contains(needle) }
    }
    func anyCall(mentioning text: String) -> Bool {
        calls.contains { call in call.contains { $0.contains(text) } }
    }
}

/// A keychain that is a set in memory.
final class MemoryKeychain: MacEraseKeychainAccess {
    var items: [(service: String, account: String)]
    var calls: [MacEraseKeychainEntry] = []
    init(_ items: [(String, String)]) { self.items = items.map { (service: $0.0, account: $0.1) } }
    func matches(_ e: MacEraseKeychainEntry, _ i: (service: String, account: String)) -> Bool {
        i.service == e.service && (e.account == nil || e.account == i.account)
    }
    func present(_ entry: MacEraseKeychainEntry) -> Bool { items.contains { matches(entry, $0) } }
    func deleteAll(_ entry: MacEraseKeychainEntry) -> Result<Int, MacEraseScopeError> {
        calls.append(entry)
        let before = items.count
        items.removeAll { matches(entry, $0) }
        return .success(before - items.count)
    }
}

func scope(_ fake: FakeHome, _ id: String) throws -> MacEraseScope {
    try MacEraseScope.resolve(
        bundleID: id,
        infoMoeHome: id == MacEraseIdentity.devBundleID
            ? fake.url("Library/Application Support/Moe Dev", dir: true).path : nil,
        environment: [:], realUserHome: fake.home,
        // The fake home's own Applications folder — never the real one.
        applications: fake.url("Applications", dir: true), debugBuild: false)
}

// MARK: - The erase

@Suite("MacErase against a temporary home")
struct MacEraseTests {

    @Test("Alfie's erase removes everything Alfie's and nothing else")
    func releaseErase() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        #expect(s.keychain == .searchList)
        let rec = Recorder()
        rec.loaded = ["com.moe.jobs"]
        let keychain = MemoryKeychain([("moe-child-oauth", "moe"), ("moe-composio-scoped", "api-key"),
                                       ("moe-gmail", "me@example.com"), ("moe-gmail", "other@example.com"),
                                       ("Claude Code-credentials", "me"), ("https://sparkle-project.org", "ed25519"),
                                       ("inworld-api-key", "someone-else")])
        var relaunched = 0
        let erase = MacErase(scope: s, keychain: keychain, commands: rec, uid: 501, relaunch: { relaunched += 1 })
        let report = erase.eraseAndRelaunch()
        #expect(report.ok, "\(report.text)")
        #expect(relaunched == 1)

        // Gone.
        for gone in ["Library/Application Support/Moe", ".moe", ".hermes", ".local/bin/hermes",
                     "Library/Application Support/FluidAudio", ".cache/fluidaudio",
                     "Library/Caches/com.memoe.app", "Library/HTTPStorages/com.memoe.app",
                     "Library/Preferences/com.memoe.app.plist",
                     "Library/Saved Application State/com.memoe.app.savedState",
                     "Library/LaunchAgents/com.moe.jobs.plist", "Library/LaunchAgents/com.memoe.app.plist"] {
            #expect(!fake.exists(gone), "\(gone) survived Alfie's erase")
        }
        // Not Moe's, or Moe Dev's: all still there.
        for kept in FakeHome.survivors + ["Library/Application Support/Moe Dev/memory/notes.md",
                                         "Library/Caches/com.memoe.app.dev/cache.db",
                                         "Library/Preferences/com.memoe.app.dev.plist",
                                         "Library/LaunchAgents/com.memoe.app.dev.jobs.plist"] {
            #expect(fake.exists(kept), "\(kept) was removed by Alfie's erase")
        }
        // Keychain: Moe's items gone, both gmail accounts; the others kept —
        // including a same-named service under an account that is not Moe's.
        let left = keychain.items.map { "\($0.service)|\($0.account)" }.sorted()
        #expect(left == ["Claude Code-credentials|me", "https://sparkle-project.org|ed25519",
                         "inworld-api-key|someone-else"])
        // System calls: the loaded job booted out, permissions and prefs reset,
        // and never a word about the snapshot net or Moe Dev.
        #expect(rec.called("launchctl", containing: "gui/501/com.moe.jobs"))
        #expect(rec.calls.contains(["/bin/launchctl", "bootout", "gui/501/com.moe.jobs"]))
        #expect(rec.calls.contains(["/usr/bin/tccutil", "reset", "All", "com.memoe.app"]))
        #expect(rec.calls.contains(["/usr/bin/defaults", "delete", "com.memoe.app"]))
        #expect(!rec.anyCall(mentioning: "worktree-snapshot"))
        #expect(!rec.anyCall(mentioning: "com.memoe.app.dev"))
    }

    @Test("Alfie Dev's erase never touches Alfie's home, Hermes, models or keychain")
    func devErase() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.devBundleID)
        #expect(s.hermesHome == nil)
        // A keychain, limited to Moe Dev's own key for agreeing
        // (MacEraseKeychain.entries(for:)); see consentKeysPerIdentity.
        #expect(s.keychain == .searchList)
        let rec = Recorder()
        let dev = MacErase(scope: s, keychain: nil, commands: rec, uid: 501, relaunch: {})
        let plan = dev.plan()
        #expect(!plan.remove.contains { if case .keychain = $0 { return true }; return false })
        let report = dev.run(plan)
        #expect(report.ok, "\(report.text)")

        for gone in ["Library/Application Support/Moe Dev", "Library/Caches/com.memoe.app.dev",
                     "Library/Preferences/com.memoe.app.dev.plist",
                     "Library/LaunchAgents/com.memoe.app.dev.jobs.plist"] {
            #expect(!fake.exists(gone), "\(gone) survived Alfie Dev's erase")
        }
        for kept in FakeHome.survivors + [
            "Library/Application Support/Moe/memory/notes.md", "Library/Application Support/Moe/config.json",
            ".moe", ".hermes/.env", ".hermes/whatsapp/session/creds.json", ".local/bin/hermes",
            "Library/Application Support/FluidAudio/Models/parakeet/x", ".cache/fluidaudio/Models/kokoro/x",
            "Library/Caches/com.memoe.app/cache.db", "Library/Preferences/com.memoe.app.plist",
            "Library/LaunchAgents/com.moe.jobs.plist", "Library/LaunchAgents/com.memoe.app.plist",
        ] {
            #expect(fake.exists(kept), "\(kept) — Alfie's — was removed by Alfie Dev's erase")
        }
        #expect(rec.calls.contains(["/usr/bin/tccutil", "reset", "All", "com.memoe.app.dev"]))
        #expect(!rec.calls.contains { $0.contains("com.memoe.app") })
        #expect(!rec.anyCall(mentioning: "com.moe.jobs"))
        #expect(plan.left.contains { $0.contains("~/.hermes") })
    }

    @Test("each identity erases its own key for agreeing, and never the other's")
    func consentKeysPerIdentity() throws {
        let items = [("com.memoe.app.consent-key", "consent-signing-key"),
                     ("com.memoe.app.dev.consent-key", "consent-signing-key"),
                     ("moe-telegram-bot", "bot")]
        // Moe Dev: its own key, and nothing of Moe's.
        let devHome = try FakeHome()
        try devHome.populate()
        let devKeychain = MemoryKeychain(items)
        let dev = MacErase(scope: try scope(devHome, MacEraseIdentity.devBundleID), keychain: devKeychain,
                           commands: Recorder(), uid: 501, relaunch: {})
        let devPlan = dev.plan()
        let devKeys = devPlan.remove.compactMap { item -> String? in
            if case .keychain(let e) = item { return e.service }; return nil
        }
        #expect(devKeys == ["com.memoe.app.dev.consent-key"])
        #expect(dev.run(devPlan).ok)
        #expect(devKeychain.items.map(\.service).sorted() == ["com.memoe.app.consent-key", "moe-telegram-bot"])
        #expect(devKeychain.calls.map(\.service) == ["com.memoe.app.dev.consent-key"])
        // An entry of Moe's handed to Moe Dev's run is refused, not deleted.
        let smuggled = MacEraseKeychain.allowlist.first { $0.service == "com.memoe.app.consent-key" }!
        let refused = dev.run(MacErasePlan(scope: devPlan.scope, remove: [.keychain(smuggled)], left: []))
        #expect(!refused.ok || devKeychain.items.contains { $0.service == "com.memoe.app.consent-key" })
        #expect(devKeychain.items.contains { $0.service == "com.memoe.app.consent-key" })
        // Moe: its own key, and not Moe Dev's.
        let relHome = try FakeHome()
        try relHome.populate()
        let relKeychain = MemoryKeychain(items)
        let rel = MacErase(scope: try scope(relHome, "com.memoe.app"), keychain: relKeychain,
                           commands: Recorder(), uid: 501, relaunch: {})
        let relPlan = rel.plan()
        #expect(relPlan.remove.contains { if case .keychain(let e) = $0 { return e.service == "com.memoe.app.consent-key" }; return false })
        #expect(!relPlan.remove.contains { if case .keychain(let e) = $0 { return e.service == "com.memoe.app.dev.consent-key" }; return false })
        _ = rel.run(relPlan)
        #expect(relKeychain.items.contains { $0.service == "com.memoe.app.dev.consent-key" })
        #expect(!relKeychain.items.contains { $0.service == "com.memoe.app.consent-key" })
    }

    @Test("a ~/.moe that points anywhere else is left, and so is a real ~/.moe folder")
    func legacyLinkElsewhere() throws {
        let fake = try FakeHome()
        try fake.file("Library/Application Support/Moe/config.json")
        try fake.file("elsewhere/keep.txt")
        try FileManager.default.createSymbolicLink(at: fake.url(".moe"),
                                                   withDestinationURL: fake.url("elsewhere", dir: true))
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: MemoryKeychain([]), commands: Recorder(), uid: 1, relaunch: {})
        #expect(erase.run(erase.plan()).ok)
        #expect(!fake.exists("Library/Application Support/Moe"))
        #expect(fake.exists(".moe"))
        #expect(fake.exists("elsewhere/keep.txt"))

        let fake2 = try FakeHome()
        try fake2.file("Library/Application Support/Moe/config.json")
        try fake2.file(".moe/notes/mine.md")
        let s2 = try scope(fake2, MacEraseIdentity.releaseBundleID)
        let erase2 = MacErase(scope: s2, keychain: MemoryKeychain([]), commands: Recorder(), uid: 1, relaunch: {})
        let plan2 = erase2.plan()
        #expect(plan2.left.contains { $0.contains("real folder") })
        #expect(erase2.run(plan2).ok)
        #expect(fake2.exists(".moe/notes/mine.md"))
    }

    @Test("a link inside Alfie's home is removed as a link; what it points at survives")
    func linksAreNotFollowed() throws {
        let fake = try FakeHome()
        try fake.populate()
        try FileManager.default.createSymbolicLink(
            at: fake.url("Library/Application Support/Moe/claude-link"),
            withDestinationURL: fake.url(".claude", dir: true))
        try FileManager.default.createSymbolicLink(
            at: fake.url(".hermes/docs-link"), withDestinationURL: fake.url("Documents", dir: true))
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: MemoryKeychain([]), commands: Recorder(), uid: 1, relaunch: {})
        #expect(erase.run(erase.plan()).ok)
        #expect(!fake.exists("Library/Application Support/Moe"))
        #expect(fake.exists(".claude/.credentials.json"))
        #expect(fake.exists("Documents/my-essay.txt"))
    }

    @Test("Alfie's Chrome host goes with its Hermes; someone else's, or Alfie Dev's erase, leaves it")
    func chromeHost() throws {
        let fake = try FakeHome()
        let manifest = MacEraseChromeHost.manifest
        func host(launcher: String) -> String {
            #"{"name": "app.memoe.chrome_bridge", "path": "\#(launcher)", "type": "stdio"}"#
        }
        try fake.file(".hermes/chrome-bridge/memoe-chrome-host", "#!/bin/sh\n")
        try fake.file(".hermes/chrome-bridge/bridge.json", "{}")
        try fake.file(manifest, host(launcher: fake.url(".hermes/chrome-bridge/memoe-chrome-host").path))
        try fake.file("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.other.json", "{}")
        try fake.file("Library/Application Support/Google/Chrome/Default/Preferences", "{}")
        // Moe Dev shares ~/.hermes with Moe, so it leaves the host alone.
        let dev = MacErase(scope: try scope(fake, MacEraseIdentity.devBundleID), keychain: nil,
                           commands: Recorder(), uid: 1, relaunch: {})
        try fake.file("Library/Application Support/Moe Dev/config.json", "{}")
        #expect(dev.run(dev.plan()).ok)
        #expect(fake.exists(manifest))

        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: MemoryKeychain([]), commands: Recorder(), uid: 1, relaunch: {})
        #expect(erase.run(erase.plan()).ok)
        #expect(!fake.exists(manifest))
        #expect(!fake.exists(".hermes/chrome-bridge"))
        #expect(fake.exists("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.other.json"))
        #expect(fake.exists("Library/Application Support/Google/Chrome/Default/Preferences"))

        // A manifest by our name whose launcher is not in this Hermes: not ours.
        let other = try FakeHome()
        try other.file(".hermes/.env")
        try other.file(manifest, host(launcher: "/opt/somebody/else/host"))
        let e2 = MacErase(scope: try scope(other, MacEraseIdentity.releaseBundleID),
                          keychain: MemoryKeychain([]), commands: Recorder(), uid: 1, relaunch: {})
        #expect(e2.run(e2.plan()).ok)
        #expect(other.exists(manifest))
    }

    @Test("a hermes command that is not Alfie's Hermes is left")
    func foreignHermesWrapper() throws {
        let fake = try FakeHome()
        try fake.file(".hermes/.env")
        try fake.file(".local/bin/hermes", "#!/opt/somebody/else/python\n")
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: MemoryKeychain([]), commands: Recorder(), uid: 1, relaunch: {})
        #expect(erase.run(erase.plan()).ok)
        #expect(!fake.exists(".hermes"))
        #expect(fake.exists(".local/bin/hermes"))
    }

    @Test("the home is gone, so the next launch is a first run and shows onboarding")
    func freshHomeMeansOnboarding() throws {
        // FirstRun.installHomeIfNeeded: `firstRun = !exists(config.json)`;
        // AppDelegate shows onboarding when `firstRun`, and `Onboarding.done`
        // is the `.onboarded` marker inside the same home. Both live in the
        // home, so a removed home is a first run.
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: MemoryKeychain([]), commands: Recorder(), uid: 1, relaunch: {})
        _ = erase.eraseAndRelaunch()
        #expect(!FileManager.default.fileExists(atPath: s.moeHome.appendingPathComponent("config.json").path))
        #expect(!FileManager.default.fileExists(atPath: s.moeHome.appendingPathComponent(".onboarded").path))
    }
}

// MARK: - The guard and the scope

@Suite("MacErase refuses")
struct MacEraseRefusalTests {

    @Test("unknown identities are refused")
    func unknownIdentity() throws {
        let fake = try FakeHome()
        for id in [nil, "", "com.memoe.app.beta", "com.other.app", "com.memoe.app "] as [String?] {
            #expect(throws: MacEraseScopeError.self) {
                _ = try MacEraseScope.resolve(bundleID: id, infoMoeHome: nil, environment: [:],
                                              realUserHome: fake.home, debugBuild: false)
            }
        }
    }

    @Test("Alfie Dev without its own home, or with Alfie's, is refused")
    func devHomeMustBeItsOwn() throws {
        let fake = try FakeHome()
        for stamped in [nil, "", fake.url("Library/Application Support/Moe").path,
                        fake.url("Library/Application Support").path, fake.home.path] as [String?] {
            #expect(throws: MacEraseScopeError.self) {
                _ = try MacEraseScope.resolve(bundleID: MacEraseIdentity.devBundleID, infoMoeHome: stamped,
                                              environment: [:], realUserHome: fake.home, debugBuild: false)
            }
        }
        // And a release build that carries a MoeHome is not one build.sh makes.
        #expect(throws: MacEraseScopeError.self) {
            _ = try MacEraseScope.resolve(bundleID: MacEraseIdentity.releaseBundleID,
                                          infoMoeHome: fake.url("Library/Application Support/Moe Dev").path,
                                          environment: [:], realUserHome: fake.home, debugBuild: false)
        }
    }

    @Test("MOE_HOME is ignored by a release build")
    func releaseIgnoresEnvironment() throws {
        let fake = try FakeHome()
        let s = try MacEraseScope.resolve(bundleID: MacEraseIdentity.releaseBundleID, infoMoeHome: nil,
                                          environment: ["MOE_HOME": "/tmp/elsewhere", "HERMES_HOME": "/tmp/h",
                                                        "MOE_ERASE_USER_HOME": "/tmp/u"],
                                          realUserHome: fake.home, debugBuild: false)
        #expect(!s.scratch)
        #expect(s.moeHome.path == fake.url("Library/Application Support/Moe").path)
        #expect(s.hermesHome?.path == fake.url(".hermes").path)
    }

    @Test("a scratch run needs a scratch ~, never the real one, and keeps everything inside it")
    func scratchRules() throws {
        let fake = try FakeHome()
        let real = FileManager.default.homeDirectoryForCurrentUser
        func resolve(_ env: [String: String]) throws -> MacEraseScope {
            try MacEraseScope.resolve(bundleID: nil, infoMoeHome: nil, environment: env,
                                      realUserHome: real, debugBuild: true)
        }
        let inside = fake.url("moe-home").path
        #expect(throws: MacEraseScopeError.self) {   // no scratch ~
            _ = try resolve(["MOE_HOME": inside, "MOE_ERASE_BUNDLE_ID": "com.memoe.app"])
        }
        #expect(throws: MacEraseScopeError.self) {   // the real ~
            _ = try resolve(["MOE_HOME": inside, "MOE_ERASE_BUNDLE_ID": "com.memoe.app",
                             "MOE_ERASE_USER_HOME": real.path])
        }
        // The real ~ again, with a MOE_HOME inside it — so no other rule
        // (MOE_HOME must be inside the scratch ~) can be what refuses it.
        // `resolve` only reads; this path is never created.
        #expect(throws: MacEraseScopeError.self) {
            _ = try resolve(["MOE_HOME": real.appendingPathComponent("moe-erase-test-never-created/home").path,
                             "MOE_ERASE_BUNDLE_ID": "com.memoe.app", "MOE_ERASE_USER_HOME": real.path])
        }
        #expect(throws: MacEraseScopeError.self) {   // MOE_HOME outside the scratch ~
            _ = try resolve(["MOE_HOME": "/tmp/x", "MOE_ERASE_BUNDLE_ID": "com.memoe.app",
                             "MOE_ERASE_USER_HOME": fake.home.path])
        }
        #expect(throws: MacEraseScopeError.self) {   // HERMES_HOME outside it (the real ~/.hermes)
            _ = try resolve(["MOE_HOME": inside, "MOE_ERASE_BUNDLE_ID": "com.memoe.app",
                             "MOE_ERASE_USER_HOME": fake.home.path,
                             "HERMES_HOME": real.appendingPathComponent(".hermes").path])
        }
        #expect(throws: MacEraseScopeError.self) {   // a keychain file outside it (the login keychain)
            _ = try resolve(["MOE_HOME": inside, "MOE_ERASE_BUNDLE_ID": "com.memoe.app",
                             "MOE_ERASE_USER_HOME": fake.home.path,
                             "MOE_ERASE_KEYCHAIN": real.appendingPathComponent("Library/Keychains/login.keychain-db").path])
        }
        let ok = try resolve(["MOE_HOME": inside, "MOE_ERASE_BUNDLE_ID": "com.memoe.app",
                              "MOE_ERASE_USER_HOME": fake.home.path])
        #expect(ok.scratch)
        #expect(ok.keychain == .none, "no keychain unless one is named")
        #expect(ok.hermesHome == nil, "no Hermes home unless one is named")
        // And a scratch run executes no system command: they are recorded.
        #expect(MacErase.standard(scope: ok, uid: 1, relaunch: {}).commands is RecordingCommands)
    }

    @Test("the guard refuses everything outside Alfie's reach", arguments: [
        "", ".claude", ".claude/settings.json", ".codex", "Library/Keychains",
        "Library/Keychains/login.keychain-db", "Moe-backup-2026-09-07", "Moe-backup-2026-09-10-1230/x",
        "Library/Application Support", "Library", "Library/Application Support/Moe Dev",
    ])
    func guardRefuses(relative: String) throws {
        let fake = try FakeHome()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 1, relaunch: {})
        #expect(erase.refusal(for: relative.isEmpty ? fake.home : fake.url(relative)) != nil)
        #expect(erase.refusal(for: URL(fileURLWithPath: "/")) != nil)
        #expect(erase.refusal(for: fake.root) != nil)
    }

    @Test("and for Alfie Dev, Alfie's home and everything shared", arguments: [
        "Library/Application Support/Moe", "Library/Application Support/Moe/memory",
        ".hermes", ".hermes/.env", "Library/Application Support/FluidAudio", ".cache/fluidaudio",
    ])
    func devGuardRefuses(relative: String) throws {
        let fake = try FakeHome()
        let s = try scope(fake, MacEraseIdentity.devBundleID)
        let erase = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 1, relaunch: {})
        #expect(erase.refusal(for: fake.url(relative)) != nil)
        #expect(erase.refusal(for: fake.url("Library/Application Support/Moe Dev")) == nil)
    }

    @Test("a plan item the guard would refuse is refused again at deletion")
    func refusedAtDeletion() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 1, relaunch: {})
        let forged = MacErasePlan(scope: s, remove: [.path(fake.url(".claude"), why: "forged"),
                                                     .path(fake.url("Moe-backup-2026-09-10-1230"), why: "forged"),
                                                     .keychain(.init(service: "Claude Code-credentials", account: nil, source: "forged")),
                                                     .launchd(label: "com.moe.worktree-snapshot",
                                                              plist: fake.url("Library/LaunchAgents/com.moe.worktree-snapshot.plist"),
                                                              loaded: true),
                                                     .tcc(bundleID: "com.apple.Terminal")], left: [])
        let report = erase.run(forged)
        #expect(report.failures.count == 5, "\(report.text)")
        for kept in FakeHome.survivors { #expect(fake.exists(kept)) }
    }

    @Test("the launchd lists are explicit, and the snapshot net is on neither")
    func labels() {
        let release = MacEraseIdentity(bundleID: MacEraseIdentity.releaseBundleID)!
        let dev = MacEraseIdentity(bundleID: MacEraseIdentity.devBundleID)!
        #expect(!release.launchdLabels.contains("com.moe.worktree-snapshot"))
        #expect(!dev.launchdLabels.contains("com.moe.worktree-snapshot"))
        // Launchd.jobsLabel (Sources/Moe/MainWindow.swift): "com.moe.jobs"
        // for Moe, bundle id + ".jobs" for anything else.
        #expect(release.launchdLabels.first == "com.moe.jobs")
        #expect(dev.launchdLabels == ["com.memoe.app.dev.jobs"])
        #expect(Set(release.launchdLabels).isDisjoint(with: dev.launchdLabels))
    }
}

// MARK: - A real keychain file

/// A throwaway keychain in the fake home, and a `security` wrapper that
/// refuses any call not aimed at it.
final class ThrowawayKeychain {
    let file: URL
    let wrapper: URL
    let violations: URL

    init(in fake: FakeHome) throws {
        file = fake.root.appendingPathComponent("erase-test.keychain-db")
        violations = fake.root.appendingPathComponent("violations.log")
        wrapper = fake.root.appendingPathComponent("security-guard.sh")
        let script = """
        #!/bin/sh
        # Refuse any keychain call whose last argument is not the throwaway file.
        for last in "$@"; do :; done
        if [ "$last" != '\(file.path)' ]; then
          echo "$*" >> '\(violations.path)'
          exit 97
        fi
        exec /usr/bin/security "$@"
        """
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        try Self.security(["create-keychain", "-p", "erase-test", file.path])
        try Self.security(["unlock-keychain", "-p", "erase-test", file.path])
    }

    deinit { _ = try? Self.security(["delete-keychain", file.path]) }

    @discardableResult
    static func security(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func add(_ service: String, _ account: String) throws {
        let rc = try Self.security(["add-generic-password", "-s", service, "-a", account, "-w", "secret", file.path])
        precondition(rc == 0, "could not add \(service) to the throwaway keychain")
    }

    func has(_ service: String, _ account: String) -> Bool {
        (try? Self.security(["find-generic-password", "-s", service, "-a", account, file.path])) == 0
    }

    var violationLines: [String] {
        ((try? String(contentsOf: violations, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

@Suite("MacErase and a real keychain file", .serialized)
struct MacEraseKeychainFileTests {

    @Test("Alfie's items go from the throwaway keychain; everything else in it stays")
    func throwaway() throws {
        let fake = try FakeHome()
        let kc = try ThrowawayKeychain(in: fake)
        for (s, a) in [("moe-child-oauth", "moe"), ("moe-composio-scoped", "api-key"), ("moe-telegram-bot", "bot"),
                       ("moe-gmail", "a@example.com"), ("moe-gmail", "b@example.com"),
                       ("Claude Code-credentials", "me"), ("https://sparkle-project.org", "ed25519"),
                       ("com.other.app", "token"), ("assemblyai-api-key", "not-moe")] {
            try kc.add(s, a)
        }
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let keychain = SecurityToolKeychain(bin: kc.wrapper.path, keychainFile: kc.file)
        let erase = MacErase(scope: s, keychain: keychain, commands: Recorder(), uid: 1, relaunch: {})
        let plan = erase.plan()
        let planned = plan.remove.compactMap { item -> String? in
            if case .keychain(let e) = item { return e.service }; return nil
        }
        #expect(Set(planned) == ["moe-child-oauth", "moe-composio-scoped", "moe-telegram-bot", "moe-gmail"])
        let report = erase.run(plan)
        #expect(report.ok, "\(report.text)")
        #expect(kc.violationLines.isEmpty, "a keychain call escaped the throwaway file: \(kc.violationLines)")

        for (s, a) in [("moe-child-oauth", "moe"), ("moe-composio-scoped", "api-key"), ("moe-telegram-bot", "bot"),
                       ("moe-gmail", "a@example.com"), ("moe-gmail", "b@example.com")] {
            #expect(!kc.has(s, a), "\(s) survived")
        }
        for (s, a) in [("Claude Code-credentials", "me"), ("https://sparkle-project.org", "ed25519"),
                       ("com.other.app", "token"), ("assemblyai-api-key", "not-moe")] {
            #expect(kc.has(s, a), "\(s)/\(a) — not Alfie's — was deleted")
        }
    }

    @Test("the wrapper really refuses a call without the keychain file — the guard can fail")
    func wrapperCanFail() throws {
        let fake = try FakeHome()
        let kc = try ThrowawayKeychain(in: fake)
        // Aimed at the search list (keychainFile nil), through the wrapper:
        // refused before /usr/bin/security runs, and recorded.
        let unscoped = SecurityToolKeychain(bin: kc.wrapper.path, keychainFile: nil)
        let result = unscoped.deleteAll(.init(service: "moe-erase-test-never-exists", account: "x", source: "test"))
        guard case .failure = result else {
            Issue.record("an unscoped delete got past the wrapper")
            return
        }
        #expect(kc.violationLines.count == 1)
    }
}
