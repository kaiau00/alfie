import AppKit
import Foundation
import MoeErase
import Security
import ServiceManagement

/// D9.12 — Erase Memoe from this Mac, the app half. The engine is `MacErase`
/// in `Sources/MoeErase`; this file is the only place the real machine is
/// handed to it.
///
/// **Why the erase runs in a second process, after the app has quit.** A Moe
/// that is running writes its home constantly — the log, a conversation
/// flushed on quit, config saved by `shutDown` — and its Hermes gateway runs
/// out of `~/.hermes`. An erase done in-process would race all of them, and
/// the one write that lands after it (config.json) is exactly the file whose
/// absence sends the next launch to onboarding. So the app starts
/// `Moe --erase-mac` as its own child, hands it a request down a pipe, waits
/// for the child to answer "armed", and quits normally; the child waits
/// until the app is gone, stops anything still running from the homes,
/// erases, and opens the app again.
///
/// **Why the child checks its parent, and takes no arguments.** This Mac runs
/// agents that read main.swift and run binaries, and Hermes runs a shell on
/// the person's behalf. The first version took a ticket FILE, and
/// `Moe --erase-mac <path>` deleted whatever path it was given before it
/// read it (the review, 2026-09-11). Now there is nothing to name: the
/// request arrives on stdin, which must be a pipe; the pid in it must be the
/// child's own parent; and that parent's code must satisfy this app's own
/// designated requirement. A shell or a script that runs the binary is the
/// parent in that case, and is not Moe. Hermes's shell gate also refuses the
/// flag outright (`*--erase-mac*` in configure-hermes.py's GATE_DENY_GLOBS).
enum MacEraseRun {

    static let quitWait: TimeInterval = 120
    static let ackWait: TimeInterval = 15

    // MARK: - Scope

    /// The scope for this app, resolved the way `Config.homeDir` is and then
    /// required to agree with it: an erase aimed anywhere but the home this
    /// app actually uses is refused.
    static func scope() throws -> MacEraseScope {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let scope = try MacEraseScope.resolve(
            bundleID: Bundle.main.bundleIdentifier,
            infoMoeHome: Bundle.main.object(forInfoDictionaryKey: "MoeHome") as? String,
            environment: ProcessInfo.processInfo.environment,
            realUserHome: FileManager.default.homeDirectoryForCurrentUser,
            // Where CuaDriver is. Only Moe removes it; the engine decides.
            applications: MacEraseCuaDriver.systemApplications,
            debugBuild: debug)
        guard scope.moeHome.standardizedFileURL.path == Config.homeDir.standardizedFileURL.path else {
            throw MacEraseScopeError("the erase resolved \(scope.moeHome.path), but this Moe's home is "
                                     + "\(Config.homeDir.path); refused")
        }
        return scope
    }

    static func engine(_ scope: MacEraseScope) -> MacErase {
        MacErase.standard(scope: scope, uid: getuid(), loginItem: SystemLoginItem(), relaunch: { reopen() })
    }

    /// Exactly what would go, for the second warning. Deletes nothing.
    static func plan() throws -> MacErasePlan {
        let s = try scope()
        return engine(s).plan()
    }

    /// Open this same app bundle again. The home is gone, so `FirstRun`
    /// finds no config.json and the launch goes to onboarding.
    private static func reopen() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", bundle.path]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - After the relaunch

    /// Whether this launch must hold off installing CuaDriver: an erase
    /// removed it and setup has not been finished since (MacEraseNote).
    /// HermesConfigure reads this; without it the fresh Moe put CuaDriver
    /// back one minute after the owner's erase (2026-09-11).
    static var holdsDriverInstall: Bool {
        MacEraseNote.holdsDriverInstall(MacEraseNote.read(from: Config.homeDir), onboarded: Onboarding.done)
    }
    static let skipDriverEnv = MacEraseNote.skipDriverEnv

    // MARK: - From the app

