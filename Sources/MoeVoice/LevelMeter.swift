import Foundation

/// Turns raw loudness into "is this person actually speaking", for the glow.
///
/// A plain RMS meter twitches at room tone and looks like it is reacting to
/// nothing. This tracks the quiet floor of the room and only registers what
/// rises clearly above it, then smooths with a fast attack and slow release
/// so the light moves the way a voice does rather than flickering.
public struct LevelMeter: Sendable {
    private var noiseFloorDb: Float = -55
    public private(set) var level: Float = 0

    public init() {}

    /// Feed one frame's RMS in dBFS; read `level` (0…1) after.
    public mutating func update(db: Float) {
        // Follow the floor down quickly, let it drift up slowly.
        if db < noiseFloorDb {
            noiseFloorDb = noiseFloorDb * 0.90 + db * 0.10
        } else {
            noiseFloorDb = noiseFloorDb * 0.999 + db * 0.001
        }
        noiseFloorDb = max(-70, min(noiseFloorDb, -25))

        // Speech has to clear the floor by a real margin to count.
        let over = db - (noiseFloorDb + 8)
        let target = max(0, min(1, over / 26))

        let rate: Float = target > level ? 0.55 : 0.12
        level += (target - level) * rate
    }

    /// dBFS of a block of samples.
    public static func db(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -100 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        let rms = (sum / Float(samples.count)).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }
}
