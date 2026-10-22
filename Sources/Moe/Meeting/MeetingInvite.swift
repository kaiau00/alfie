import AppKit
import EventKit
import Foundation
import MoeMeeting

/// The one EventKit call meeting mode makes: who is on the invite for the
/// meeting happening now (MEETING-MODE.md, Phase B step 1).
///
/// Everything that decides anything — which event, which attendee is the
/// user, which name goes on which voice — is pure and lives in
/// `MoeMeeting/SpeakerNames.swift`, tested without EventKit. This file only
/// turns `EKEvent` into `CalendarEventInfo` and hands it over.
///
/// **Never prompts.** Calendar access is asked for from the Meetings pane,
/// by a person who pressed a button, or by `Moe --eventkit-request` (see
/// `EventKitBridge`). Raising a system sheet in the middle of starting a
/// recording is the wrong moment for it, and a meeting must start whatever
/// the answer would have been. No access is an ordinary path: no attendees,
/// no names, the transcript exactly as it reads today.
enum MeetingInvite {

    enum Access: Equatable {
        /// Full access; the invite can be read.
        case granted
        /// Never asked. The pane can offer to ask.
        case notDetermined
        /// Refused, restricted, or write-only. The pane can point at
        /// System Settings; nothing else changes.
        case denied
    }

    static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// How far either side of "now" to look for the meeting's event. Wide
    /// enough that a long call started late is still inside its event,
    /// narrow enough to stay cheap.
    static let searchWindow: TimeInterval = 12 * 3600

    /// The invite for the meeting starting at `now`: its title and the
    /// people on it. Empty on every path that is not "access granted and an
    /// event with attendees is running".
    static func invite(at now: Date = Date()) -> (title: String, attendees: [MeetingAttendee])? {
        guard access == .granted else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-searchWindow),
                                                 end: now.addingTimeInterval(searchWindow),
                                                 calendars: nil)
        let events = store.events(matching: predicate).map(info(for:))
        guard let event = MeetingCalendar.pick(from: events, at: now) else { return nil }
        return (event.title, event.attendees)
    }

    static func info(for event: EKEvent) -> CalendarEventInfo {
        CalendarEventInfo(title: event.title ?? "",
                          start: event.startDate ?? .distantPast,
                          end: event.endDate ?? .distantPast,
                          isAllDay: event.isAllDay,
                          attendees: (event.attendees ?? []).map { attendee($0, organiser: event.organizer) })
    }

    static func attendee(_ p: EKParticipant, organiser: EKParticipant?) -> MeetingAttendee {
        // `url` is `mailto:dan@acme.com` for an ordinary invitee; for a
        // room or a resource it can be anything, and then there is no
        // address to fall back on.
        var email: String?
        let raw = p.url.absoluteString
        if raw.lowercased().hasPrefix("mailto:") {
            let address = String(raw.dropFirst("mailto:".count))
            if address.contains("@") { email = address.removingPercentEncoding ?? address }
        }
        return MeetingAttendee(name: p.name, email: email,
                               // `isCurrentUser` is the calendar's own
                               // answer to "is this you", and it is the only
                               // reliable one: matching on a name guesses.
                               isSelf: p.isCurrentUser,
                               isOrganiser: organiser.map { $0.url == p.url } ?? false)
    }

    /// The Meetings pane's "use my calendar" button, and only that: a
    /// person asked, so the sheet is theirs. Returns whether it is granted
    /// afterwards.
    @MainActor
    static func requestAccess() async -> Bool {
        switch access {
        case .granted:
            return true
        case .denied:
            NSWorkspace.shared.open(settingsURL)
            return false
        case .notDetermined:
            let store = EKEventStore()
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            Log.write("meeting: calendar access \(granted ? "granted" : "not granted")")
            return granted
        }
    }

    /// System Settings › Privacy & Security › Calendars.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    /// The line the Meetings pane shows when names could come from the
    /// calendar and do not yet. Plain, and never an error.
    static var offer: String? {
        switch access {
        case .granted: return nil
        case .notDetermined:
            return "Alfie can put people's names in your notes by reading who was invited."
        case .denied:
            return "Alfie could put people's names in your notes, but it is not allowed to read your calendar."
        }
    }
}
