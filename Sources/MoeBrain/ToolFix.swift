import Foundation

/// **Why a tool failed, when the reason is one the person can fix** —
/// docs/FIXABLE-FAILURES.md, slice 3.
///
/// Hermes's tools say it as a code from a closed vocabulary
/// (`tools/fix_reasons.py` in the fork), and the fork's api_server puts the
/// fields on the `completed` `hermes.tool.progress` frame as `fix`:
///
///     event: hermes.tool.progress
///     data: {"tool": "…", "toolCallId": "…", "status": "completed",
///            "fix": {"code": "tcc_app_data", "owner": "app", "pane": "Privacy_AllFiles",
///                    "subject": "Google Chrome", "retry": true, "path": "…"}}
///
/// That is the only way the code reaches the app: the model's own words stay
/// the model's, and the app shows its own. Everything here is parsing — what
/// the app then *does* with a code is `PermissionGuide.forCode` in the app.
///
/// **Only codes in `FixCode` are read.** An unknown code (a newer Hermes, a
/// branch that has not landed, a tool with a `code` of its own) is nothing:
/// no card beats a card for the wrong cause, which is how a person grants
/// the wrong app. `ToolFixVocabularyTests` reads the pinned fork's `CODES`
/// and fails when the two disagree in either direction.
public enum FixCode: String, CaseIterable, Sendable {
    // macOS privacy grants
    case tccAppData = "tcc_app_data"
    case tccFiles = "tcc_files"
    case tccAutomation = "tcc_automation"
    case tccDriverAccessibility = "tcc_driver_accessibility"
    case tccDriverScreen = "tcc_driver_screen"
    case tccMicrophone = "tcc_microphone"
    case tccCalendar = "tcc_calendar"
    case tccReminders = "tcc_reminders"
    case tccContacts = "tcc_contacts"
    // not grants, but fixable
    case driverNotRunning = "driver_not_running"
    case windowOtherSpace = "window_other_space"
    case mcpNeedsReauth = "mcp_needs_reauth"
    case mcpNotConnected = "mcp_not_connected"
    case claudeLoginExpired = "claude_login_expired"
    case claudeUsageCap = "claude_usage_cap"
    case browserMissing = "browser_missing"
    case profileLocked = "profile_locked"
    /// Memoe's Chrome extension isn't installed, or isn't connected. Only
    /// explained for now; the card that installs it is a later slice.
    case browserExtensionMissing = "browser_extension_missing"
    /// A page step only the person can take — a passkey, a CAPTCHA, an
    /// identity check — met on a turn nobody was at (a scheduled job). Not a
    /// setting: the job reports it, and nothing on the Mac fixes it.
    case personNeeded = "person_needed"
}

/// Whose macOS grant it is. They are different rows in System Settings.
public enum FixOwner: String, Sendable {
    /// Memoe (or Memoe Dev) itself.
    case app
    /// CuaDriver (`com.trycua.driver`), the screen helper.
    case driver
}

public struct ToolFix: Equatable, Sendable {
    public let code: FixCode
    /// Nil when the cause is not a grant.
    public let owner: FixOwner?
    /// A `Privacy_*` anchor, or nil. Only anchors in `knownPanes` are kept.
    public let pane: String?
    /// The app or folder involved: "Google Chrome", "Desktop", "Notes".
    public let subject: String?
    /// The identical call is expected to work once the named fix is done.
    public let retry: Bool
    /// `"driver"`: the grant applies to a freshly launched screen helper;
    /// Hermes relaunches it on the next call itself.
    public let restart: String?
    /// `tcc_automation` only: `"denied"` (-1743, a switch to turn on) or
    /// `"not_asked"` (-1744, macOS needs to ask while the person is there).
    public let consent: String?
    /// A second pane the same fix needs (CuaDriver still waiting on both of
    /// its grants names Accessibility first and Screen Recording here).
    public let alsoPane: String?
    /// Every other scalar the tool sent (`path`, `window_id`, `detail`…), as text.
    public let extras: [String: String]

