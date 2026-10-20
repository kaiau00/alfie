import Foundation

/// When the cloud recogniser mints its next session credential ahead of a
/// turn.
///
/// A token is single-use and lives sixty seconds, and minting one is a round
/// trip to the edge. Paid inside a turn, that round trip is the turn: on
/// 2026-10-01 02:45:50 it took 5646 ms, the session opened late, and the read
/// was garbled (`AssemblyAIStream.liveWait`). The prefetch used to stop five
/// minutes after a warm-up; but with "Hey Moe" listening a turn can begin at
/// any moment, so while it is on one fresh token is always held — one edge
/// request per token lifetime, and none while a session is open (a token
/// minted then would expire before it was wanted).
public enum CredentialPrefetch {

    public enum Step: Equatable {
        case mint
        case wait(Double)
        case stop
    }

    /// A held token with less than this left is replaced. `take()` refuses
    /// one under eight seconds; the rest is the mint's own round trip.
    public static let refreshBelowSeconds: Double = 15
    /// How often the loop looks again while it has nothing to do.
    public static let pollSeconds: Double = 5
    /// Rest after a failed mint, by failures in a row: an edge that is down
    /// is not asked every five seconds.
    public static let backoffLadder: [Double] = [5, 15, 30, 60]

    public static func next(now: Date, windowUntil: Date, wakeWordOn: Bool, sessionOpen: Bool,
                            heldExpiresAt: Date?, failuresInARow: Int, lastFailureAt: Date?) -> Step {
        guard now < windowUntil || wakeWordOn else { return .stop }
        if sessionOpen { return .wait(pollSeconds) }
        if let at = heldExpiresAt, at.timeIntervalSince(now) > refreshBelowSeconds {
            return .wait(min(pollSeconds, at.timeIntervalSince(now) - refreshBelowSeconds))
        }
        if failuresInARow > 0, let failed = lastFailureAt {
            let rest = backoffLadder[min(failuresInARow - 1, backoffLadder.count - 1)]
            let left = rest - now.timeIntervalSince(failed)
            if left > 0 { return .wait(min(pollSeconds, left)) }
        }
        return .mint
    }
}
