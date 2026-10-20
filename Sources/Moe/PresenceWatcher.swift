import AppKit
import Foundation

/// The Mac going to sleep, waking, locking, unlocking, or the app quitting.
/// The local presence file and the brain's sleep handling hang off these; the
/// official build also tells its cloud (`CloudLink.presence`).
enum PresenceEvent: CaseIterable {
    case willSleep, didWake, locked, unlocked, quit
}

/// The four observers, in one place, so the app and the CLI register exactly
/// the same thing. `Conductor.startPresence` owns one; the
/// callback runs on the main queue.
final class PresenceWatcher {
    private let handle: (PresenceEvent) -> Void
    private var observers: [NSObjectProtocol] = []

    init(_ handle: @escaping (PresenceEvent) -> Void) {
        self.handle = handle
    }

    deinit { stop() }

    /// Debug builds only: a prefix under which a test may post its OWN
    /// distributed notifications — `<prefix>.sleep`, `<prefix>.wake` — so a
    /// suite can drive the watcher end to end without posting Apple's names
    /// system-wide, which would reach the owner's running Moe too.
    static var testPrefix: String? { TestHooks.env("MOE_TEST_AWAY_NOTIFICATIONS") }


    func start() {
        stop()
        let dnc = DistributedNotificationCenter.default()
        let wnc = NSWorkspace.shared.notificationCenter
        func on(_ event: PresenceEvent) -> (Notification) -> Void {
            { [weak self] _ in self?.handle(event) }
        }
        observers = [
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                            object: nil, queue: .main, using: on(.locked)),
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                            object: nil, queue: .main, using: on(.unlocked)),
            wnc.addObserver(forName: NSWorkspace.willSleepNotification,
                            object: nil, queue: .main, using: on(.willSleep)),
            wnc.addObserver(forName: NSWorkspace.didWakeNotification,
                            object: nil, queue: .main, using: on(.didWake)),
        ]
        if let prefix = Self.testPrefix {
            observers.append(dnc.addObserver(forName: Notification.Name(prefix + ".sleep"),
                                             object: nil, queue: .main, using: on(.willSleep)))
            observers.append(dnc.addObserver(forName: Notification.Name(prefix + ".wake"),
                                             object: nil, queue: .main, using: on(.didWake)))
        }
    }

    func stop() {
        for o in observers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers = []
    }
}