    public init(code: FixCode, owner: FixOwner? = nil, pane: String? = nil, subject: String? = nil,
                retry: Bool = true, restart: String? = nil, consent: String? = nil,
                alsoPane: String? = nil, extras: [String: String] = [:]) {
        self.code = code
        self.owner = owner
        self.pane = pane.flatMap { Self.knownPanes.contains($0) ? $0 : nil }
        self.subject = subject.flatMap { $0.isEmpty ? nil : $0 }
        self.retry = retry
        self.restart = restart
        self.consent = consent
        self.alsoPane = alsoPane.flatMap { Self.knownPanes.contains($0) ? $0 : nil }
        self.extras = extras
    }

    /// The fork's `PANES`. A pane outside it is dropped, never opened.
    public static let knownPanes: Set<String> = [
        "Privacy_AllFiles", "Privacy_FilesAndFolders", "Privacy_Automation", "Privacy_Accessibility",
        "Privacy_ScreenCapture", "Privacy_Microphone", "Privacy_Calendars", "Privacy_Reminders",
        "Privacy_Contacts",
    ]

    private static let named: Set<String> = [
        "code", "owner", "pane", "subject", "retry", "restart", "consent", "also_pane", "error",
    ]

    /// The fix a `completed` tool-progress frame carries, or nil — for a frame
    /// with no `fix`, a `fix` that is not an object, and a code the app does
    /// not know.
    public static func parse(progressFrame obj: [String: Any]) -> ToolFix? {
        guard let fix = obj["fix"] as? [String: Any] else { return nil }
        return parse(fields: fix)
    }

    /// The contract fields themselves (`{code, owner, pane, subject, retry, …}`).
    public static func parse(fields fix: [String: Any]) -> ToolFix? {
        guard let raw = fix["code"] as? String, let code = FixCode(rawValue: raw) else { return nil }
        var extras: [String: String] = [:]
        for (k, v) in fix where !named.contains(k) {
            switch v {
            case let s as String: extras[k] = s
            case let n as NSNumber: extras[k] = n.stringValue
            default: continue
            }
        }
        return ToolFix(code: code,
                       owner: (fix["owner"] as? String).flatMap(FixOwner.init(rawValue:)),
                       pane: fix["pane"] as? String,
                       subject: fix["subject"] as? String,
                       retry: (fix["retry"] as? Bool) ?? false,
                       restart: fix["restart"] as? String,
                       consent: fix["consent"] as? String,
                       alsoPane: fix["also_pane"] as? String,
                       extras: extras)
    }
}

extension FixCode {
    /// The grant this code is about — owner and pane — exactly as the fork's
    /// `GRANTS` has it; nil for a code that is not a grant.
    /// `ToolFixVocabularyTests` compares it with the pinned fork's table, and
    /// `PermissionGuideFixCodeTests` holds the app's guides to it.
    public var grant: (owner: FixOwner, pane: String)? {
        switch self {
        case .tccAppData: return (.app, "Privacy_AllFiles")
        case .tccFiles: return (.app, "Privacy_AllFiles")
        case .tccAutomation: return (.app, "Privacy_Automation")
        case .tccDriverAccessibility: return (.driver, "Privacy_Accessibility")
        case .tccDriverScreen: return (.driver, "Privacy_ScreenCapture")
        case .tccMicrophone: return (.app, "Privacy_Microphone")
        case .tccCalendar: return (.app, "Privacy_Calendars")
        case .tccReminders: return (.app, "Privacy_Reminders")
        case .tccContacts: return (.app, "Privacy_Contacts")
        case .driverNotRunning, .windowOtherSpace, .mcpNeedsReauth, .mcpNotConnected,
             .claudeLoginExpired, .claudeUsageCap, .browserMissing, .profileLocked,
             .browserExtensionMissing, .personNeeded:
            return nil
        }
    }
}
