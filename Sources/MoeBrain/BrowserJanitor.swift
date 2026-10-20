import Foundation

/// What Moe's driven browser leaves on disk that nothing else removes.
///
/// **Old Chrome for Testing builds.** `agent-browser install` (run by
/// install-hermes.sh at onboarding, and lazily by Hermes when none is found)
/// puts each new Chrome in `~/.agent-browser/browsers/chrome-<version>` and
/// never deletes the last one: ~360 MB per Chrome release, measured four deep
/// on the owner's Mac on 2026-09-25. Hermes launches only the newest build that
/// has an executable (`driven_browser_executable` in the fork's
/// tools/browser_tool_real_profile.py sorts by version, newest first), so every
/// older one is dead weight — unless a process is still running out of it.
///
/// **Chrome's on-device AI model.** Chrome downloads Gemini Nano (4.1 GB,
/// `OptGuideOnDeviceModel`) into the driven profile when a page asks for it,
/// and `--disable-component-update` does not stop it (measured: the flag was on
/// the running browser, the model arrived anyway). Moe never uses it. It is
/// removed whenever no driven browser is running on that profile.
///
/// Pure decisions here, so the tests can pin them; `sweep` does the deleting.
public enum BrowserJanitor {

    /// Version parts of `chrome-154.0.8037.57`, or nil for anything else
    /// (a partial download, a Playwright `chromium-*`, a stray file).
    public static func version(_ entry: String) -> [Int]? {
        guard entry.hasPrefix("chrome-") else { return nil }
        let parts = entry.dropFirst("chrome-".count).split(separator: ".")
        let nums = parts.compactMap { Int($0) }
        guard !nums.isEmpty, nums.count == parts.count else { return nil }
        return nums
    }

    /// The builds under `root` that can go: every `chrome-<version>` older than
    /// the newest one that is complete (`isComplete`), and not named in any
    /// command line of `processTable`. With no complete build nothing goes.
    public static func staleBuilds(entries: [String], root: String, processTable: String,
                                   isComplete: (String) -> Bool) -> [String] {
        let versioned = entries.compactMap { e in version(e).map { (e, $0) } }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
        guard let keep = versioned.last(where: { isComplete($0.0) }) else { return [] }
        let base = root.hasSuffix("/") ? root : root + "/"
        return versioned
            .filter { $0.1.lexicographicallyPrecedes(keep.1) }
            .map(\.0)
            .filter { !processTable.contains(base + $0 + "/") }
    }

    /// The executable Hermes looks for in a build, macOS layouts
    /// (`_driven_browser_candidates` in the fork).
    public static func executables(in build: String) -> [String] {
        ["Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
         "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
         "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"]
            .map { (build as NSString).appendingPathComponent($0) }
    }

    public static let onDeviceModelDir = "OptGuideOnDeviceModel"

    /// Deletes what the two rules above allow. Returns a line for the log, or
    /// nil when there was nothing to do.
    @discardableResult
    public static func sweep(browsersRoot: String, hermesHome: String,
                             processTable: String) -> String? {
        let fm = FileManager.default
        var done: [String] = []

        let entries = (try? fm.contentsOfDirectory(atPath: browsersRoot)) ?? []
        let stale = staleBuilds(entries: entries, root: browsersRoot, processTable: processTable) { entry in
            executables(in: (browsersRoot as NSString).appendingPathComponent(entry))
                .contains { fm.isExecutableFile(atPath: $0) }
        }
        for entry in stale {
            let path = (browsersRoot as NSString).appendingPathComponent(entry)
            if (try? fm.removeItem(atPath: path)) != nil { done.append(entry) }
        }

        if DrivenBrowsers.pids(inProcessTable: processTable, hermesHome: hermesHome).isEmpty {
            let profiles = (hermesHome as NSString).appendingPathComponent("browser-profile")
            for profile in (try? fm.contentsOfDirectory(atPath: profiles)) ?? [] {
                let model = ((profiles as NSString).appendingPathComponent(profile) as NSString)
                    .appendingPathComponent(onDeviceModelDir)
                if fm.fileExists(atPath: model), (try? fm.removeItem(atPath: model)) != nil {
                    done.append("\(profile)/\(onDeviceModelDir)")
                }
            }
        }
        return done.isEmpty ? nil : "browser: removed \(done.joined(separator: ", "))"
    }
}
