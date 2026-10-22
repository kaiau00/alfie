import AppKit
import CryptoKit
import Foundation

/// **Moe in your Chrome** — Connections › Chrome (ticket #13).
///
/// The lane is Hermes's: the Memoe extension (the fork's `extensions/chrome`)
/// talks to a native-messaging host, and `browser_exec(where="chrome")` works
/// in a "Moe" tab group through it. This is the app's part: put the extension
/// where Chrome's Load unpacked can pick it, write the host, flip
/// `browser.chrome_extension.enabled`, and say which state it is in. Every
/// call goes through `configure-hermes.py`, the one writer of Hermes's config.
///
/// The flag goes on at **Set up**, not at the first connect: with it off the
/// relay serves no socket and writes no bridge file
/// (`browser_chrome_bridge.serve_bridge`), so a connect can never be seen
/// until it is on. Nothing restarts either way — the relay re-reads the
/// config every 5 s and `browser_exec` on every call (measured 2026-09-24
/// against a throwaway Chrome for Testing: off → disconnected, on →
/// connected, both within 7 s).
enum ChromeExtension {
    /// Fixed by the `key` in the extension's manifest.
    static let extensionID = "ljblhmlmgflmbffbfelamefleikodmjh"

    /// The unlisted Chrome Web Store listing. **Nil until it is live**; set it
    /// and Set up opens the listing instead of staging an unpacked folder.
    static let storeURL: URL? = nil

    /// Where Load unpacked is pointed: Moe's own home, copied from the
    /// installed Hermes on every Set up so it matches the pinned lane.
    static var stagedFolder: URL { Paths.home.appendingPathComponent("chrome-extension", isDirectory: true) }

    /// Chrome takes this from outside as a GURL Apple event, which is what
    /// `open -a "Google Chrome" chrome://extensions` sends — measured against
    /// Chrome for Testing 154 on 2026-09-24 (the tab opened). The steps say
    /// how to get there anyway, in case a Chrome ever refuses it.
    static let extensionsPage = URL(string: "chrome://extensions")!
    static let chromeBundleID = "com.google.Chrome"

