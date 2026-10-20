import AppKit
import CoreServices
import MoeBrain

/// **The Fix card**: a tool failed for a reason the person can fix, and the
/// tool said which (docs/FIXABLE-FAILURES.md, slice 3). One line of why, in
/// plain words, naming the app whose switch it is, and the one thing that
/// fixes it — shown on the island and in Chat, where the talk-key "Fix" row
/// lives.
///
/// The words are the app's, built from the code and its subject, never the
/// tool's `error` text: that is written for the model, and it already has
/// it. Which grant, which pane and which action all come from
/// `PermissionGuide.forCode`, so the card, Settings and (slice 4) the brain
/// say the same thing.
struct FixOffer: Identifiable, Equatable {
    let fix: ToolFix
    /// One line, plain words.
    let why: String
    /// The button that fixes it, or nil when there is nothing to press
    /// (`FixRemedy.explain`): the card then offers only Dismiss.
    let actionTitle: String?
    /// The System Settings pane Open Settings opens, when the remedy is a grant.
    let settingsURL: URL?

    /// One card per code: a second failure for the same reason is the same card.
    var id: String { fix.code.rawValue }

    static let openSettings = "Open Settings"
    static let dismiss = "Dismiss"
    static let setUpChrome = "Set up Chrome"
    /// Never "Memoe": CuaDriver's switch is its own row, and naming the
    /// wrong app is how a person turns on the wrong one.
    static let driverName = "CuaDriver (the screen helper)"

    static func == (a: FixOffer, b: FixOffer) -> Bool {
        a.fix == b.fix && a.why == b.why && a.actionTitle == b.actionTitle && a.settingsURL == b.settingsURL
    }

    var remedy: FixRemedy { PermissionGuide.forCode(fix.code, pane: fix.pane) }

    /// The card for a failure, or nil when this failure gets none: a code
    /// Moe handles itself (another Space), and a stopped screen helper that
    /// Hermes already reset (`retry`), where there is nothing to do but ask
    /// again.
    init?(_ fix: ToolFix, app: String = BuildInfo.hostAppName) {
        let remedy = PermissionGuide.forCode(fix.code, pane: fix.pane)
        if case .noCard = remedy { return nil }
        if fix.code == .driverNotRunning, fix.retry { return nil }
        self.fix = fix
        self.why = Self.why(fix, app: app)
        switch remedy {
        case .grant(let guide):
            actionTitle = Self.openSettings
            settingsURL = guide.settingsURL
        case .restartScreenHelper:
            actionTitle = "Quit and reopen \(app)"
            settingsURL = nil
        case .openConnections:
            actionTitle = "Open Connections"
            settingsURL = nil
        case .signInToBrain:
            actionTitle = "Sign in"
            settingsURL = nil
        case .openChromeExtension:
            actionTitle = Self.setUpChrome
            settingsURL = nil
        case .explain, .noCard:
            actionTitle = nil
            settingsURL = nil
        }
    }

