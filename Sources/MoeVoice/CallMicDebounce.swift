import Foundation

/// When Moe's echo canceller gives the microphone up to a call, and when it
/// takes it back.
///
/// Voice processing flips the built-in microphone into its raw multi-channel
/// mode for every process, and a call app reading it then sends its far end
/// near-silence — so while a call has the microphone the canceller must be
/// off (`AudioFrontEnd`, "Not over a call"). Switching it costs a full graph
/// restart, and a restart stops the player: whatever Moe was saying is cut.
///
/// The rule used to be "whoever holds the microphone *this* poll". A browser
/// holds it for all sorts of things that are not calls — a page asking for a
/// second, a tab's meter, Chrome reopening its input after the device was
/// reconfigured under it. On the owner's Mac on 2026-09-24 (ticket #12)
/// Chrome came and went every 2–7 s from 15:20:37 to 15:21:09, and every
/// change restarted the graph: eight restarts in thirty-two seconds, the
/// canceller and barge-in flapping on and off with each, and any reply in
/// flight stopped mid-word.
///
/// So the two directions now wait for the signal to *hold*:
///
///  - a dedicated call app (Zoom, FaceTime, Telegram…) is still believed at
///    once — its far end hears nothing until the canceller is off, and those
///    apps do not open the microphone for anything else;
///  - a browser must hold the microphone for `browserHoldSeconds` before it
///    is treated as a call, and never takes it while Moe is talking;
///  - the canceller comes back only after the microphone has been free of
///    every call for `releaseSeconds`, and never in the middle of Moe
///    talking — waiting costs nothing, a restart costs the sentence.
///
/// Pure: the caller polls and feeds it, so the whole rule is tested with the
/// timeline measured from the log.
public struct CallMicDebounce: Equatable, Sendable {

    public struct Holder: Equatable, Sendable {
        public var name: String
        public var isBrowser: Bool
        public init(name: String, isBrowser: Bool) {
            self.name = name
            self.isBrowser = isBrowser
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Leave the graph alone.
        case keep
        /// A call has the microphone: voice processing off, for this app.
        case giveUp(String)
        /// The call is over: voice processing back on.
        case takeBack
    }

    /// A browser alone on the microphone for this long is a call. Between
    /// `MeetingDetector`'s 3 s (corroborated) and 12 s (mic alone): long
    /// enough that none of the 2–7 s grabs in the ticket's log qualify.
    public var browserHoldSeconds: Double = 10
    /// The microphone free of every call for this long: the call is over.
    public var releaseSeconds: Double = 10

    private var heldSince: Double?
    private var clearSince: Double?

    public init() {}

    /// One poll.
    /// - Parameters:
    ///   - holders: the call apps on the microphone now.
    ///   - cancellerOn: whether voice processing is currently running.
    ///   - speaking: whether Moe has audio queued or playing.
    ///   - now: seconds, any monotonic origin.
    public mutating func observe(holders: [Holder], cancellerOn: Bool,
                                 speaking: Bool, now: Double) -> Decision {
        if cancellerOn {
            clearSince = nil
            guard let first = holders.first else {
                heldSince = nil
                return .keep
            }
            if let call = holders.first(where: { !$0.isBrowser }) {
                heldSince = nil
                return .giveUp(call.name)
            }
            let since = heldSince ?? now
            heldSince = since
            guard now - since >= browserHoldSeconds, !speaking else { return .keep }
            heldSince = nil
            return .giveUp(first.name)
        }
        heldSince = nil
        guard holders.isEmpty else {
            clearSince = nil
            return .keep
        }
        let since = clearSince ?? now
        clearSince = since
        guard now - since >= releaseSeconds, !speaking else { return .keep }
        clearSince = nil
        return .takeBack
    }
}
