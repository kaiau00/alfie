import AVFoundation
import Foundation

// Bits shared by the system tap and the mic capture: a thread-safe level
// meter, a streaming resampler to the 16 kHz mono Float format the ASR and
// diarizer want, a sample sink that streams straight to a WAV file, and a
// WAV reader. Proven in the MeetingTap spike (MEETING-MODE.md) and moved
// here unchanged in behaviour.

/// The one format everything downstream (FluidAudio ASR + diarization) wants.
public let meetingSampleRate: Double = 16_000
let targetFormat = AVAudioFormat(standardFormatWithSampleRate: meetingSampleRate, channels: 1)!

// MARK: - Level meter

public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum: Double = 0
    private var count: Int = 0
    private var peak: Float = 0
    private var sounded = false

    public init() {}

    /// Whether one non-zero sample has ever reached this meter — unlike
    /// `peak`, which `drain` clears every hundred milliseconds.
    ///
    /// This is the whole difference between a stream that is quiet and a
    /// stream that is dead, and nothing else measured it. A broken process
    /// tap delivers buffers on time, of the right length, in the right
    /// format, with every sample exactly `0.0`: buffer counts and frame
    /// counts both say it is working, which is why `tapIsDelivering`
    /// reported a healthy tap through 59,153,310 frames of silence. Only
    /// "did any sample have a value" tells them apart.
    public var everSounded: Bool { lock.lock(); defer { lock.unlock() }; return sounded }

    /// Forget that, so the next stretch is judged on its own. Called when
    /// the tap is rebuilt: the old tap's sound says nothing about the new
    /// one's.
    public func resetSounded() { lock.lock(); sounded = false; lock.unlock() }

    func add(_ samples: UnsafeBufferPointer<Float>) {
        var localSum: Double = 0
        var localPeak: Float = 0
        for v in samples {
            localSum += Double(v * v)
            localPeak = max(localPeak, abs(v))
        }
        lock.lock()
        sum += localSum
        count += samples.count
        peak = max(peak, localPeak)
        if localPeak > 0 { sounded = true }
        lock.unlock()
    }

    /// Returns (rms dBFS, peak dBFS, frames) since the last drain.
    public func drain() -> (rms: Float, peak: Float, frames: Int) {
        lock.lock()
        let s = sum, c = count, p = peak
        sum = 0; count = 0; peak = 0
        lock.unlock()
        guard c > 0 else { return (-200, -200, 0) }
        let rms = (s / Double(c)).squareRoot()
        return (db(Float(rms)), db(p), c)
    }

    private func db(_ x: Float) -> Float { 20 * log10(max(x, 1e-10)) }
}

// MARK: - Sample sink: 16 kHz mono, streamed to a WAV file as it arrives