    /// The why line. Every case names whose problem it is: the app by the
    /// name on its System Settings row, or CuaDriver by its own.
    static func why(_ fix: ToolFix, app: String) -> String {
        // Never the tool's text: only a name from a fixed list, else nil
        // (and each case below says "another app", "that folder", …).
        let subject = FixSubject.known(fix.subject, for: fix.code)
        switch fix.code {
        case .tccAppData:
            return "\(app) isn't allowed to read \(subject.map { "\($0)'s" } ?? "another app's") data. Turn on Full Disk Access for \(app)."
        case .tccFiles:
            let folder = subject.map { "your \($0) folder" } ?? "that folder"
            return fix.pane == "Privacy_FilesAndFolders"
                ? "\(app) isn't allowed into \(folder). Turn it on for \(app) under Files & Folders."
                : "\(app) isn't allowed into \(folder). Turn on Full Disk Access for \(app)."
        case .tccAutomation:
            let target = subject ?? "that app"
            return fix.consent == "not_asked"
                ? "macOS needs to ask before \(app) can control \(target). Choose Allow when it asks, or turn \(target) on under Automation."
                : "\(app) isn't allowed to control \(target). Turn \(target) on for \(app) under Automation."
        case .tccDriverAccessibility:
            return fix.alsoPane == "Privacy_ScreenCapture"
                ? "\(driverName) is still waiting for macOS permission. Turn CuaDriver on under Accessibility and Screen Recording."
                : "\(driverName) isn't allowed to control your Mac. Turn CuaDriver on under Accessibility."
        case .tccDriverScreen:
            return "\(driverName) isn't allowed to see your screen. Turn CuaDriver on under Screen Recording."
        case .tccMicrophone:
            return "\(app) can't hear you: the microphone is off for it. Turn \(app) on under Microphone."
        case .tccCalendar:
            return "\(app) isn't allowed to see your calendar. Turn \(app) on under Calendars."
        case .tccReminders:
            return "\(app) isn't allowed to see your reminders. Turn \(app) on under Reminders."
        case .tccContacts:
            return "\(app) isn't allowed to see your contacts. Turn \(app) on under Contacts."
        case .driverNotRunning:
            return "The screen helper (CuaDriver) isn't running. Reopening \(app) starts it again."
        case .mcpNeedsReauth:
            return "\(subject ?? "A connection") needs you to sign in again."
        case .mcpNotConnected:
            return "\(subject ?? "A connection") isn't connected, so Moe couldn't use it."
        case .claudeLoginExpired:
            return "Moe's sign-in to Claude has run out. Sign in again and Moe can carry on."
        case .claudeUsageCap:
            return "You've used up your Claude plan for now, so Moe can't think until it resets."
        case .browserMissing:
            return "The browser Moe uses isn't set up on this Mac yet."
        case .profileLocked:
            return "\(subject ?? "Your browser") has its profile in use. Quit it, then ask Moe again."
        case .browserExtensionMissing:
            return "The \(app) extension for Chrome isn't connected, so Moe couldn't work in your Chrome."
        case .windowOtherSpace, .personNeeded:
            return ""
        }
    }
}

/// What pressing a Fix card's button does. A seam so a test can drive the
/// Conductor without System Settings opening on the Mac running it.
@MainActor
struct FixActions {
    var perform: (FixOffer, Conductor) -> Void

    static let live = FixActions { offer, conductor in
        switch offer.remedy {
        case .grant(let guide):
            guard let url = offer.settingsURL else { return }
            // Memoe's own Screen Recording: ask macOS first, which is what
            // puts Memoe on that list (PermissionExplainer does the same).
            // Never for CuaDriver's row: that ask would be Memoe's.
            if guide.id == PermissionGuide.screenRecording.id, ScreenPermission.request() { return }
            conductor.openSettingsURL(url)
            // The pane is open: watch the switch, and carry on when it flips
            // (slice 4, `GrantWatch`) — unless it is already on.
            Task { @MainActor in await conductor.watchGrant(for: offer.fix) }
        case .restartScreenHelper:
            Relaunch.now()
        case .openConnections:
            (NSApp.delegate as? AppDelegate)?.showMainWindow(at: .connections)
        case .signInToBrain:
            SettingsWindow.show(conductor: conductor, at: .brain)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .moeSignIn, object: nil)
            }
        case .openChromeExtension:
            // Flag first: ConnectionsView reads it when it appears, and also
            // when it is already open behind the island.
            ChromeExtensionModel.shared.focusRequested = true
            (NSApplication.shared.delegate as? AppDelegate)?.showMainWindow(at: .connections)
        case .explain, .noCard:
            break
        }
    }
}

