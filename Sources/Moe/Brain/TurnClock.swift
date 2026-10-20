import Foundation
import MoeBrain

/// The clock every turn is stamped with (ticket #9): the Mac's own zone,
/// followed as it changes.
///
/// Stamped in ONE place — `HermesBrain.pumpLocked`, where every turn's text
/// becomes a request — never at the callers. A stamp at the callers was the
/// first version, and three routes walked past it: the sleep re-issue (which
/// resends the saved text, old Now line and all), the resume priming, and a
/// new `bridge.send` on another branch. A guard that enumerates callers is
/// walked past by the next caller; the request is the one thing every turn
/// becomes.
enum TurnClock {
    /// Tests put a fixed clock here.
    nonisolated(unsafe) static var source: () -> (now: Date, zone: TimeZone) = live

    static func now() -> Date { source().now }
    static func zone() -> TimeZone { source().zone }

    /// `text` with a fresh Now line first and any older one removed.
    static func stamped(_ text: String) -> String {
        stamps.withLock { $0 += 1 }
        let c = source()
        return NowLine.stamp(text, at: c.now, zone: c.zone)
    }

    /// The real clock, or — in a debug build only — `MOE_TEST_NOW` (ISO
    /// 8601) advanced by `MOE_TEST_NOW_STEP_MINUTES` for every turn stamped, so
    /// `scripts/test-now-line.sh` can tell a re-issue's line from the
    /// original's. `MOE_TEST_TZ` names the zone.
    static func live() -> (now: Date, zone: TimeZone) {
        let zone = TestHooks.env("MOE_TEST_TZ").flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        guard let start = TestHooks.env("MOE_TEST_NOW").flatMap(parse) else { return (Date(), zone) }
        let step = TestHooks.env("MOE_TEST_NOW_STEP_MINUTES").flatMap(Double.init) ?? 0
        let n = max(0, stamps.withLock { $0 } - 1)
        return (start.addingTimeInterval(Double(n) * step * 60), zone)
    }

    private static let stamps = Locked(0)

    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// A value behind a lock, for the test clock's read counter.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
