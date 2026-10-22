import Foundation
import Testing
@testable import MoeErase

// The review's findings on slice F (2026-09-11), each as a rule that fails on
// the mutation it names. Everything runs against a temporary home (FakeHome,
// MacEraseTests.swift) and fake process tables — no real process is listed
// or signalled here; scripts/test-privacy-erase.sh does that, inside a
// scratch home, with processes it started itself.

// MARK: - Who may start an erase (findings 1 and 2)

@Suite("The erase request")
struct MacEraseRequestTests {

    func fixture() throws -> (FakeHome, MacEraseScope, MacEraseRequest) {
        let fake = try FakeHome()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let r = MacEraseRequest(nonce: String(repeating: "ab", count: 32), bundleID: s.identity.bundleID,
                                moeHome: s.moeHome.path, pid: 4242)
        return (fake, s, r)
    }

    @Test("a request from the app, through a pipe, from its parent, is accepted")
    func accepted() throws {
        let (_, s, r) = try fixture()
        #expect(MacEraseRequest.refusal(r, scope: s, parentPID: 4242, stdinIsPipe: true, parentIsThisApp: true) == nil)
    }

    @Test("M4: pid 0 or 1 — the kernel or launchd as the 'app' — is refused", arguments: [Int32(0), 1, -1])
    func noParent(pid: Int32) throws {
        let (_, s, r0) = try fixture()
        let r = MacEraseRequest(nonce: r0.nonce, bundleID: r0.bundleID, moeHome: r0.moeHome, pid: pid)
        #expect(MacEraseRequest.refusal(r, scope: s, parentPID: pid, stdinIsPipe: true, parentIsThisApp: true) != nil)
    }

    @Test("M6: a parent that is not this app is refused — a shell, a script, an agent")
    func parentNotTheApp() throws {
        let (_, s, r) = try fixture()
        #expect(MacEraseRequest.refusal(r, scope: s, parentPID: 4242, stdinIsPipe: true, parentIsThisApp: false) != nil)
    }

    @Test("a request naming a pid that is not the parent is refused")
    func notTheParent() throws {
        let (_, s, r) = try fixture()
        #expect(MacEraseRequest.refusal(r, scope: s, parentPID: 999, stdinIsPipe: true, parentIsThisApp: true) != nil)
    }

    @Test("not through a pipe — a file, a terminal — is refused")
    func notAPipe() throws {
        let (_, s, r) = try fixture()
        #expect(MacEraseRequest.refusal(r, scope: s, parentPID: 4242, stdinIsPipe: false, parentIsThisApp: true) != nil)
    }

    @Test("no nonce, another identity, or another home is refused")
    func wrongContents() throws {
        let (fake, s, r) = try fixture()
        let bad = [
            MacEraseRequest(nonce: "", bundleID: r.bundleID, moeHome: r.moeHome, pid: r.pid),
            MacEraseRequest(nonce: r.nonce, bundleID: MacEraseIdentity.devBundleID, moeHome: r.moeHome, pid: r.pid),
            MacEraseRequest(nonce: r.nonce, bundleID: r.bundleID,
                            moeHome: fake.url("Library/Application Support/Moe Dev").path, pid: r.pid),
            MacEraseRequest(nonce: r.nonce, bundleID: r.bundleID, moeHome: fake.url("Documents").path, pid: r.pid),
        ]
        for request in bad {
            #expect(MacEraseRequest.refusal(request, scope: s, parentPID: 4242, stdinIsPipe: true,
                                            parentIsThisApp: true) != nil, "accepted: \(request)")
        }
    }
}

// MARK: - Stopping what runs from the homes (finding 8)

final class FakeProcessTable: MacEraseProcessTable {
    var table: [MacEraseProcess]
    var living: Set<Int32>
    /// Pids that ignore SIGTERM and need SIGKILL.
    var stubborn: Set<Int32> = []
    var signals: [(Int32, Int32)] = []

    init(_ table: [MacEraseProcess]) {
        self.table = table
        living = Set(table.map(\.pid))
    }
    func list() -> [MacEraseProcess] { table.filter { living.contains($0.pid) } }
    /// Pids that exit on SIGTERM and are at once reused by another program:
    /// the entry is replaced, and the pid stays alive.
    var reuseOnTerm: [Int32: MacEraseProcess] = [:]

