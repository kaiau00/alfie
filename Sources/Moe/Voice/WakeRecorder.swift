import AVFoundation
import Foundation
import MoeVoice

/// Recording the wake word in the room it has to work in.
///
/// The head that ships was trained entirely on synthesised speech, and it
/// shows: 56 of 72 held-out positives, 6 false accepts across 48 confusable
/// phrases. Both numbers are a data problem rather than a model one — no
/// recording of the person who actually says the name, in the room they
/// actually say it in, went into it. "Real recordings would fix this" has
/// been true and unowned for a while, because the ask was a paragraph of
/// instructions rather than something a person could sit down and do.
///
/// So this is the ask, made concrete: it prints a line, waits until you say
/// it, saves it where the trainer and `--wake-bench` already look, and moves
/// on. Ten minutes end to end. Nothing here decides anything about the wake
/// head; it only collects, and says what it collected.
enum WakeRecorder {

    /// One thing to say, and which pile it belongs in.
    struct Prompt: Sendable {
        let say: String
        let note: String
        let folder: String
    }

    /// The script.
    ///
    /// Three piles, and the middle one is the one that is usually missing.
    /// A wake head learns "that is the name" from positives and "that is not
    /// the name" from ordinary speech, but the errors people actually notice
    /// are the near misses — a phrase one phoneme away that fires anyway.
    /// Those have to be said out loud by the same voice in the same room, or
    /// the model never sees the distinction it is being asked to draw.
    ///
    /// Positives vary the things that changed between training and the
    /// kitchen: distance, level, speed, and whether the name stands alone or
    /// is buried in a sentence. A phrase that only ever appears after
    /// silence teaches "speech begins" — which is exactly the failure the
    /// first four training runs had.
    static func script() -> [Prompt] {
        var out: [Prompt] = []

        func positives(_ note: String, _ n: Int, _ lines: [String]) {
            for i in 0..<n {
                out.append(Prompt(say: lines[i % lines.count], note: note, folder: "positive"))
            }
        }

        let plain = ["Hey Alfie"]
        positives("normally, as if you were asking for something", 10, plain)
        positives("quietly, the way you would talk at night", 8, plain)
        positives("from across the room", 8, plain)
        positives("quickly, running the words together", 6, plain)
        positives("slowly and clearly", 4, plain)
        positives("turned away from the Mac", 6, plain)

        // The name inside a sentence: this is how it is really used, and a
        // head trained only on the isolated phrase misses it.
        positives("as a whole sentence, at your normal pace", 12, [
            "Hey Alfie, what's on my calendar",
            "Hey Alfie, remind me to call the bank",
            "Hey Alfie, what's the weather like",
            "Okay hey Alfie, open my notes",
            "Hey Alfie, can you check my email",
            "Hey Alfie, what time is that meeting",
        ])

        // Near misses. Every one of these is a phrase the current head has
        // fired on, or is a phoneme away from one.
        for line in ["Hey alpha", "Hey Elfie", "Hey Ollie", "Hey Allie",
                     "Hey Albie", "Hey Alfred", "Hey, selfie", "Hey, half",
                     "Hey Archie", "Hey, coffee", "Alfie", "Say Alfie",
                     "Hey, also", "Hey after", "Hey, all three", "Hey Ralphie"] {
            out.append(Prompt(say: line, note: "a near miss — say it naturally, do not over-enunciate",
                              folder: "confusable"))
            out.append(Prompt(say: line, note: "again, a little faster", folder: "confusable"))
        }

        // Ordinary speech, so the head hears what a room sounds like when
        // nobody wants anything. Content does not matter; length does.
        for line in ["Say a sentence about what you did this morning",
                     "Read out the last email you remember",
                     "Describe what is on your desk right now",
                     "Say what you are planning to do this evening",
                     "Count slowly from one to fifteen",
                     "Say anything at all for about ten seconds"] {
            out.append(Prompt(say: line, note: "ordinary speech, no wake word", folder: "negative"))
        }

        return out
    }

    /// The short form, for Settings › Voice › "Teach Moe its name": twelve
    /// with the name and eight near misses, about two minutes. Enough to
    /// choose a threshold for one voice in one room (`WakeCalibration`),
    /// not enough to retrain on — the Terminal script above is that.
    static func shortScript() -> [Prompt] {
        var out: [Prompt] = []
        func positive(_ note: String, _ n: Int, _ lines: [String] = ["Hey Alfie"]) {
            for i in 0..<n { out.append(Prompt(say: lines[i % lines.count], note: note, folder: "positive")) }
        }
        positive("normally, as if you were asking for something", 3)
        positive("quietly, the way you would talk at night", 2)
        positive("from across the room", 2)
        positive("quickly, running the words together", 1)
        positive("slowly and clearly", 1)
        positive("as a whole sentence, at your normal pace", 3, [
            "Hey Alfie, what's on my calendar",
            "Hey Alfie, what's the weather like",
            "Hey Alfie, remind me to call the bank",
        ])
        for line in ["Hey Joe", "Hey no", "Hey more", "Hey mole", "A moment", "Hey homie", "Hey Mona", "Hey Mom"] {
            out.append(Prompt(say: line, note: "a near miss — say it naturally", folder: "confusable"))
        }
        return out
    }

    /// A 16 kHz mono WAV, where `--wake-bench` and the trainer both look.
    static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: AudioPipeline.rate,
                                   channels: 1,
                                   interleaved: false)!
        let file = try AVAudioFile(forWriting: url,
                                   settings: [
                                       AVFormatIDKey: kAudioFormatLinearPCM,
                                       AVSampleRateKey: AudioPipeline.rate,
                                       AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false,
                                   ],
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            throw NSError(domain: "WakeRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not allocate a buffer"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                buffer.floatChannelData![0].update(from: base, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }

    /// Cut a clip down to the speech in it, plus a margin either side.
    ///
    /// `from` and `to` are seconds into the same capture, taken when the
    /// VAD reported the start and the end. The margins are deliberately
    /// lopsided: a wake word loses its last consonant more easily than its
    /// first, because the VAD reports the end about a quarter second late
    /// and a person's voice trails off before it does.
    static func trim(_ samples: [Float], from: Double, to: Double,
                     head: Double, tail: Double) -> [Float] {
        let rate = AudioPipeline.rate
        let first = max(0, Int((from - head) * rate))
        let last = min(samples.count, Int((to + tail) * rate))
        guard last > first else { return samples }
        return Array(samples[first..<last])
    }

    /// Peak, for the "that was too quiet" check. A clip that is all floor
    /// teaches the model nothing, and a pile of them quietly moves the
    /// threshold under every clip recorded beside them.
    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }
}

/// Whether the VAD currently hears speech.
///
/// The pipeline reports starts and ends on its own actor; the recorder
/// waits on them from another. One box, so neither has to know about the
/// other's isolation.
actor SpeechGate {
    private(set) var on = false
    func set(_ value: Bool) { on = value }
}
