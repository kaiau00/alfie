import Foundation
import Testing
@testable import MoeVoice

/// Step 1.5: the wake head fires, the local recogniser reads what it fired
/// on, and Moe wakes only if the name is in it.
struct WakeConfirmTests {

    let spotter = WakeSpotter(phrases: WakeSpotter.defaultPhrases)

    /// How a recogniser is expected to write "Hey Alfie" (not yet measured on
    /// recordings, unlike upstream's Moe list).
    @Test func theNameInTheWaysTheRecogniserWritesIt() {
        for said in ["hey alfie", "Hey Alfy.", "Hey, Alfie, what's the weather?", "Healfie, what time is it",
                     "heyalfie", "okay alfie", "so um hey alfie", "Alfi.", "Hey Alphie!", "Hey Alfee."] {
            #expect(WakeConfirm.heardTheName(said, spotter: spotter), "\(said)")
        }
    }

    /// What the head fires on that is not the name, written by the
    /// recogniser as what it is: "how are you" scored 0.83 on the head
    /// against a real wake's 0.76–0.92, and the Inworld confusables "Hey
    /// Molly", "Hey Mode", "Hey Moses", "Hey Mom", "Hey Mona" were 60 of its
    /// 117 false fires there.
    @Test func lookalikesTheHeadFiresOnAreTurnedAway() {
        for said in ["how are you", "hey alpha", "a moment please", "hey make it louder", "tell me more",
                     "Hey Ollie.", "Hey Allie.", "Hey Elfie.", "Hey Albie.", "Hey Alfred.", "Hey, selfie.",
                     "Hey, coffee.", "hey man", "Hey, half.", "the amount is due", "", "okay"] {
            #expect(!WakeConfirm.heardTheName(said, spotter: spotter), "\(said)")
        }
    }

    @Test func theHeadListensLowerOnlyWhileEveryHitIsConfirmed() {
        let shipped = WakePolicy(threshold: 0.95, strongThreshold: 0.95, requiredHits: 2)
        let lower = WakeConfirm.headPolicy(shipped, confirming: true, threshold: 0.7)
        #expect(lower.threshold == 0.7)
        #expect(lower.requiredHits == 2)
        #expect(WakeConfirm.headPolicy(shipped, confirming: false, threshold: 0.7).threshold == 0.95)
        // A per-Mac calibration already under it stands.
        let calibrated = shipped.withThreshold(0.6)
        #expect(WakeConfirm.headPolicy(calibrated, confirming: true, threshold: 0.7).threshold == 0.6)
    }
}