/// Receives 16 kHz mono Float buffers from an IO thread and writes them to
/// a 16-bit WAV straight away, so an hour-long meeting costs 115 MB of disk
/// per stream and nothing in RAM. The header is written with zero sizes and
/// patched in `close()`.
///
/// Every stream is padded with silence up to its first buffer, measured
/// from a shared `epoch`, so `t = 0` in system.wav and mic.wav is the same
/// instant even though the tap comes up hundreds of ms after the mic.
public final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let epoch: Date
    public let url: URL
    public let meter = LevelMeter()
    private var closed = false
    private var first: Date?
    private var nBuffers = 0
    private var nFrames = 0
    private var leadFrames = 0
    private var mutedFlag = false
    /// Scratch for the 16-bit conversion, grown once and reused: the
    /// audio callbacks must not allocate per buffer.
    private var scratch = [Int16](repeating: 0, count: 8192)

    /// Off the record: while set, incoming audio is replaced by silence of
    /// the same length — the timeline stays aligned, the content is gone
    /// before it reaches the disk. Never a level reading either.
    public var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return mutedFlag }
        set { lock.lock(); mutedFlag = newValue; lock.unlock() }
    }

    /// Wall-clock time the first buffer arrived, for latency reporting.
    public var firstBufferAt: Date? { lock.lock(); defer { lock.unlock() }; return first }
    public var buffers: Int { lock.lock(); defer { lock.unlock() }; return nBuffers }
    /// Frames written to the file, leading silence included.
    public var count: Int { lock.lock(); defer { lock.unlock() }; return nFrames }
    /// Frames of leading silence the stream was padded with.
    public var leadingSilenceFrames: Int { lock.lock(); defer { lock.unlock() }; return leadFrames }
    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    public init(url: URL, epoch: Date) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
        self.epoch = epoch
        try handle.write(contentsOf: Wav.header(dataBytes: 0))
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let ptr = UnsafeBufferPointer(start: data, count: n)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if !mutedFlag { meter.add(ptr) }
        if first == nil {
            let now = Date()
            first = now
            let lead = Int(max(0, now.timeIntervalSince(epoch)) * meetingSampleRate)
            leadFrames = lead
            if lead > 0 { write([Int16](repeating: 0, count: lead)) }
        }
        nBuffers += 1
        if scratch.count < n { scratch = [Int16](repeating: 0, count: n) }
        if mutedFlag {
            for i in 0..<n { scratch[i] = 0 }
        } else {
            for i in 0..<n { scratch[i] = Int16(max(-1, min(1, ptr[i])) * 32767) }
        }
        // write(2) straight from the scratch buffer: no Data, no copy.
        scratch.withUnsafeBytes { _ = Darwin.write(handle.fileDescriptor, $0.baseAddress, n * 2) }
        nFrames += n
    }

    /// Whether audio with a value in it has ever reached this stream.
    /// `buffers` and `count` cannot answer this: a dead process tap keeps
    /// both of them climbing with buffers of exact zeros.
    public var hasSound: Bool { meter.everSounded }

    /// Judge the next stretch on its own — after the tap behind this sink
    /// has been destroyed and rebuilt.
    public func forgetSound() { meter.resetSounded() }

    /// Write silence up to where the wall clock says this stream should be,
    /// and return how many frames that took.
    ///
    /// A stream is padded once, at its first buffer, so both files start at
    /// the same instant. A stream that then *stops* delivering has no such
    /// protection: the seconds it missed simply are not in the file, so it
    /// ends up short and every timestamp after the gap is early by the
    /// length of it — the transcript's clock and the diarizer's spans both
    /// read off frame counts. Rebuilding a dead tap without this would move
    /// every remaining "them" line earlier than it was said.
    @discardableResult
    public func padToNow(_ now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return 0 }
        // Nothing has arrived at all yet: `append` will do the padding from
        // the epoch itself, and doing it here would make it happen twice.
        guard first != nil else { return 0 }
        let want = Int(max(0, now.timeIntervalSince(epoch)) * meetingSampleRate)
        let gap = want - nFrames
        guard gap > 0 else { return 0 }
        write([Int16](repeating: 0, count: gap))
        return gap
    }

    /// Patches the RIFF/data sizes and closes the file. Idempotent.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Wav.header(dataBytes: UInt32(nFrames * 2)))
        try? handle.close()
    }

    private func write(_ pcm: [Int16]) {
        pcm.withUnsafeBytes { try? handle.write(contentsOf: Data($0)) }
        nFrames += pcm.count
    }

    deinit { close() }
}

// MARK: - Streaming resampler → 16 kHz mono