    func signal(_ pid: Int32, _ signal: Int32) -> Bool {
        signals.append((pid, signal))
        if signal == SIGTERM, let next = reuseOnTerm[pid] {
            table.removeAll { $0.pid == pid }
            table.append(next)
            living.insert(pid)
            return true
        }
        if signal == SIGKILL || !stubborn.contains(pid) { living.remove(pid) }
        return true
    }
    func alive(_ pid: Int32) -> Bool { living.contains(pid) }
}

@Suite("Stopping what runs from what is erased")
struct MacEraseProcessTests {
    let me: UInt32 = 501

    func table(_ fake: FakeHome) -> [MacEraseProcess] {
        let hermes = fake.url(".hermes").path, moe = fake.url("Library/Application Support/Moe").path
        return [
            .init(pid: 100, uid: me, executable: hermes + "/python/bin/python3.11", cwd: "/",
                  arguments: ["python3.11", "-m", "hermes", "gateway"]),                    // exe inside ~/.hermes
            .init(pid: 101, uid: me, executable: "/opt/uv/python3", cwd: "/",
                  arguments: ["python3", hermes + "/hermes-agent/run.py"]),                // a path argument
            .init(pid: 102, uid: me, executable: "/usr/bin/env", cwd: "/",
                  environment: ["HERMES_HOME": hermes]),                                    // HERMES_HOME
            .init(pid: 103, uid: me, executable: "/bin/sleep", cwd: moe + "/logs"),          // cwd in Moe's home
            .init(pid: 104, uid: me, executable: "/bin/zsh", cwd: hermes),                   // a person's shell
            .init(pid: 105, uid: me, executable: "/usr/local/bin/hermes", cwd: "/tmp",
                  arguments: ["hermes", "chat"]),                                           // named hermes, elsewhere
            .init(pid: 106, uid: 0, executable: hermes + "/python/bin/python3.11", cwd: "/"), // another user
            .init(pid: 1, uid: me, executable: hermes + "/x", cwd: "/"),                    // launchd's pid
            .init(pid: 107, uid: me, executable: hermes + "/python/bin/python3.11", cwd: "/"), // the helper itself
            .init(pid: 108, uid: me, executable: fake.url("Library/Application Support/Moe Dev/bin/x").path, cwd: "/"),
        ]
    }

    @Test("matched by what they are and where they run, never by name; never another user, pid 1 or itself")
    func matching() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: me,
                             processes: FakeProcessTable(table(fake)), selfPID: 107, relaunch: {})
        let (stop, shells) = erase.processesToStop(table(fake))
        #expect(Set(stop.map(\.pid)) == [100, 101, 102, 103])
        #expect(shells.map(\.pid) == [104], "a shell open in the home is named, not killed")
    }

    @Test("Alfie Dev stops only what runs from its own home — never the shared Hermes")
    func devMatching() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.devBundleID)
        let erase = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: me,
                             processes: FakeProcessTable(table(fake)), selfPID: 107, relaunch: {})
        #expect(erase.processesToStop(table(fake)).stop.map(\.pid) == [108])
    }

    @Test("stopped before anything is removed: SIGTERM, then SIGKILL for what ignores it")
    func stopped() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let procs = FakeProcessTable(table(fake))
        procs.stubborn = [101]
        var erase = MacErase(scope: s, keychain: MemoryKeychain([]), commands: Recorder(), uid: me,
                             processes: procs, selfPID: 107, relaunch: {})
        erase.stopWait = 0.3
        let plan = erase.plan()
        let planned = plan.remove.compactMap { item -> Int32? in
            if case .process(let pid, _) = item { return pid }; return nil
        }
        #expect(Set(planned) == [100, 101, 102, 103])
        let report = erase.run(plan)
        #expect(report.ok, "\(report.text)")
        #expect(procs.living == [104, 105, 106, 1, 107, 108].reduce(into: Set<Int32>()) { $0.insert($1) })
        #expect(procs.signals.contains { $0 == (101, SIGKILL) })
        #expect(!procs.signals.contains { $0.0 == 104 || $0.0 == 105 || $0.0 == 106 || $0.0 == 1 || $0.0 == 107 })
        // Stopped first: the process outcomes come before every removal.
        let firstRemoval = report.outcomes.firstIndex { if case .process = $0.0 { return false }; return true } ?? 0
        let lastProcess = report.outcomes.lastIndex { if case .process = $0.0 { return true }; return false } ?? 0
        #expect(lastProcess < firstRemoval)
    }
}

// MARK: - The shared keychain name (finding 5) and what stays (finding 9)

@Suite("Shared names and what stays")
struct MacEraseSharedTests {

