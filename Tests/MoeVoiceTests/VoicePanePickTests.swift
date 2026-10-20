import Testing
@testable import MoeVoice

/// Settings › Voice showed Kokoro after reopening on a Mac that was speaking
/// with the premium voice (2026-09-22).
struct VoicePanePickTests {

    /// Opening the pane moves the picker from its placeholder to the saved
    /// engine. That fired the change handler, which reset the voice to the
    /// engine's default ("Clive" over the saved "Ashley") and could bounce
    /// the pick back to Kokoro.
    @Test func thePaneLoadingIsNotAPick() {
        #expect(VoicePanePick.engineChange(to: "inworld", saved: "inworld") == .loaded)
        #expect(VoicePanePick.engineChange(to: "pocket", saved: "inworld") == .picked)
        #expect(VoicePanePick.engineChange(to: "kokoro", saved: "inworld") == .picked)
    }

    @Test func aPlanStillLoadingIsNotFree() {
        #expect(VoicePanePick.cloudPick(mayUse: false, liveTier: nil, cachedTier: nil) == .turnOn)
        #expect(VoicePanePick.cloudPick(mayUse: false, liveTier: nil, cachedTier: "away") == .turnOn)
        #expect(VoicePanePick.cloudPick(mayUse: false, liveTier: nil, cachedTier: "free") == .upgrade)
        #expect(VoicePanePick.cloudPick(mayUse: false, liveTier: "free", cachedTier: "away") == .upgrade)
        #expect(VoicePanePick.cloudPick(mayUse: false, liveTier: "pro", cachedTier: nil) == .turnOn)
        #expect(VoicePanePick.cloudPick(mayUse: true, liveTier: "free", cachedTier: nil) == .use)
    }
}