    /// After both warnings and the proof of identity (Google, or Touch ID /
    /// the login password): start the child, wait for it to accept, quit.
    /// Throws — and the app stays up — if the child refuses or does not answer.
    ///
    /// TODO(slice G): the buttons that reach this — "Erase this Mac" and
    /// "Delete my account" in PrivacyDangerZone.swift — become HumanOnlyButton,
    /// so only a person-made event can press them; an accessibility-driven or
    /// synthesized click must not be able to start this.
    static func eraseAfterQuit() async throws {
        let s = try scope()
        try await Task.detached(priority: .userInitiated) { try spawnHelper(scope: s) }.value
        await MainActor.run {
            Log.write("erase: the person confirmed Erase Memoe from this Mac; the eraser accepted; quitting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    /// Start `Moe --erase-mac` as this process's child and hand it the
    /// request down its stdin. Returns once it has answered `armed <nonce>`.
    static func spawnHelper(scope: MacEraseScope) throws {
        guard let exe = Bundle.main.executableURL else { throw MacEraseScopeError("no executable to run") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MacEraseScopeError("no randomness for the request")
        }
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        let request = MacEraseRequest(nonce: nonce, bundleID: scope.identity.bundleID,
                                      moeHome: scope.moeHome.path, pid: getpid())
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--erase-mac"]
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        input.fileHandleForWriting.write(line)
        try? input.fileHandleForWriting.close()

        let answer = readAll(output.fileHandleForReading, within: ackWait)
        let text = String(decoding: answer ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == "armed \(nonce)" else {
            if p.isRunning { p.terminate() }
            let why = String(decoding: readAll(errors.fileHandleForReading, within: 2) ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacEraseScopeError("the eraser would not start: \(why.isEmpty ? "no answer" : why)")
        }
    }

    private final class Box: @unchecked Sendable { var data: Data? }

    private static func readAll(_ handle: FileHandle, within: TimeInterval) -> Data? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = handle.readDataToEndOfFile()
            done.signal()
        }
        return done.wait(timeout: .now() + within) == .success ? box.data : nil
    }

    // MARK: - The parent's code

    /// Does the process `pid` satisfy this binary's own designated
    /// requirement? For a release that is "identifier com.memoe.app and
    /// our certificate"; for an ad-hoc debug build it is its cdhash — the
    /// same binary. A shell, python, or any other program fails it.
    static func parentIsThisApp(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        var myStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(myStatic, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var parent: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess,
              let parent else { return false }
        return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
    }

    // MARK: - The child process

    /// `Moe --erase-plan`, `Moe --erase-mac`, and (DEBUG, scratch only)
    /// `Moe --erase-mac-spawn`, from main.swift before anything there can
    /// touch the home. Never calls `Log`: the log lives in the home being
    /// removed.
    static func main(_ args: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        switch args[1] {
        case "--erase-plan":
            do {
                print(try plan().json())
                exit(0)
            } catch {
                fail("erase-plan: \(error)", code: 2)
            }
        case "--erase-mac-spawn":
            // The app's half, without the app: for scripts/test-privacy-erase.sh,
            // which needs a parent that IS this binary. Debug builds only, and
            // only against a scratch home.
            #if DEBUG
            do {
                let s = try scope()
                guard s.scratch else { fail("erase-mac-spawn: only against a scratch home", code: 2) }
                try spawnHelper(scope: s)
                print("spawned")
                exit(0)
            } catch {
                fail("erase-mac-spawn: \(error)", code: 2)
            }
            #else
            fail("erase-mac-spawn: not in this build", code: 64)
            #endif
        default:
            child(args)
        }
    }

    private static func child(_ args: [String]) -> Never {
        // Nothing on the command line. A path here is the old ticket
        // interface, and the whole of what was wrong with it: it deleted what
        // it was handed. Refused, and nothing named is touched.
        guard args.count == 2 else { fail("erase-mac: takes no arguments; nothing erased", code: 64) }
        var st = stat()
        let isPipe = fstat(0, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO
        guard isPipe else { fail("erase-mac: the request must come from the app through a pipe; nothing erased", code: 2) }
        guard let line = readRequestLine(),
              let request = try? JSONDecoder().decode(MacEraseRequest.self, from: line) else {
            fail("erase-mac: no request from the app; nothing erased", code: 2)
        }
        let parent = getppid()
        let s: MacEraseScope
        do { s = try scope() } catch { fail("erase-mac: nothing erased — \(error)", code: 2) }
        let parentOK = request.pid > 1 && request.pid == parent && parentIsThisApp(pid: parent)
        if let why = MacEraseRequest.refusal(request, scope: s, parentPID: parent,
                                             stdinIsPipe: isPipe, parentIsThisApp: parentOK) {
            fail("erase-mac: nothing erased — \(why)", code: 3)
        }
        // The answer the app quits on. Then nothing more is written to the
        // app's pipes: it is about to be gone.
        FileHandle.standardOutput.write(Data("armed \(request.nonce)\n".utf8))
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 { dup2(null, 1); dup2(null, 2) }

        let deadline = Date().addingTimeInterval(quitWait)
        while kill(request.pid, 0) == 0, getppid() == request.pid {
            guard Date() < deadline else { exit(3) }   // the app did not quit: nothing erased
            usleep(200_000)
        }
        let report = engine(s).eraseAndRelaunch()
        if s.scratch, let record = s.recordFile, let handle = try? FileHandle(forWritingTo: record) {
            handle.seekToEndOfFile()
            handle.write(Data("REPORT\t\(report.ok ? "ok" : "failed")\n\(report.text)\n".utf8))
            try? handle.close()
        }
        NSLog("Moe erase (%@): %ld items, %ld not removed",
              s.identity.bundleID, report.outcomes.count, report.failures.count)
        exit(report.ok ? 0 : 1)
    }

    /// One line from stdin, at most 4 KB.
    private static func readRequestLine() -> Data? {
        var data = Data()
        while data.count < 4096 {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.contains(0x0A) { break }
        }
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        return data.prefix(upTo: newline)
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}

/// The login item the erase takes out: this app, as macOS has it registered.
/// What `LoginItem.set(false)` does, without `Log.write` — the erase runs
/// after the home, and the log in it, are about to go, and a log line written
/// mid-erase would put a folder back. Moe Dev never registers
/// (`LoginItem.isDeveloperBuild`), so for it this finds nothing to remove.
struct SystemLoginItem: MacEraseLoginItem {
    func isRegistered() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
    func unregister() -> String? {
        do {
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
