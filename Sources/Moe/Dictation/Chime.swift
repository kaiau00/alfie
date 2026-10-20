import AppKit
import AVFoundation
import Foundation

/// The three small sounds of dictation: a rising two-tone as recording
/// starts, a falling one as it stops, a low tick when it is cancelled.
///
/// Made, not shipped: the tones are synthesised once at launch (a 25 ms
/// attack and 90 ms release, so nothing clicks or pings), written to four
/// small files under Moe's cache, and played with `NSSound`.
///
/// Why files and `NSSound`, and not an `AVAudioEngine` of this class's own,
/// which is what it was until 2026-09-19: `AVAudioPlayerNode.play` raises an
/// Objective-C exception — which Swift cannot catch — whenever the engine
/// is not truly running, and after a sleep it is not, whatever `isRunning`
/// says: the output device has not started delivering cycles yet. Twice on
/// the owner's Mac an answer that finished during a lid close chimed on wake
/// and the app aborted ("player did not see an IO cycle"; crash reports
/// Moe-2026-09-19-203324 and -214304). `NSSound.play()` returns false in
/// every such state and throws in none of them, and it takes no device
/// state with it: no engine, no input node, nothing the microphone graph
/// can be fighting.
@MainActor
final class Chime {

    /// `reply` is not dictation's: it is the note an answer makes when Moe
    /// is not going to speak it (`Conductor.announce`). It lives here because
    /// this is the app's one tone generator.
    ///
    /// `halt` is the talk key's stop (`Conductor.confirmStopped`): two quick
    /// falling notes, lower than anything else here, so "everything
    /// stopped" is never heard as dictation stopping or an answer arriving.
    enum Kind: String { case start, stop, cancel, reply, halt }

    /// Master volume; the chimes are meant to be felt more than heard.
    var volume: Float = 0.10

    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var files: [Kind: URL] = [:]
    private var playing: NSSound?

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-chimes-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notes: [(Kind, [(hz: Double, seconds: Double)])] = [
            (.start,  [(523.25, 0.16)]),   // C5
            (.stop,   [(392.00, 0.16)]),   // G4
            (.cancel, [(261.63, 0.10)]),   // C4
            // E5 — above the dictation pair and shorter, so "your answer is
            // here" is never mistaken for "the microphone opened".
            (.reply,  [(659.25, 0.12)]),
            // E4 then A3: the only two-note sound, and the only falling one.
            (.halt,   [(329.63, 0.07), (220.00, 0.09)]),
        ]
        for (kind, tones) in notes {
            guard let buffer = Self.render(tones, format: format) else { continue }
            let url = dir.appendingPathComponent(kind.rawValue + ".caf")
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
                files[kind] = url
            } catch {
                Log.write("chime: could not write \(kind.rawValue): \(error.localizedDescription)")
            }
        }
    }

    /// The rendered file for a tone, for the test that checks they exist.
    func fileForTests(_ kind: Kind) -> URL? { files[kind] }

    /// Play one chime. Never throws and never blocks: no output device, or
    /// one that is not ready yet, costs a log line, not the app.
    func play(_ kind: Kind) {
        guard let url = files[kind], let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = volume
        playing?.stop()
        playing = sound
        if sound.play() {
            Log.write("chime: \(kind.rawValue)")
        } else {
            Log.write("chime: \(kind.rawValue) could not play (no output device ready)")
        }
    }

    /// Pure tones one after another, each with its own raised-cosine (Hann)
    /// envelope over a single phase accumulator: every note starts and ends
    /// at exactly zero, so nothing clicks where one meets the next — the
    /// "scratch" of the first version was two notes butted together with a
    /// phase jump and no envelope between them.
    private static func render(_ notes: [(hz: Double, seconds: Double)],
                               format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let lengths = notes.map { Int($0.seconds * rate) }
        let total = lengths.reduce(0, +)
        guard total > 0, lengths.allSatisfy({ $0 > 1 }),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        var phase = 0.0
        var at = 0
        for (note, n) in zip(notes, lengths) {
            let step = 2 * Double.pi * note.hz / rate
            for i in 0..<n {
                // Hann window: gentle in, gentle out, symmetric.
                let env = 0.5 * (1 - cos(2 * .pi * Double(i) / Double(n - 1)))
                out[at + i] = Float(env * sin(phase))
                phase += step
            }
            at += n
        }
        return buffer
    }
}