/// **What a Fix card may name.** `subject` arrives from a tool result, and
/// a card is shown with an Open Settings button beside it, so its text is
/// untrusted: a page or a shell's output that got a string into it must
/// not be able to put a sentence of its own on Memoe's card. A subject is
/// only ever shown when it is one of these names (matched ignoring case,
/// shown in the spelling here); anything else becomes the card's generic
/// word — "another app", "that folder", "A connection".
enum FixSubject {
    /// Apps whose data Full Disk Access guards, and the browsers whose
    /// profiles Moe reads — the names on their own System Settings rows.
    static let browsers = [
        "Google Chrome", "Google Chrome for Testing", "Safari", "Firefox", "Microsoft Edge",
        "Brave Browser", "Arc", "Chromium", "Opera", "Vivaldi", "Orion", "Zen",
    ]
    static let appData = browsers + [
        "Messages", "Mail", "Notes", "Photos", "Calendar", "Contacts", "Reminders",
        "Stocks", "Voice Memos", "Music", "TV", "Podcasts", "Books", "Home",
    ]
    /// The folders macOS asks about under Files & Folders.
    static let folders = [
        "Desktop", "Documents", "Downloads", "iCloud Drive", "Removable Volumes", "Network Volumes",
    ]
    /// Apps Moe drives with Apple Events, as they appear under Automation.
    static let automation = browsers + [
        "Finder", "System Events", "Mail", "Messages", "Notes", "Calendar", "Reminders",
        "Contacts", "Music", "Photos", "Keynote", "Pages", "Numbers", "Terminal", "Preview",
        "TextEdit", "Shortcuts", "QuickTime Player", "Spotify", "Slack", "Microsoft Word",
        "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Outlook", "System Settings",
    ]
    /// Connection names as Memoe's Connections page shows them.
    static let connections = [
        "Gmail", "Google Calendar", "Google Drive", "Google Docs", "Google Sheets", "Google Contacts",
        "Outlook", "Slack", "Notion", "GitHub", "Linear", "Jira", "Confluence", "Figma", "Stripe",
        "Vercel", "Cloudflare", "Dropbox", "Todoist", "Asana", "Trello", "Airtable", "HubSpot",
        "Salesforce", "Zoom", "Discord", "Telegram", "WhatsApp", "Spotify", "Composio",
    ]

    static func list(for code: FixCode) -> [String] {
        switch code {
        case .tccAppData: return appData
        case .tccFiles: return folders
        case .tccAutomation: return automation
        case .mcpNeedsReauth, .mcpNotConnected: return connections
        case .profileLocked: return browsers
        default: return []
        }
    }

    /// The known spelling of `raw` for this code, or nil.
    static func known(_ raw: String?, for code: FixCode) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return list(for: code).first { $0.caseInsensitiveCompare(raw) == .orderedSame }
    }
}

/// **Is Automation really off for this app?** A `tcc_automation` failure is
/// read from osascript's output, and a script can print a -1743 refusal of
/// its own (`error "Not authorized…" number -1743` inside a `tell`). So the
/// card is shown only when macOS itself says Memoe may not send Apple events
/// to that app: `AEDeterminePermissionToAutomateTarget`, never asking
/// (`askUserIfNeeded` false), for the app's bundle id. Slice 4's watcher
/// (`PermissionProbe.automationTarget`) is the same call.
enum AutomationConsent: Equatable {
    case granted
    /// -1743: turned off under Automation.
    case denied
    /// -1744: macOS would have to ask first.
    case notAsked
    /// No such app, it isn't running (-600), or any other answer: no evidence.
    case unknown

    /// Whether this answer is the refusal a card offers to fix.
    var isRefusal: Bool { self == .denied || self == .notAsked }

    static func live(appName: String) -> AutomationConsent {
        guard let id = bundleID(forAppNamed: appName) else { return .unknown }
        return probe(bundleID: id)
    }

    static func probe(bundleID: String) -> AutomationConsent {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &target) == noErr else {
            return .unknown
        }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                     AEEventID(typeWildCard), false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown
        }
    }

    /// The bundle id of the app with this name: a running one first, then
    /// where apps live. The name is only looked up, never shown.
    static func bundleID(forAppNamed name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let id = running.bundleIdentifier { return id }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", "/System/Library/CoreServices",
                    NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".app")
            if let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        return nil
    }
}