    /// Every file under `dir`, by relative path and contents, as one digest;
    /// nil when there is nothing there. Two folders match when their digests do.
    static func treeDigest(_ dir: URL) -> String? {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        var parts: [String] = []
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        for case let f as URL in walk {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = fm.contents(atPath: f.path) else { continue }
            let rel = String(f.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.count))
            parts.append(rel + "\u{0}" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        guard !parts.isEmpty else { return nil }
        return SHA256.hash(data: Data(parts.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The row's id in ConnectionsView's selection, beside `brainID`.
    static let rowID = "\u{1}chrome-extension"

    enum Copy {
        static let title = "Alfie in your Chrome"
        static let whatItDoes = "Alfie works in its own tab group in your Chrome, only on turns you start; Chrome shows a bar while it does."
        static let why = "Some sites block Alfie's own browser. With this on, Alfie can do those in your Chrome instead — in a tab group called Alfie, never in your tabs, and without taking your focus."
        static let steps = [
            "Turn on Developer mode, at the top right of the Extensions page.",
            "Click Load unpacked.",
            "Pick the chrome-extension folder (Show folder opens it in Finder).",
        ]
        static let pageFallback = "If the Extensions page didn't open, type chrome://extensions into Chrome's address bar."
        static let offNote = "Off: Alfie won't use your Chrome. The extension stays in Chrome until you remove it there — Chrome › Extensions › Alfie › Remove."
        static let noChrome = "Install Google Chrome first — Alfie works in your Chrome through an extension, and this Mac has no Chrome to add it to."
        static let update = "A newer Alfie extension came with this version of Alfie. Click Update, then Reload on Alfie in Chrome's Extensions page."
    }
}

/// What `configure-hermes.py --chrome-extension-status` prints.
struct ChromeLaneReport: Decodable, Equatable, Sendable {
    struct Warning: Decodable, Equatable, Sendable {
        let code: String
        let text: String?
    }
    let hostInstalled: Bool
    let enabled: Bool
    let connected: Bool
    let warnings: [Warning]
    let error: String?
    /// The pinned Hermes's `extensions/chrome`, which the staged copy must match.
    let source: String?

    enum CodingKeys: String, CodingKey {
        case hostInstalled = "host_installed", enabled, connected, warnings, error, source
    }

    static func parse(_ stdout: String) -> ChromeLaneReport? {
        guard let line = stdout.split(whereSeparator: \.isNewline).last else { return nil }
        return try? JSONDecoder().decode(ChromeLaneReport.self, from: Data(line.utf8))
    }
}

/// The row's one word, and what the detail offers.
enum ChromeLaneState: Equatable, Sendable {
    /// No host, or no staged folder: Set up.
    case notInstalled
    /// Set up, then turned off here.
    case off
    /// Set up and on, and the extension has not said hello: the steps.
    case waiting
    case connected

    /// `staged`: the Load unpacked folder is on disk. A connected extension
    /// is connected whatever else is true — the relay only answers with the
    /// flag on — so that is read first.
    static func from(_ r: ChromeLaneReport?, staged: Bool) -> ChromeLaneState {
        guard let r else { return .notInstalled }
        if r.connected { return .connected }
        if !r.hostInstalled || (ChromeExtension.storeURL == nil && !staged) { return .notInstalled }
        return r.enabled ? .waiting : .off
    }

    var word: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .off: return "Off"
        case .waiting: return "Installed, not connected"
        case .connected: return "Connected"
        }
    }

    var good: Bool { self == .connected }
}

/// Connections › Chrome's state and its three actions. One per app; the
/// pane polls it while it is on screen.
@MainActor
final class ChromeExtensionModel: ObservableObject {
    static let shared = ChromeExtensionModel()

    @Published private(set) var report: ChromeLaneReport?
    @Published private(set) var busy = false
    /// The last thing that went wrong, or what just happened, in plain words.
    @Published var note = ""
    /// Set by the Fix card: Connections selects the Chrome row and clears it.
    @Published var focusRequested = false

    /// Seams, so a test can drive Set up without a Hermes, a Chrome or Finder.
    struct Seams {
        /// `configure-hermes.py` with these arguments.
        var configure: @Sendable ([String]) -> Result<String, BrainSetup.Failure>
        /// Is the staged folder on disk.
        var stagedExists: () -> Bool
        /// Is Google Chrome installed (Launch Services knows `com.google.Chrome`).
        var chromeInstalled: () -> Bool
        /// Does the staged folder hold the same files as this Hermes's
        /// `extensions/chrome` (its path, from the status line)?
        var stagedMatches: (String) -> Bool
        /// Open a URL in Google Chrome; false when there is no Chrome.
        var openInChrome: (URL) -> Bool
        var revealInFinder: (URL) -> Void
    }
    var seams: Seams
    private let demo: Bool

    init(seams: Seams = .live) {
        self.seams = seams
        self.demo = false
    }

    /// A fixed state for `--settings-snapshot`: no polling, no scripts.
    init(demo report: ChromeLaneReport) {
        self.seams = .live
        self.report = report
        self.demo = true
    }

    var state: ChromeLaneState {
        ChromeLaneState.from(report, staged: demo ? (report?.hostInstalled ?? false) : seams.stagedExists())
    }

    /// The staged extension is not the one the installed Hermes pins: an
    /// upgrade moved the relay on and the extension in Chrome would drift from
    /// it. Set up (Update) copies it again.
    var needsUpdate: Bool {
        guard state != .notInstalled, ChromeExtension.storeURL == nil, let source = report?.source
        else { return false }
        if demo { return source == Self.demoStale }
        return !seams.stagedMatches(source)
    }
    /// A demo report's `source` that draws the Update state.
    static let demoStale = "demo:stale"

    /// The row's one line.
    var word: String {
        if needsUpdate { return "Update available" }
        if fileAccessWarning != nil { return "Connected · one thing to check" }
        return state.word
    }

    var fileAccessWarning: String? {
        guard state == .connected, let w = report?.warnings.first(where: { $0.code == "file_access_on" })
        else { return nil }
        return w.text ?? "Alfie's Chrome extension is allowed to open files on this Mac. Alfie never uses that; turn off “Allow access to file URLs” in Chrome › Extensions › Alfie."
    }

    // MARK: Status

    func refresh() async {
        guard !demo else { return }
        let run = seams.configure
        let result = await ScriptRunner.offMain { run(["--chrome-extension-status"]) }
        switch result {
        case .success(let out):
            if let r = ChromeLaneReport.parse(out) { report = r }
        case .failure(let f):
            note = f.message
        }
    }

    private var poll: Task<Void, Never>?

    /// Every 3 s while the Chrome row is on screen: the person is in Chrome
    /// clicking Load unpacked, and the row should turn green when they do.
    func startPolling() {
        guard !demo, poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    // MARK: Actions

    /// Stage the folder, write the host, turn the lane on, then open
    /// Chrome's Extensions page and show the folder. With a store listing,
    /// open it instead of staging anything.
    func setUp() async {
        guard !busy else { return }
        note = ""
        // Before anything is written: install-host would make Chrome's own
        // folder on a Mac that has no Chrome.
        guard seams.chromeInstalled() else { note = ChromeExtension.Copy.noChrome; return }
        busy = true
        defer { busy = false }
        let run = seams.configure
        let dest = ChromeExtension.stagedFolder.path
        if case .failure(let f) = await ScriptRunner.offMain({ run(["--install-chrome-extension", dest]) }) {
            note = f.message; return
        }
        if case .failure(let f) = await ScriptRunner.offMain({ run(["--set-chrome-extension", "on"]) }) {
            note = f.message; return
        }
        let store = ChromeExtension.storeURL
        if !seams.openInChrome(store ?? ChromeExtension.extensionsPage) {
            note = ChromeExtension.Copy.noChrome
        }
        if store == nil { seams.revealInFinder(ChromeExtension.stagedFolder) }
        await refresh()
    }

    /// The switch, after Set up. Off stops Moe using their Chrome within
    /// seconds; the extension itself is removed in Chrome.
    func setEnabled(_ on: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let run = seams.configure
        let result = await ScriptRunner.offMain { run(["--set-chrome-extension", on ? "on" : "off"]) }
        if case .failure(let f) = result { note = f.message } else { note = on ? "" : ChromeExtension.Copy.offNote }
        await refresh()
    }

    func showFolder() { seams.revealInFinder(ChromeExtension.stagedFolder) }

    func openExtensionsPage() {
        if !seams.openInChrome(ChromeExtension.storeURL ?? ChromeExtension.extensionsPage) {
            note = ChromeExtension.Copy.noChrome
        }
    }
}

extension ChromeExtensionModel.Seams {
    static let live = ChromeExtensionModel.Seams(
        configure: { BrainSetup.run($0) },
        stagedExists: {
            FileManager.default.fileExists(atPath: ChromeExtension.stagedFolder.appendingPathComponent("manifest.json").path)
        },
        chromeInstalled: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromeExtension.chromeBundleID) != nil
        },
        stagedMatches: { source in
            ChromeExtension.treeDigest(URL(fileURLWithPath: source, isDirectory: true))
                == ChromeExtension.treeDigest(ChromeExtension.stagedFolder)
        },
        openInChrome: { url in
            guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromeExtension.chromeBundleID)
            else { return false }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: cfg)
            return true
        },
        revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    )
}
