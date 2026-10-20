import Foundation

/// The browsers Hermes drives, told apart from every other browser on the Mac
/// by the one thing that is theirs: a `--user-data-dir` under
/// `<hermes home>/browser-profile/`.
///
/// Why Moe sweeps them itself. Hermes closes its driven browser when it exits
/// cleanly, and its next start reaps one whose owner died. But Moe stops the
/// gateway with SIGTERM and, five seconds later, SIGKILL — and the driven
/// browser starts in its own session, outside the gateway's process group, so
/// the kill never reaches it. Between Moe quitting and the next gateway start
/// (a reboot, a day) that browser is alive with nobody to close it. Until
/// 2026-09-20 it was also a hidden second instance of the person's own
/// Chrome, and Launch Services counted it as *Chrome*: their browser would
/// neither open nor quit for as long as it lived — once, for four days.
///
/// The match is on the argument, never on a process name: the person's
/// browser carries no `--user-data-dir` under Moe's home and can never
/// qualify. Helper processes (`--type=renderer`, `gpu-process`, …) are left
/// out; they exit with the browser process that owns them.
public enum DrivenBrowsers {

    /// Process ids of driven browsers in a `ps -axo pid=,command=` table.
    public static func pids(inProcessTable table: String, hermesHome: String) -> [Int32] {
        let root = hermesHome.hasSuffix("/") ? hermesHome : hermesHome + "/"
        let marker = "--user-data-dir=" + root + "browser-profile/"
        var found: [Int32] = []
        for rawLine in table.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains(marker), !line.contains("--type=") else { continue }
            let pidText = line.prefix { $0.isNumber }
            guard let pid = Int32(pidText), pid > 1 else { continue }
            found.append(pid)
        }
        return found
    }
}