    @Test("only Alfie may touch the keychain names Alfie and Alfie Dev share")
    func sharedKeychain() {
        #expect(MacEraseIdentity.mayTouchSharedKeychain(bundleID: MacEraseIdentity.releaseBundleID))
        #expect(!MacEraseIdentity.mayTouchSharedKeychain(bundleID: MacEraseIdentity.devBundleID))
        #expect(!MacEraseIdentity.mayTouchSharedKeychain(bundleID: nil))
        #expect(!MacEraseIdentity.mayTouchSharedKeychain(bundleID: "com.memoe.app.beta"))
    }

    @Test("~/.local/share/uv and Claude Code (~/.claude, ~/.local/bin/claude) are named as staying, and never removed")
    func whatStays() throws {
        let fake = try FakeHome()
        try fake.populate()
        try fake.file(".local/share/uv/python/cpython-3.11/bin/python3")
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let erase = MacErase(scope: s, keychain: MemoryKeychain([]), commands: Recorder(), uid: 1, relaunch: {})
        let plan = erase.plan()
        #expect(plan.left.contains { $0.contains("~/.local/share/uv") })
        #expect(plan.left.contains { $0.contains("~/.local/bin/claude") && $0.contains("~/.claude") })
        #expect(erase.run(plan).ok)
        #expect(fake.exists(".local/share/uv/python/cpython-3.11/bin/python3"))
        #expect(fake.exists(".local/bin/claude"))
        #expect(erase.refusal(for: fake.url(".local/bin/claude")) != nil)
    }
}

// MARK: - CuaDriver goes with Moe (the owner's decision, 2026-09-11)

/// The file removals, recorded and then done — so a test can say what the
/// erase tried to remove, not only what is missing afterwards.
/// A signature reader that answers what it is told, so no test needs the
/// real CuaDriver. `trycua` is what the real app measured on 2026-09-11.
struct FakeSigner: MacEraseSignatureCheck {
    let answer: MacEraseSigner?
    static let trycua = FakeSigner(answer: .init(identifier: "com.trycua.driver", team: "YCK386LBJ7"))
    func signer(of app: URL) -> MacEraseSigner? { answer }
}

final class RecordingFiles: MacEraseFileOps {
    var removed: [String] = []
    func removeItem(at url: URL) throws {
        removed.append(url.path)
        try FileManager.default.removeItem(at: url)
    }
}

@Suite("CuaDriver goes with Alfie, and never with Alfie Dev")
struct MacEraseCuaDriverTests {
    static let data = [".cua-driver", "Library/Caches/cua-driver", "Library/Caches/CuaDriver",
                       "Library/Application Support/CuaDriver"]

    func release(_ fake: FakeHome, _ rec: Recorder = Recorder(), files: MacEraseFileOps = LocalFileOps(),
                 processes: MacEraseProcessTable? = nil,
                 signature: MacEraseSignatureCheck = FakeSigner.trycua) throws -> MacErase {
        MacErase(scope: try scope(fake, MacEraseIdentity.releaseBundleID), keychain: MemoryKeychain([]),
                 commands: rec, uid: 501, processes: processes, selfPID: 107, files: files,
                 signature: signature, relaunch: {})
    }

    static func isApp(_ item: MacEraseItem) -> Bool { item.kind == "app" }

