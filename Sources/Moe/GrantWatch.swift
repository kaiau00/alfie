import AppKit
import AVFoundation
import Contacts
import EventKit
import IOKit.hid
import MoeBrain

/// **Watch the switch, then carry on** (docs/FIXABLE-FAILURES.md §4, slice 4).
///
/// Once a pane is opened for a fixable failure — the card's Open Settings,
/// or the brain's `moe_open_settings` — this polls that grant's `GrantProbe`
/// every 2 s for up to 5 minutes. When it flips, `onGranted` decides what
/// happens (the Conductor sends one background note that resumes the task,
/// or drops it when the conversation moved on).
///
/// `AccessibilityWatch` is the talk key's own, always-on watcher for Memoe's
/// Accessibility; this is the general one, and it only runs while someone is
/// in System Settings because Moe sent them there.
///
/// The rules:
/// - one watch per code: opening the same pane twice does not start a second;
/// - a probe that cannot observe the grant in this process is not watched
///   (`watchable`): the card says to quit and reopen instead;
/// - stopped on quit, on a new or switched conversation, and when the turn
///   that started it is abandoned (the Conductor calls `cancel`).
@MainActor
final class GrantWatch {
    struct Watch {
        let fix: ToolFix
        let guide: PermissionGuide
        /// The conversation that was open when the pane was opened.
        let conversationID: String
        /// `Conductor.personTurns` then: a newer turn the person started
        /// supersedes this one, and its carry-on is dropped.
        let personTurn: Int
        let startedAt: Date
    }

    /// What the owner of a flipped watch did with it.
    enum Outcome: Equatable {
        /// The carry-on went to the brain. The watch ends.
        case sent
        /// Nothing to carry on (superseded, another conversation). The watch ends.
        case dropped(String)
        /// Granted, but a turn is still in flight: ask again next tick.
        case later
    }

    static let interval: TimeInterval = 2
    static let limit: TimeInterval = 5 * 60

    private(set) var watches: [FixCode: Watch] = [:]
    /// How a grant is read. A seam: tests inject their own switch.
    var probe: (GrantProbe, ToolFix) async -> Bool = { probe, fix in
        await Task.detached(priority: .utility) { GrantWatch.liveProbe(probe, fix: fix) }.value
    }
    var now: () -> Date = Date.init
    var onGranted: ((Watch) -> Outcome)?
    /// The live timer. Off in tests, which call `tick()` themselves.
    var runsTimer = true

    private var timer: Timer?
    private var ticking = false
    /// Codes whose baseline is being read: a second start meanwhile is a duplicate.
    private var starting = Set<FixCode>()

    /// Whether this grant can be watched at all. A grant macOS applies only
    /// after a relaunch (`needsRelaunch`) is watched only when its probe does
    /// the very thing that failed — a readable-path probe reads the folder the
    /// tool could not — because then a flip means it works now, relaunch or
    /// not; every other relaunch grant would read "off" until Memoe restarts.
    static func watchable(_ guide: PermissionGuide) -> Bool {
        switch guide.probe {
        case .none: return false
        case .readablePath: return true
        default: return !guide.needsRelaunch
        }
    }

    /// The baseline: the grant is off now. False when it is already on —
    /// the app holds it and the failure was somewhere else (a child that
    /// started before the grant), or the request did not come from a real
    /// failure at all.
    func isOff(fix: ToolFix, guide: PermissionGuide) async -> Bool {
        !(await probe(guide.probe, fix))
    }

