import AVFoundation
import AppKit
import Contacts
import CoreGraphics
import EventKit
import Foundation
import Speech

/// Whether macOS has actually granted each permission.
///
/// The Permissions pane explained what every grant was for and how to give it,
/// and then never said whether you had. That is the one question the screen
/// exists to answer — "is it on?" — and it was the one thing missing, so the
/// pane read as documentation rather than status.
///
/// Every check here is read-only and must never prompt. `AVCaptureDevice`,
/// `CNContactStore` and `EKEventStore` all expose a status query separate from
/// the request that triggers the dialog; screen recording has
/// `CGPreflightScreenCaptureAccess` for exactly this; and Full Disk Access has
/// no API at all, so it is probed by trying to read a protected file.
enum PermissionStatus {

    enum State {
        case granted
        case denied
        /// Never asked yet — different from denied, and worth saying so:
        /// nothing is broken, Moe simply has not needed it yet.
        case notAsked
        /// No way to read this one without prompting or guessing.
        case unknown

        var label: String {
            switch self {
            case .granted:  return "Allowed"
            case .denied:   return "Not allowed"
            case .notAsked: return "Not asked yet"
            case .unknown:  return "Can't tell"
            }
        }
    }

    /// Read the current state of one guide. Cheap enough to call on redraw
    /// except for Full Disk Access, which touches the disk — the pane caches.
    static func current(_ id: String) -> State {
        switch id {
        case "microphone":         return capture(.audio)
        case "speech-recognition": return speech()
        case "accessibility":      return AXIsProcessTrusted() ? .granted : .denied
        case "screen-recording":   return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case "contacts":           return contacts()
        case "calendar":           return events(.event)
        case "reminders":          return events(.reminder)
        case "full-disk-access":   return fullDisk()
        // Input Monitoring and Automation have no read-only query that does
        // not either prompt or lie. Saying "can't tell" is better than
        // guessing wrong about a permission someone is trying to debug.
        default:                   return .unknown
        }
    }

    // MARK: - Individual checks

    private static func capture(_ type: AVMediaType) -> State {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:    return .granted
        case .denied,
             .restricted:    return .denied
        case .notDetermined: return .notAsked
        @unknown default:    return .unknown
        }
    }

    private static func speech() -> State {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:    return .granted
        case .denied,
             .restricted:    return .denied
        case .notDetermined: return .notAsked
        @unknown default:    return .unknown
        }
    }

    private static func contacts() -> State {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:    return .granted
        case .denied,
             .restricted:    return .denied
        case .notDetermined: return .notAsked
        // macOS 15 added a "limited" grant; some access is access.
        default:             return .granted
        }
    }

    private static func events(_ type: EKEntityType) -> State {
        switch EKEventStore.authorizationStatus(for: type) {
        case .authorized,
             .fullAccess:    return .granted
        case .writeOnly:     return .granted
        case .denied,
             .restricted:    return .denied
        case .notDetermined: return .notAsked
        @unknown default:    return .unknown
        }
    }

    /// No API exists. The convention is to read something only Full Disk
    /// Access can reach; the Mail index is the usual choice because it is
    /// present on every Mac and protected on every recent macOS.
    ///
    /// A read that throws means not granted. It cannot be told apart from a
    /// genuinely missing file, so a missing path reports `.unknown` rather
    /// than claiming a denial.
    private static func fullDisk() -> State {
        let probe = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mail")
        guard FileManager.default.fileExists(atPath: probe.path) else {
            // No Mail data on this Mac; fall back to another protected store.
            let safari = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Safari/Bookmarks.plist")
            guard FileManager.default.fileExists(atPath: safari.path) else { return .unknown }
            return (try? Data(contentsOf: safari)) != nil ? .granted : .denied
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
            ? .granted : .denied
    }
}
