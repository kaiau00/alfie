import Foundation
import Testing
@testable import MoeVoice

struct WhisperFeaturesTests {

    struct Fixture: Decodable {
        let audio: [Float]
        let shape: [Int]
        let features: [Float]
    }

    private func fixture(_ name: String) throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Two fixtures: 3.5 s (left zero-pad path) and 9 s (last-8-s path,
    /// and the left reflect pad over real audio — a left-index error is
    /// invisible when the left edge is silence).
    @Test(arguments: ["whisper-features", "whisper-features-long"])
    func matchesTheReferenceRecipe(_ name: String) throws {
        let f = try fixture(name)
        #expect(f.shape == [80, 800])
        let ours = WhisperFeatures().features(for: f.audio)
        #expect(ours.count == f.features.count)
        var worst: Float = 0
        var worstAt = 0
        for i in 0..<ours.count {
            let d = abs(ours[i] - f.features[i])
            if d > worst { worst = d; worstAt = i }
        }
        // Measured: ~4e-5 (float32 sgemm DFT against float64 numpy FFT).
        // A wrong window sits at 7e-2, a wrong reflect edge at 3e-2.
        #expect(worst < 5e-4, "\(name): worst |Δ| \(worst) at \(worstAt) (mel \(worstAt / 800), frame \(worstAt % 800))")
    }

    @Test func silenceIsFinite() {
        let out = WhisperFeatures().features(for: [])
        #expect(out.count == 80 * 800)
        #expect(out.allSatisfy { $0.isFinite })
    }

    @Test func longAudioKeepsTheLastEightSeconds() {
        var audio = [Float](repeating: 0, count: 20 * 16_000)
        // A tone only in the last second: the last frames must carry it.
        for i in (19 * 16_000)..<(20 * 16_000) {
            audio[i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 16_000)
        }
        let out = WhisperFeatures().features(for: audio)
        // Mel band near 440 Hz, last frame vs a frame from the silent part.
        let band = 12
        let loud = out[band * 800 + 799]
        let quiet = out[band * 800 + 100]
        #expect(loud > quiet + 0.5)
    }
}