    /// Start watching, unless this code is already watched, cannot be, or
    /// its grant is already on (the baseline).
    @discardableResult
    func start(fix: ToolFix, guide: PermissionGuide, conversationID: String, personTurn: Int) async -> Bool {
        guard Self.watchable(guide) else {
            Log.write("grant watch: \(guide.name) is not watchable (\(guide.probe.json))")
            return false
        }
        guard watches[fix.code] == nil, !starting.contains(fix.code) else {
            Log.write("grant watch: \(fix.code.rawValue) already watched")
            return false
        }
        starting.insert(fix.code)
        defer { starting.remove(fix.code) }
        guard await isOff(fix: fix, guide: guide) else {
            Log.write("grant watch: \(guide.name) is already on — nothing to watch, no carry-on")
            return false
        }
        guard watches[fix.code] == nil else { return false }
        watches[fix.code] = Watch(fix: fix, guide: guide, conversationID: conversationID,
                                  personTurn: personTurn, startedAt: now())
        Log.write("grant watch: watching \(guide.name) for \(fix.code.rawValue) (\(guide.probe.json))")
        schedule()
        return true
    }

    func cancel(where match: (Watch) -> Bool, _ why: String) {
        for (code, watch) in watches where match(watch) {
            watches[code] = nil
            Log.write("grant watch: stopped \(code.rawValue) — \(why)")
        }
        if watches.isEmpty { stopTimer() }
    }

    func cancelAll(_ why: String) { cancel(where: { _ in true }, why) }

    /// One poll of every watch.
    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false; if watches.isEmpty { stopTimer() } }
        let at = now()
        for (code, watch) in watches {
            if at.timeIntervalSince(watch.startedAt) > Self.limit {
                watches[code] = nil
                Log.write("grant watch: gave up on \(code.rawValue) after \(Int(Self.limit)) s")
                continue
            }
            guard await probe(watch.guide.probe, watch.fix) else { continue }
            // Cancelled while the probe ran: nothing to do.
            guard watches[code]?.startedAt == watch.startedAt else { continue }
            let outcome = onGranted?(watch) ?? .dropped("nobody listening")
            switch outcome {
            case .later:
                continue
            case .sent:
                watches[code] = nil
                Log.write("grant watch: \(watch.guide.name) is on — carry-on sent")
            case .dropped(let why):
                watches[code] = nil
                Log.write("grant watch: \(watch.guide.name) is on — no carry-on: \(why)")
            }
        }
    }

    private func schedule() {
        guard runsTimer, timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - The probes, for real

    /// Whether the grant is on, asking macOS without ever prompting.
    nonisolated static func liveProbe(_ probe: GrantProbe, fix: ToolFix) -> Bool {
        switch probe {
        case .accessibilityTrusted:
            return AXIsProcessTrusted()
        case .inputMonitoringAccess:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .screenCapturePreflight:
            return CGPreflightScreenCaptureAccess()
        case .microphoneAuthorization:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .calendarAuthorization:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .remindersAuthorization:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .contactsAuthorization:
            return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .readablePath(let fallback):
            return readable(probePath(fallback, fix: fix))
        case .automationTarget:
            guard let app = FixSubject.known(fix.subject, for: .tccAutomation) else { return false }
            return AutomationConsent.live(appName: app) == .granted
        case .driverPermission(let key):
            return driverGrant(key)
        case .none:
            return false
        }
    }

    /// The failure's own `path` when it named an absolute one — the folder
    /// the tool could not read is the best evidence — else the guide's.
    nonisolated static func probePath(_ fallback: String, fix: ToolFix) -> String {
        if let path = fix.extras["path"], path.hasPrefix("/"), !path.contains("\0") { return path }
        return (fallback as NSString).expandingTildeInPath
    }

    /// An EPERM-free read: a directory's listing, or a file's first byte.
    nonisolated static func readable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }

    /// `cua-driver permissions status --json`, this key true. CuaDriver's
    /// own identity answers, which is the only one that counts for its rows.
    nonisolated static func driverGrant(_ key: String) -> Bool {
        let cmd = NSHomeDirectory() + "/.local/bin/cua-driver"
        guard FileManager.default.isExecutableFile(atPath: cmd) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = ["permissions", "status", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?[key] as? Bool == true
    }
}
