import Foundation
import Testing
@testable import MoeDictation

/// The tier ordering lives in `PolishTier` (MoeDictation) so it can be tested
/// without a model, a server or a network — the same reason `CursorPrefix`
/// and `WordErrorRate` were split out. The router that consults it lives in
/// the app target and needs all three.
@Suite("PolishTier")
struct PolishTierTests {

    @Test("the default order puts speed and privacy first")
    func defaultOrder() {
        let order = PolishTier.ladder(preferred: nil)
        #expect(order == [.appleOnDevice, .localServer, .configuredBrain])
    }

    /// A preference reorders the ladder; it does not truncate it. Choosing
    /// the fastest tier on a machine that later loses it must not silently
    /// disable the rewrite.
    @Test("a preference moves to the front and the rest still follow")
    func preferenceReorders() {
        #expect(PolishTier.ladder(preferred: .configuredBrain)
                == [.configuredBrain, .appleOnDevice, .localServer])
        #expect(PolishTier.ladder(preferred: .localServer)
                == [.localServer, .appleOnDevice, .configuredBrain])
    }

    /// "Rules only" is the one preference that really is exclusive: it means
    /// "no model, ever", which is a privacy choice and must be honoured
    /// absolutely.
    @Test("rules-only tries nothing at all")
    func rulesOnlyIsExclusive() {
        #expect(PolishTier.ladder(preferred: .rulesOnly).isEmpty)
    }

    /// The Settings copy must never overstate privacy, so this is a fact
    /// about each tier rather than a sentence someone writes twice.
    @Test("only the configured brain leaves the machine")
    func onDeviceIsHonest() {
        #expect(PolishTier.appleOnDevice.isOnDevice)
        #expect(PolishTier.localServer.isOnDevice)
        #expect(PolishTier.rulesOnly.isOnDevice)
        #expect(!PolishTier.configuredBrain.isOnDevice)
    }

    @Test("every tier names an outcome, never an engine")
    func namesAreNeutral() {
        for tier in PolishTier.allCases {
            let name = tier.displayName.lowercased()
            #expect(!name.contains("apple intelligence"))
            #expect(!name.contains("ollama"))
            #expect(!name.contains("llama"))
            #expect(!name.contains("hermes"))
            #expect(!name.contains("claude"))
            #expect(!name.isEmpty)
        }
    }

    @Test("tiers round-trip through config")
    func codable() throws {
        for tier in PolishTier.allCases {
            let data = try JSONEncoder().encode(tier)
            #expect(try JSONDecoder().decode(PolishTier.self, from: data) == tier)
        }
    }
}