/// Wraps AVAudioConverter so each incoming buffer (any rate, interleaved or
/// not) comes out as 16 kHz mono Float.
///
/// How the channels are reduced is **not** left to the converter's defaults,
/// because those are not what the name suggests. Measured on macOS 26 with
/// synthetic buffers — a tone on exactly one channel, everything else zero
/// (`ResamplerChannelTests`, which is the executable form of this comment):
///
///   * **2 → 1 is not an average.** The converter takes channel 0 and drops
///     channel 1 entirely (tone on ch0: -9.0 dBFS out; tone on ch1: digital
///     silence). `downmix = true` is what averages them, and then both
///     survive at -15.0 dBFS. This module used to claim "L/R averaged" and
///     was silently discarding the right channel of every stereo source —
///     including the system tap, whose format is 48 kHz **stereo**.
///   * **N → 1 for N > 2 comes back as digital silence.** Not an error: the
///     status is `.inputRanDry`, `error` is nil, the output buffer is the
///     right length and every sample in it is zero. `downmix = true` does
///     not rescue it (except on a `UseChannelDescriptions` layout, where it
///     degenerates to channel 0 again). Only an explicit `channelMap` gets
///     audio out of a bus that wide.
///
/// So: a caller with more than two channels must say which one it wants
/// (`channel:`), and asking for a plain multi-channel conversion fails at
/// init rather than quietly writing an hour of zeros to disk.
public final class Resampler {
    private let converter: AVAudioConverter
    private let ratio: Double
    /// Reused across calls: the sink copies what it needs synchronously,
    /// so one output buffer per resampler is enough and nothing is
    /// allocated per callback. Not safe to call from two threads at once —
    /// each capture has its own.
    private var out: AVAudioPCMBuffer?

    /// `channel` names a single source channel to take, for a bus wider than
    /// stereo. Nil means "reduce whatever this is": mono passes through,
    /// stereo is averaged, and anything wider is refused.
    public init?(from source: AVAudioFormat, channel: Int? = nil) {
        if let channel, channel < 0 || channel >= Int(source.channelCount) { return nil }
        // Refuse the silent case rather than discover it in the recording.
        if channel == nil, source.channelCount > 2 { return nil }
        guard let c = AVAudioConverter(from: source, to: targetFormat) else { return nil }
        if let channel {
            c.channelMap = [NSNumber(value: channel)]
        } else if source.channelCount == 2 {
            c.downmix = true
        }
        converter = c
        ratio = targetFormat.sampleRate / source.sampleRate
    }

    public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        if out == nil || out!.frameCapacity < capacity {
            out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 4096))
        }
        guard let out else { return nil }
        out.frameLength = 0
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { return nil }
        return out
    }
}

// MARK: - WAV

public enum Wav {
    /// Bytes before the sample data in the files this module writes.
    public static let headerBytes = 44

    /// 44-byte RIFF header for 16 kHz mono 16-bit PCM with `dataBytes` of
    /// sample data following it.
    public static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(meetingSampleRate)); u32(UInt32(meetingSampleRate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return data
    }

    public static func pcm16(_ samples: UnsafeBufferPointer<Float>) -> [Int16] {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        return pcm
    }

    /// Int16 little-endian PCM bytes → Float samples.
    public static func floats(fromPCM16 data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n { out[i] = Float(Int16(littleEndian: p[i])) / 32768 }
        }
        return out
    }

    /// Reads any AVAudioFile-readable file as 16 kHz mono Float.
    public static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(max(file.length, 1)))
        else { throw TapError("could not allocate buffer for \(url.lastPathComponent)") }
        try file.read(into: buffer)
        if file.processingFormat.sampleRate == meetingSampleRate, file.processingFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                             count: Int(buffer.frameLength)))
        }
        guard let r = Resampler(from: file.processingFormat), let out = r.convert(buffer) else {
            throw TapError("could not resample \(url.lastPathComponent)")
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0],
                                         count: Int(out.frameLength)))
    }

    /// Frames `[from, from + count)` of a 16 kHz mono 16-bit file this module
    /// is still writing — the header's sizes are zero until close, so the
    /// data is read by offset rather than through AVAudioFile. Short at EOF.
    public static func readFrames(_ url: URL, from: Int, count: Int) throws -> [Float] {
        guard count > 0 else { return [] }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(headerBytes + from * 2))
        let data = try h.read(upToCount: count * 2) ?? Data()
        return floats(fromPCM16: data)
    }
}

// MARK: - Errors

public func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
    }
    return "\(status)"
}

public struct TapError: Error, CustomStringConvertible {
    public let description: String
    public init(_ what: String, _ status: OSStatus) { description = "\(what) failed: \(fourCC(status))" }
    public init(_ what: String) { description = what }
}
