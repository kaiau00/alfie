import Foundation

/// The decisions Settings › Voice makes about the picker, pulled out of the
/// view so they are tests. Found 2026-09-22: the pane showed Kokoro after
/// reopening on a Mac speaking with the premium voice, for three reasons —
/// a stale copy of the config (fixed where the save happens, in the
/// Conductor), the picker's own change handler firing on the value the pane
/// loaded, and a still-loading plan status read as "free".
public enum VoicePanePick {

    /// What a change of the engine picker is.
    public enum EngineChange: Equatable, Sendable {
        /// The picker moved to the engine that is saved — the pane opening,
        /// or the person going back to it. Its saved voice comes back with
        /// it; nothing is reset to a default and nothing is gated (it is
        /// what this Mac already uses).
        case loaded
        /// A different engine was picked.
        case picked
    }

    /// Stateless on purpose: a "the pane is loading" latch goes stale if
    /// SwiftUI never delivers the change it was waiting for, and then eats
    /// the person's own pick (review L5).
    public static func engineChange(to new: String, saved: String) -> EngineChange {
        saved == new ? .loaded : .picked
    }

    /// The person picked the cloud voice. What happens next.
    public enum CloudPick: Equatable, Sendable {
        /// This Mac may use it: carry on.
        case use
        /// The plan has it but the switch is off: turn it on.
        case turnOn
        /// The plan does not have it: send them to the plan, keep the old pick.
        case upgrade
    }

    /// - Parameters:
    ///   - mayUse: `CloudVoice.mayUse(.tts)` right now.
    ///   - liveTier: the plan from the live status, nil while it is loading.
    ///   - cachedTier: the last plan honoured on this Mac, nil if none.
    ///
    /// Unknown is not free. A status that has not arrived yet used to read
    /// as "free", bounce the pick back to the local voice and open the plan
    /// page on a Mac that is paying for the premium one.
    public static func cloudPick(mayUse: Bool, liveTier: String?, cachedTier: String?) -> CloudPick {
        if mayUse { return .use }
        guard let tier = liveTier ?? cachedTier else { return .turnOn }
        return tier == "free" ? .upgrade : .turnOn
    }
}