    @Test("Alfie's erase removes the app, its command, its data and its permissions — permissions first")
    func releaseRemoves() throws {
        let fake = try FakeHome()
        try fake.populate()
        try fake.cuaDriver()
        try fake.cuaDriverData()
        try fake.file("Library/Preferences/com.trycua.driver.plist")
        let rec = Recorder()
        let erase = try release(fake, rec)
        let plan = erase.plan()
        #expect(plan.remove.contains { Self.isApp($0) && $0.target == fake.url("Applications/CuaDriver.app").path })
        #expect(!plan.left.contains { $0.contains("CuaDriver") }, "\(plan.left)")
        let report = erase.run(plan)
        #expect(report.ok, "\(report.text)")
        for gone in ["Applications/CuaDriver.app", ".local/bin/cua-driver",
                     "Library/Preferences/com.trycua.driver.plist"] + Self.data {
            #expect(!fake.exists(gone), "\(gone) survived Alfie's erase")
        }
        for kept in FakeHome.survivors { #expect(fake.exists(kept), "\(kept) was removed") }
        // tccutil finds an app by its bundle id, so CuaDriver's permissions
        // are reset while it is still there to be found.
        #expect(rec.calls.contains(["/usr/bin/tccutil", "reset", "All", "com.trycua.driver"]))
        #expect(rec.calls.contains(["/usr/bin/defaults", "delete", "com.trycua.driver"]))
        let tcc = report.outcomes.firstIndex { $0.0 == .tcc(bundleID: MacEraseCuaDriver.bundleID) }
        let app = report.outcomes.firstIndex { Self.isApp($0.0) }
        #expect(tcc != nil && app != nil && tcc! < app!, "\(report.text)")
    }

    @Test("Alfie Dev leaves CuaDriver alone, says so, and refuses a forged plan for it")
    func devLeaves() throws {
        let fake = try FakeHome()
        try fake.populate()
        let app = try fake.cuaDriver()
        try fake.cuaDriverData()
        let exe = app.appendingPathComponent("Contents/MacOS/cua-driver").path
        let rec = Recorder()
        let table = FakeProcessTable([.init(pid: 200, uid: 501, executable: exe, cwd: "/")])
        // A genuinely signed CuaDriver, so the only thing that can refuse it
        // is that this is Moe Dev (with the real codesign the stand-in would
        // be refused for its signature, and the identity gate never tested).
        let dev = MacErase(scope: try scope(fake, MacEraseIdentity.devBundleID), keychain: nil, commands: rec,
                           uid: 501, processes: table, selfPID: 107, signature: FakeSigner.trycua, relaunch: {})
        let plan = dev.plan()
        // The reason, not a refusal: Moe Dev never looks at CuaDriver at
        // all, so nothing of it may appear as "Not removed" — that line
        // would mean the plan asked and a later guard said no.
        #expect(plan.left.contains { $0.contains("CuaDriver") && $0.contains("shared with Alfie") })
        #expect(!plan.left.contains { line in
            line.hasPrefix("Not removed") && ["CuaDriver", "cua-driver"].contains { line.contains($0) }
        }, "\(plan.left)")
        #expect(!plan.remove.contains { item in
            ["CuaDriver", "cua-driver", "trycua"].contains { item.target.contains($0) }
        }, "\(plan.json())")
        #expect(dev.run(plan).ok)
        let forged = dev.run(MacErasePlan(scope: plan.scope, remove: [
            .cuaDriverApp(app), .tcc(bundleID: MacEraseCuaDriver.bundleID),
            .path(fake.url(".cua-driver"), why: "forged"), .defaults(domain: MacEraseCuaDriver.bundleID),
        ], left: []))
        #expect(forged.failures.count == 4, "\(forged.text)")
        for kept in ["Applications/CuaDriver.app/Contents/Info.plist", ".local/bin/cua-driver"] + Self.data {
            #expect(fake.exists(kept), "\(kept) — shared with Alfie — was removed by Alfie Dev's erase")
        }
        #expect(!rec.anyCall(mentioning: "trycua"))
        #expect(table.living == [200], "Alfie Dev stopped the shared cua-driver")
    }

    @Test("a bundle at that path that is not com.trycua.driver is left, and named")
    func notTrycua() throws {
        for plistText in [nil, "x"] as [String?] {
            let fake = try FakeHome()
            try fake.populate()
            let app: URL
            if let plistText {   // not a plist at all
                app = try fake.file("Applications/CuaDriver.app/Contents/Info.plist", plistText)
                    .deletingLastPathComponent().deletingLastPathComponent()
            } else {
                app = try fake.cuaDriver(bundleID: "com.someone.else")
            }
            try fake.cuaDriverData()
            let rec = Recorder(), files = RecordingFiles()
            let erase = try release(fake, rec, files: files)
            let plan = erase.plan()
            #expect(!plan.remove.contains(where: Self.isApp))
            #expect(!plan.remove.contains { $0.target.hasSuffix(".local/bin/cua-driver") })
            #expect(plan.left.contains { $0.contains("CuaDriver.app") && $0.contains("Not removed") }, "\(plan.left)")
            _ = erase.run(plan)
            let forged = erase.run(MacErasePlan(scope: plan.scope, remove: [.cuaDriverApp(app)], left: []))
            #expect(!forged.ok)
            #expect(fake.exists("Applications/CuaDriver.app/Contents/Info.plist"))
            #expect(fake.exists(".local/bin/cua-driver"))
            #expect(!files.removed.contains { $0.contains("CuaDriver.app") }, "\(files.removed)")
            #expect(!rec.calls.contains(["/usr/bin/tccutil", "reset", "All", MacEraseCuaDriver.bundleID]))
        }
    }

    @Test("a CuaDriver.app that is a link is refused: neither the link nor what it points at is touched")
    func linkRefused() throws {
        let fake = try FakeHome()
        try fake.populate()
        let real = try fake.cuaDriver(at: "Elsewhere/CuaDriver.app")
        try FileManager.default.createDirectory(at: fake.url("Applications", dir: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fake.url("Applications/CuaDriver.app"), withDestinationURL: real)
        let rec = Recorder(), files = RecordingFiles()
        let erase = try release(fake, rec, files: files)
        let plan = erase.plan()
        #expect(!plan.remove.contains(where: Self.isApp))
        #expect(plan.left.contains { $0.contains("CuaDriver.app") && $0.contains("link") }, "\(plan.left)")
        _ = erase.run(plan)
        let forged = erase.run(MacErasePlan(scope: plan.scope,
                                            remove: [.cuaDriverApp(fake.url("Applications/CuaDriver.app"))], left: []))
        #expect(!forged.ok)
        #expect(fake.exists("Elsewhere/CuaDriver.app/Contents/Info.plist"))
        #expect(fake.exists("Elsewhere/CuaDriver.app/Contents/MacOS/cua-driver"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fake.url("Applications/CuaDriver.app").path)) != nil)
        #expect(!files.removed.contains { $0.contains("CuaDriver.app") }, "\(files.removed)")
        #expect(!rec.anyCall(mentioning: "trycua"))

        // A real folder whose Contents is a link: refused the same way.
        let fake2 = try FakeHome()
        let elsewhere = try fake2.cuaDriver(at: "Elsewhere/CuaDriver.app")
        try FileManager.default.createDirectory(at: fake2.url("Applications/CuaDriver.app", dir: true),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fake2.url("Applications/CuaDriver.app/Contents"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("Contents"))
        let erase2 = try release(fake2)
        #expect(!erase2.plan().remove.contains(where: Self.isApp))
        #expect(fake2.exists("Elsewhere/CuaDriver.app/Contents/MacOS/cua-driver"))
    }

    @Test("~/.local/bin/cua-driver goes only while it is a link into that app")
    func commandLink() throws {
        let fake = try FakeHome()
        try fake.populate()
        try fake.cuaDriver()
        try fake.file("opt/cua-driver", "someone else's")
        try FileManager.default.createDirectory(at: fake.url(".local/bin", dir: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fake.url(".local/bin/cua-driver"),
                                                   withDestinationURL: fake.url("opt/cua-driver"))
        let erase = try release(fake)
        let plan = erase.plan()
        #expect(erase.run(plan).ok)
        #expect(!fake.exists("Applications/CuaDriver.app"))
        #expect(fake.exists(".local/bin/cua-driver") && fake.exists("opt/cua-driver"))
        #expect(plan.left.contains { $0.contains("~/.local/bin/cua-driver") }, "\(plan.left)")
    }

    @Test("a running cua-driver is stopped first, matched by where its executable is — never by name")
    func processStopped() throws {
        let fake = try FakeHome()
        try fake.populate()
        let app = try fake.cuaDriver()
        let exe = app.appendingPathComponent("Contents/MacOS/cua-driver").path
        let table = FakeProcessTable([
            .init(pid: 200, uid: 501, executable: exe, cwd: "/", arguments: ["cua-driver", "serve"]),
            .init(pid: 201, uid: 501, executable: "/opt/elsewhere/cua-driver", cwd: "/", arguments: ["cua-driver", "serve"]),
            .init(pid: 202, uid: 0, executable: exe, cwd: "/"),
        ])
        var erase = try release(fake, processes: table)
        erase.stopWait = 0.2
        let plan = erase.plan()
        #expect(plan.remove.compactMap { item -> Int32? in
            if case .process(let pid, _) = item { return pid }; return nil
        } == [200])
        let report = erase.run(plan)
        #expect(report.ok, "\(report.text)")
        #expect(table.living == [201, 202])
        let stopped = report.outcomes.firstIndex { $0.0.kind == "process" }
        let removed = report.outcomes.firstIndex { Self.isApp($0.0) }
        #expect(stopped != nil && removed != nil && stopped! < removed!)
    }

    @Test("only <Applications>/CuaDriver.app, and only an Applications folder that is /Applications or inside ~")
    func exactPath() throws {
        let fake = try FakeHome()
        try fake.populate()
        let other = try fake.cuaDriver(at: "Applications/Other.app")
        let nested = try fake.cuaDriver(at: "Applications/Utilities/CuaDriver.app")
        let erase = try release(fake)
        let report = erase.run(MacErasePlan(scope: erase.scope, remove: [.cuaDriverApp(other), .cuaDriverApp(nested)],
                                            left: []))
        #expect(report.failures.count == 2, "\(report.text)")
        #expect(fake.exists("Applications/Other.app/Contents/Info.plist"))
        #expect(fake.exists("Applications/Utilities/CuaDriver.app/Contents/Info.plist"))
        for bad in [fake.root.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Users/Shared"),
                    URL(fileURLWithPath: "/")] {
            #expect(throws: MacEraseScopeError.self) {
                _ = try MacEraseScope.resolve(bundleID: MacEraseIdentity.releaseBundleID, infoMoeHome: nil,
                                              environment: [:], realUserHome: fake.home, applications: bad,
                                              debugBuild: false)
            }
        }
        // Resolution only — nothing is planned or run against these.
        let real = try MacEraseScope.resolve(bundleID: MacEraseIdentity.releaseBundleID, infoMoeHome: nil,
                                             environment: [:], realUserHome: fake.home,
                                             applications: MacEraseCuaDriver.systemApplications, debugBuild: false)
        #expect(real.applicationsDir?.path == "/Applications")
        let none = try MacEraseScope.resolve(bundleID: MacEraseIdentity.releaseBundleID, infoMoeHome: nil,
                                             environment: [:], realUserHome: fake.home, debugBuild: false)
        #expect(none.applicationsDir == nil, "a scope made without an Applications folder names no app")
    }

    // MARK: The review of 2026-09-11 — each test fails on the mutation it names.

    @Test("a scratch ~ that is /, or holds or sits inside the real home, is refused; its Applications is always its own")
    func scratchHomeApart() throws {
        let fake = try FakeHome()
        let real = FileManager.default.homeDirectoryForCurrentUser
        func resolve(_ userHome: String, _ moeHome: String, applications: URL? = nil) throws -> MacEraseScope {
            try MacEraseScope.resolve(bundleID: nil, infoMoeHome: nil,
                                      environment: ["MOE_HOME": moeHome, "MOE_ERASE_USER_HOME": userHome,
                                                    "MOE_ERASE_BUNDLE_ID": MacEraseIdentity.releaseBundleID],
                                      realUserHome: real, applications: applications, debugBuild: true)
        }
        // Each MOE_HOME is inside the scratch ~ it is given, so only the rule
        // under test can refuse. `resolve` only reads; nothing is created.
        let parent = real.deletingLastPathComponent()
        let inside = real.appendingPathComponent("moe-erase-test-never-created", isDirectory: true)
        #expect(throws: MacEraseScopeError.self) { _ = try resolve("/", fake.url("moe-home").path) }
        #expect(throws: MacEraseScopeError.self) {
            _ = try resolve(parent.path, parent.appendingPathComponent("moe-erase-test-never-created/moe").path)
        }
        #expect(throws: MacEraseScopeError.self) {
            _ = try resolve(inside.path, inside.appendingPathComponent("moe").path)
        }
        // Handed the real /Applications, a scratch run still names its own.
        let ok = try resolve(fake.home.path, fake.url("moe-home").path,
                             applications: MacEraseCuaDriver.systemApplications)
        #expect(ok.applicationsDir.map { MacErase.canonical($0).path }
                == MacErase.canonical(fake.url("Applications")).path)
    }

    @Test("the guard itself refuses an Applications folder that is neither /Applications nor inside ~")
    func guardRefusesForeignApplications() throws {
        let fake = try FakeHome()
        try fake.populate()
        // Outside the fake ~ — reachable only by a scope made by hand, since
        // resolve refuses it; the guard must refuse it on its own.
        let outside = fake.root.appendingPathComponent("Elsewhere/Applications", isDirectory: true)
        let app = try fake.cuaDriver(at: "../../Elsewhere/Applications/CuaDriver.app")
        let s = MacEraseScope(identity: MacEraseIdentity(bundleID: MacEraseIdentity.releaseBundleID)!,
                              userHome: fake.home, moeHome: fake.url("Library/Application Support/Moe", dir: true),
                              hermesHome: nil, keychain: .none, scratch: false, applicationsDir: outside)
        let rec = Recorder(), files = RecordingFiles()
        let erase = MacErase(scope: s, keychain: nil, commands: rec, uid: 501, files: files,
                             signature: FakeSigner.trycua, relaunch: {})
        let plan = erase.plan()
        #expect(!plan.removesCuaDriver)
        #expect(plan.left.contains { $0.contains("neither /Applications") }, "\(plan.left)")
        let forged = erase.run(MacErasePlan(scope: s, remove: [.cuaDriverApp(outside.appendingPathComponent("CuaDriver.app"))],
                                            left: []))
        #expect(!forged.ok)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
        #expect(!files.removed.contains { $0.contains("CuaDriver.app") })
        #expect(!rec.anyCall(mentioning: "trycua"))
    }

    @Test("an Info.plist that is a link is refused, even when what it points at says com.trycua.driver")
    func infoPlistLinkRefused() throws {
        let fake = try FakeHome()
        try fake.populate()
        let genuine = try fake.cuaDriver(at: "Elsewhere/CuaDriver.app")
        let app = try fake.cuaDriver()
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.removeItem(at: plist)
        try FileManager.default.createSymbolicLink(at: plist,
                                                   withDestinationURL: genuine.appendingPathComponent("Contents/Info.plist"))
        let rec = Recorder(), files = RecordingFiles()
        let erase = try release(fake, rec, files: files)
        let plan = erase.plan()
        #expect(!plan.removesCuaDriver)
        #expect(plan.left.contains { $0.contains("Info.plist") && $0.contains("link") }, "\(plan.left)")
        #expect(!erase.run(MacErasePlan(scope: plan.scope, remove: [.cuaDriverApp(app)], left: [])).ok)
        #expect(fake.exists("Applications/CuaDriver.app/Contents/MacOS/cua-driver"))
        #expect(fake.exists("Elsewhere/CuaDriver.app/Contents/Info.plist"))
        #expect(!files.removed.contains { $0.contains("CuaDriver.app") })
    }

    @Test("the command link is read again at removal: pointed elsewhere after the plan, it is left")
    func commandLinkRecheckedAtRemoval() throws {
        let fake = try FakeHome()
        try fake.populate()
        try fake.cuaDriver()
        try fake.cuaDriverData()
        try fake.file("opt/cua-driver", "someone else's")
        let rec = Recorder(), files = RecordingFiles()
        let erase = try release(fake, rec, files: files)
        let plan = erase.plan()
        #expect(plan.remove.contains { if case .cuaDriverLink = $0 { return true }; return false })
        // Between the plan and the run, the link is pointed at something else.
        let link = fake.url(".local/bin/cua-driver")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fake.url("opt/cua-driver"))
        let report = erase.run(plan)
        #expect(report.outcomes.contains { item, outcome in
            if case .cuaDriverLink = item, case .refused = outcome { return true }; return false
        }, "\(report.text)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == fake.url("opt/cua-driver").path)
        #expect(fake.exists("opt/cua-driver"))
        #expect(!files.removed.contains { $0.hasSuffix(".local/bin/cua-driver") })
    }

    @Test("a pid that now belongs to another program is never signalled — before SIGTERM, or before SIGKILL")
    func pidReuse() throws {
        let fake = try FakeHome()
        try fake.populate()
        let s = try scope(fake, MacEraseIdentity.releaseBundleID)
        let moe = fake.url("Library/Application Support/Moe").path
        let hermes = fake.url(".hermes").path

        // Before SIGTERM: the planned pid now runs another executable, still
        // from inside Moe's home — so only the executable can tell them apart.
        let t1 = FakeProcessTable([.init(pid: 300, uid: 501, executable: "/bin/sleep", cwd: moe + "/logs")])
        var e1 = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 501, processes: t1, selfPID: 107,
                          relaunch: {})
        e1.stopWait = 0.2
        #expect(e1.plan().remove.contains(.process(pid: 300, command: "/bin/sleep")))
        t1.table = [.init(pid: 300, uid: 501, executable: "/opt/other/tool", cwd: moe + "/logs")]
        _ = e1.stopProcesses([(300, "/bin/sleep")])
        #expect(t1.signals.isEmpty, "signalled a pid that is now another program: \(t1.signals)")

        // Before SIGKILL: it ignored nothing — it exited on SIGTERM and its
        // pid went at once to another program, which must not be killed.
        let python = hermes + "/python/bin/python3.11"
        let t2 = FakeProcessTable([.init(pid: 301, uid: 501, executable: python, cwd: "/")])
        t2.reuseOnTerm[301] = .init(pid: 301, uid: 501, executable: "/Applications/Other.app/Contents/MacOS/other",
                                    cwd: "/")
        var e2 = MacErase(scope: s, keychain: nil, commands: Recorder(), uid: 501, processes: t2, selfPID: 107,
                          relaunch: {})
        e2.stopWait = 0.2
        let out = e2.stopProcesses([(301, python)])
        #expect(!t2.signals.contains { $0 == (301, SIGKILL) }, "\(t2.signals)")
        #expect(t2.living.contains(301))
        #expect(out.first?.1.ok == true, "\(out)")
    }

    @Test("the warnings follow the plan: CuaDriver is named as going only when the plan removes it")
    func planSaysWhetherCuaDriverGoes() throws {
        let present = try FakeHome()
        try present.populate()
        try present.cuaDriver()
        #expect(try release(present).plan().removesCuaDriver)

        let absent = try FakeHome()
        try absent.populate()
        #expect(!(try release(absent).plan().removesCuaDriver), "nothing there to remove")

        let refused = try FakeHome()
        try refused.populate()
        try refused.cuaDriver()
        let otherTeam = FakeSigner(answer: .init(identifier: "com.trycua.driver", team: "ABCDE12345"))
        #expect(!(try release(refused, signature: otherTeam).plan().removesCuaDriver), "refused")

        let dev = try FakeHome()
        try dev.populate()
        try dev.cuaDriver()
        let devErase = MacErase(scope: try scope(dev, MacEraseIdentity.devBundleID), keychain: nil,
                                commands: Recorder(), uid: 501, signature: FakeSigner.trycua, relaunch: {})
        #expect(!devErase.plan().removesCuaDriver, "Alfie Dev")
    }

    @Test("CuaDriver must be signed by trycua: another team, another identifier, or no readable signature is refused")
    func signedByTrycua() throws {
        let refusedAnswers: [MacEraseSigner?] = [
            .init(identifier: "com.trycua.driver", team: "ABCDE12345"),
            .init(identifier: "com.trycua.driver", team: "not set"),
            .init(identifier: "com.someone.else", team: "YCK386LBJ7"),
            nil,
        ]
        for answer in refusedAnswers {
            let fake = try FakeHome()
            try fake.populate()
            let app = try fake.cuaDriver()
            let rec = Recorder(), files = RecordingFiles()
            let erase = try release(fake, rec, files: files, signature: FakeSigner(answer: answer))
            let plan = erase.plan()
            #expect(!plan.removesCuaDriver, "\(String(describing: answer))")
            #expect(!erase.run(MacErasePlan(scope: plan.scope, remove: [.cuaDriverApp(app)], left: [])).ok)
            #expect(fake.exists("Applications/CuaDriver.app/Contents/Info.plist"))
            #expect(!files.removed.contains { $0.contains("CuaDriver.app") })
            #expect(!rec.anyCall(mentioning: "trycua"))
        }
        // Both of Hermes's teams are CuaDriver.
        for team in ["4YEC26S9KF", "YCK386LBJ7"] {
            let fake = try FakeHome()
            try fake.populate()
            try fake.cuaDriver()
            let signed = FakeSigner(answer: .init(identifier: "com.trycua.driver", team: team))
            #expect(try release(fake, signature: signed).plan().removesCuaDriver, "\(team)")
        }
    }

    @Test("codesign -dv is read as Hermes reads it, and the real codesign refuses a stand-in")
    func codesignReading() throws {
        // `codesign -dv /Applications/CuaDriver.app` on this Mac, 2026-09-11
        // (read-only) — the two lines that decide it, as measured:
        let measured = "Identifier=com.trycua.driver\nTeamIdentifier=YCK386LBJ7\n"
        #expect(CodesignSignature.parse(measured) == MacEraseSigner(identifier: "com.trycua.driver", team: "YCK386LBJ7"))
        #expect(CodesignSignature.parse("Identifier=com.trycua.driver\n") == nil, "no team is no answer")
        // The real /usr/bin/codesign on a stand-in in the temp home — never
        // the real app: not signed by trycua, so not CuaDriver.
        let fake = try FakeHome()
        let app = try fake.cuaDriver()
        let signer = CodesignSignature().signer(of: app)
        #expect(signer.map { MacEraseCuaDriver.teamIDs.contains($0.team) } != true)
        let erase = MacErase(scope: try scope(fake, MacEraseIdentity.releaseBundleID), keychain: nil,
                             commands: Recorder(), uid: 501, relaunch: {})   // the default reader: real codesign
        #expect(erase.cuaDriverRefusal(app) != nil)
    }
}
