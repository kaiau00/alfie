import Foundation

/// Whether a microphone-meter reading is worth telling the UI about.
///
/// This is one `if`, and it is a type because of what sits behind it.
/// `Conductor.level` is `@Published`, `Conductor` is `ObservableObject`, and
/// twenty-one views hold it as `@ObservedObject`. `ObservableObject` has no
/// per-property tracking: one assignment to any `@Published` property sends
/// one `objectWillChange`, and every one of those views re-evaluates its
/// body. So this decision is not "should the meter update" — it is "should
/// the entire application re-render", fifteen times a second, for as long as
/// the audio graph is up.
///
/// It was answered "yes, always" until a profile of an idle Moe found
/// `LayoutEngineBox.sizeThatFits` sitting above every neural network in the
/// process. A gate that lives inside a closure inside `Conductor.wire()`
/// cannot be tested — nothing in the suite can build a `Conductor` — so it
/// lives here instead, where `MicMeterGateTests` can hold it to its side
/// effect rather than to whether it was reached.
public enum MicMeterGate {

    /// The smallest change worth a redraw.
    ///
    /// Below what the meter can show: `IslandView.notchHalo` turns the level
    /// into a 7 pt spread animated over 0.09 s, so a hundredth of the range
    /// is a fifteenth of a point. It is float noise off a silent microphone,
    /// and it costs a full layout pass.
    public static let step: Float = 0.01

    /// The value to publish, or `nil` to publish nothing.
    ///
    /// - Parameters:
    ///   - reading: what the pipeline heard, 0…1.
    ///   - listening: whether anything actually renders the number. The
    ///     island reads it only in `.listening` (`notchHalo` computes
    ///     `drive = listening ? voice : (idle ? 0 : 0.4)`, and `StateDot`
    ///     grows on it only in that mode), so off the microphone this is not
    ///     a dimmed meter, it is an unread one.
    ///   - muted: the person muted themselves. Nothing on screen may follow
    ///     the microphone then (2026-09-25: the halo pulsed with the owner's
    ///     voice while muted, which reads as "it can hear me"), so the UI is
    ///     handed zero whatever the pipeline hears.
    ///   - current: what the UI already has.
    ///
    /// Returning `nil` for "no change" rather than the old value is
    /// deliberate: `@Published` does not de-duplicate, so a caller handed
    /// `0` when it already holds `0` would assign it and fire anyway. The
    /// only way to publish nothing is to have nothing to assign.
    public static func next(reading: Float, listening: Bool, muted: Bool = false,
                            current: Float) -> Float? {
        let wanted = listening && !muted ? reading : 0
        return abs(wanted - current) >= step ? wanted : nil
    }
}
