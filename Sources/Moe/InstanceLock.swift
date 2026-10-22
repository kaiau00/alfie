import AppKit
import Darwin
import MoeErase

/// One Moe at a time.
///
/// On 2026-09-02 a debug binary another tool had launched to render
/// screenshots booted the whole runtime beside the installed app. Both heard
/// the same sentence, transcribed it differently, opened two Hermes sessions
/// and answered out loud, one after the other. Nothing in macOS stops that:
/// LaunchServices only de-duplicates `open` of the same bundle, and a bare
/// `.build/debug/Moe` has no bundle at all.
///
/// So the runtime — the mic, the wake word, the brain — belongs to whoever
/// holds an exclusive `flock` on one file. The file lives under the real
/// home directory on purpose, not under `MOE_HOME`: a test that points
/// `MOE_HOME` at a scratch directory still shares this Mac's microphone
/// and this Mac's gateway, so it still has to lose to the app you use.
///
/// The lock is a kernel object on the open file: it goes away when the
/// process does, however it dies, so there is no stale lock to clean up.
/// `O_CLOEXEC` keeps the children Moe spawns (the gateway, `claude`) from
/// inheriting it and holding it after Moe has quit.
enum InstanceLock {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Moe/instance.lock")

    private static var fd: Int32 = -1

    /// This process holds the lock after the call. `false` means another
    /// process holds it; `holder` says which one when it can be read.
    /// A lock that cannot even be created (an unwritable home) yields to
    /// the app rather than refusing to launch it.
    @discardableResult
    static func acquire() -> Bool {
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let h = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard h >= 0 else { return true }
        guard flock(h, LOCK_EX | LOCK_NB) == 0 else {
            close(h)
            return false
        }
        _ = ftruncate(h, 0)
        let line = "\(getpid())\n"
        _ = line.withCString { write(h, $0, strlen($0)) }
        fd = h
        return true
    }

    /// Keeps trying for `seconds`: an updater relaunches the new build
    /// while the old one is still on its way out.
    static func acquire(waiting seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if acquire() { return true }
            if Date() >= deadline { return false }
            usleep(200_000)
        }
    }

    /// The pid the holder wrote, when readable.
    static var holder: pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid
    }

    /// The installed Moe outranks everything else holding this lock.
    ///
    /// The lock is shared on purpose — one microphone, one gateway, one wake
    /// word on this Mac — but "whoever got there first wins" turned out to
    /// be the wrong rule, and it was found the hard way. Moe Dev, or a build
    /// run out of a worktree, would take the lock at login and the app the
    /// owner actually uses would start, find it held, and quit. The log line
    /// for it is
    ///
    ///     another Moe is already running: /Applications/Memoe Dev.app; this one is quitting
    ///
    /// which reads like housekeeping and is in fact the user's Moe refusing
    /// to run on their own machine. Moe Dev exists so that testing costs the
    /// owner nothing; a workbench that evicts the real app is worse than no
    /// separation at all.
    ///
    /// So there is a rank. `/Applications/Memoe.app` takes the lock from
    /// anything that is not `/Applications/Memoe.app`, and everything else
    /// still yields the way it always did. It asks the holder to quit
    /// (`terminate`, not `kill`) so Moe Dev shuts its gateway down and lets
    /// go of the microphone rather than leaving both half-open.
    static func evictLesserHolder() -> Bool {
        guard Bundle.main.bundleIdentifier == MacEraseIdentity.releaseBundleID,
              Bundle.main.bundleURL.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: "/Applications/Memoe.app")
                    .resolvingSymlinksInPath().path
        else { return false }

        guard let pid = holder,
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        // Never evict another copy of the installed app: two of those is a
        // double launch, and the existing "bring the running one forward"
        // behaviour is right for it.
        if app.bundleURL?.resolvingSymlinksInPath().path
            == Bundle.main.bundleURL.resolvingSymlinksInPath().path { return false }

        Log.write("taking the lock from \(holderDescription): the installed Alfie outranks it")
        app.terminate()
        // Its gateway and audio take a moment to go. SIGKILL is deliberately
        // not the next step — a half-killed Moe Dev leaves the microphone
        // grabbed, and the point of this is to have a working Moe, not to
        // win a race.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if app.isTerminated { break }
            usleep(200_000)
        }
        return acquire(waiting: 3)
    }

    /// The holder as a description for a log line.
    static var holderDescription: String {
        guard let pid = holder else { return "another process" }
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path else {
            return "pid \(pid)"
        }
        return "\(bundle) (pid \(pid))"
    }
}
