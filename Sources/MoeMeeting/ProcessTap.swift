import AVFoundation
import CoreAudio
import Foundation

// System-audio capture via Core Audio process taps (macOS 14.2+ API,
// usable from 14.4). No ScreenCaptureKit, so no screen-recording prompt.
//
// The shape of it:
//
//   CATapDescription  →  AudioHardwareCreateProcessTap  →  tap AudioObjectID
//   aggregate device { default output as sub-device, taps: [tap UID] }
//   AudioDeviceCreateIOProcIDWithBlock on the aggregate → input buffers are
//   the tapped processes' output, in the tap's own format (48 kHz stereo
//   Float32 here). We resample to 16 kHz mono on the way to the sink.
//
// Permission: process taps are gated by TCC service kTCCServiceAudioCapture
// ("System Audio Recording Only" under Privacy & Security › Screen & System
// Audio Recording). See MEETING-MODE.md for what actually happens.

// MARK: - Process enumeration

public struct AudioProcess {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
    public let isRunningInput: Bool
}

public enum ProcessList {

    /// The process object ids, and nothing else — the two reads every
    /// enumeration starts with, whatever it goes on to ask about each one.
    static func objectIDs() throws -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                                    &addr, 0, nil, &size)
        guard status == noErr else { throw TapError("process list size", status) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw TapError("process list", status) }
        return ids
    }

    public static func all() throws -> [AudioProcess] {
        try objectIDs().map { id in
            AudioProcess(objectID: id,
                         pid: readPID(id),
                         bundleID: readString(id, kAudioProcessPropertyBundleID) ?? "",
                         isRunningOutput: readBool(id, kAudioProcessPropertyIsRunningOutput),
                         isRunningInput: readBool(id, kAudioProcessPropertyIsRunningInput))
        }
    }

    public static func find(bundleID: String) throws -> [AudioProcess] {
        try all().filter { $0.bundleID == bundleID }
    }

    /// Who is on the microphone, for the three timers that ask constantly.
    ///
    /// `all()` is not free and it is not called once. Every entry costs
    /// **four** synchronous property reads, and each one is a mach round
    /// trip to `coreaudiod` — so a machine with sixty audio processes pays
    /// two hundred and forty IPC calls per poll. Three callers poll on
    /// three unrelated clocks: `MeetingWatcher` every 1.5 s,
    /// `AudioFrontEnd.watchCallApps` every 2 s, and `MicCapture` whenever it
    /// is asked. None of them ever saw the others' answer, so the work was
    /// done two and three times over.
    ///
    /// Measured on the owner's Mac, that had `coreaudiod` sitting at 12% of
    /// a core with Moe idle — a system daemon, where a person looking at
    /// Activity Monitor blames the system rather than the app driving it.
    ///
    /// Two changes, and both are subtraction:
    ///
    /// - **Three properties, not four.** Every one of these callers builds a
    ///   `CallSignal`, which is a bundle id and two flags. `pid` is read on
    ///   every process and then thrown away; the only code that wants it is
    ///   the `MeetingTap` diagnostic, which still calls `all()`. That is a
    ///   quarter of the round trips, for nothing.
    /// - **One reading, shared.** `maxAge` is under the fastest caller's
    ///   period, so nobody is served an answer older than they asked for,
    ///   and two callers landing in the same second read once.
    public enum Signals {

        /// How long a reading may be reused.
        ///
        /// Below `MeetingWatcher.interval` (1.5 s), which is the fastest
        /// poll and the one that decides how quickly a call is noticed — so
        /// it always gets a fresh read and its latency is unchanged. The 2 s
        /// caller usually reuses it. Raising this past 1.5 s would start
        /// slowing down call detection, which is the thing this must not do.
        public static let maxAge: TimeInterval = 1.2

        private static let lock = NSLock()
        private static var cached: [CallSignal] = []
        private static var takenAt: Date?
        private static var reads = 0

        /// How many times Core Audio has actually been asked.
        ///
        /// The side effect, exposed on purpose: a cache that has silently
        /// stopped caching and a cache that is working look identical from
        /// the outside, and "did it return signals" is a check that cannot
        /// fail. `ProcessSignalCacheTests` counts this.
        public static var readsPerformed: Int {
            lock.lock(); defer { lock.unlock() }
            return reads
        }

        /// Forget the reading. For tests, and for anything that needs the
        /// next answer to be current no matter how recent the last one was.
        public static func invalidate(resettingCount: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            takenAt = nil
            cached = []
            if resettingCount { reads = 0 }
        }

        /// The current signals, from cache when one is fresh enough.
        ///
        /// `now` and `read` are injected so the ageing rule can be tested
        /// without sleeping and without a microphone.
        public static func current(now: Date = Date(),
                                   read: () -> [CallSignal] = { ProcessList.readSignals() }) -> [CallSignal] {
            lock.lock()
            if let takenAt, now.timeIntervalSince(takenAt) < maxAge, now >= takenAt {
                defer { lock.unlock() }
                return cached
            }
            lock.unlock()
            // Outside the lock: this is IPC, and holding a lock across it
            // would serialise every caller behind the slowest read rather
            // than merely sharing its result.
            let fresh = read()
            lock.lock(); defer { lock.unlock() }
            cached = fresh
            takenAt = now
            reads += 1
            return fresh
        }
    }

    /// One uncached pass over Core Audio's process list, reading only what a
    /// `CallSignal` holds — three properties per process rather than four.
    public static func readSignals() -> [CallSignal] {
        guard let ids = try? objectIDs() else { return [] }
        return ids.map {
            CallSignal(bundleID: readString($0, kAudioProcessPropertyBundleID) ?? "",
                       input: readBool($0, kAudioProcessPropertyIsRunningInput),
                       output: readBool($0, kAudioProcessPropertyIsRunningOutput))
        }
    }

    private static func readPID(_ id: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid)
        return pid
    }

    private static func readBool(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Process name from the pid, for display (the bundle id is often empty
    /// for daemons and command-line tools).
    public static func name(forPID pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : "?"
    }
}

// MARK: - The tap

/// Which processes to tap.
public enum TapTarget {
    /// Everything except our own process (so a future Moe-in-the-meeting
    /// TTS reply does not feed back into "them").
    case allExceptSelf
    case processes([AudioObjectID])
}

public final class ProcessTap {
    public let target: TapTarget
    public let sink: SampleSink

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var resampler: Resampler?
    public private(set) var tapFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "moe.meetingtap.io")

    /// IO-proc invocations, including ones that carried no frames — tells a
    /// dead aggregate apart from a silent one.
    final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    let counters = Counters()
    public var ioCallbacks: Int { counters.value }

    /// What this tap is pointed at and what clocks it, for the log: the
    /// call's audio arriving on the wrong device (or from no process at
    /// all) reads as "no meeting audio", which does not say which.
    public var targetDescription: String {
        var what: String
        switch target {
        case .allExceptSelf: what = "every process except Moe"
        case .processes(let ids): what = "process object(s) \(ids.map(String.init).joined(separator: ", "))"
        }
        if let out = AudioDevices.defaultOutput() { what += ", playing through \(out.label)" }
        if let f = tapFormat {
            what += String(format: ", tap format %.0f Hz × %u ch", f.sampleRate, f.channelCount)
        }
        return what
    }

    public init(target: TapTarget, sink: SampleSink) {
        self.target = target
        self.sink = sink
    }

    /// Creates the tap + aggregate device and starts IO. Throws with the
    /// four-char OSStatus if Core Audio refuses, tearing down whatever was
    /// already created (a tap without an aggregate would otherwise sit in
    /// coreaudiod until the process exits).
    public func start() throws {
        do { try startOrThrow() } catch { stop(); throw error }
    }

    private func startOrThrow() throws {
        // 1. Tap description. Stereo mixdown so we get a plain L/R stream
        //    regardless of how many channels the output device has.
        let description: CATapDescription
        switch target {
        case .allExceptSelf:
            let me = try selfProcessObject()
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: me.map { [$0] } ?? [])
        case .processes(let ids):
            description = CATapDescription(stereoMixdownOfProcesses: ids)
        }
        description.name = "Moe meeting tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted   // the user still hears the call

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError("AudioHardwareCreateProcessTap", status) }
        tapID = tap

        // 2. The tap's stream format: this is what the aggregate's input
        //    IO buffers will be in.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError("read tap format", status) }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError("tap format not representable as AVAudioFormat")
        }
        tapFormat = format
        guard let r = Resampler(from: format) else {
            throw TapError("no converter from \(format) to 16 kHz mono")
        }
        resampler = r

        // 3. Aggregate device: default output device as the clock source
        //    sub-device, plus our tap. Private so it never shows up in
        //    Audio MIDI Setup or anyone else's device list.
        let outputUID = try defaultOutputDeviceUID()
        let aggregateUID = UUID().uuidString
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Moe meeting tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: 1,
                 kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        // Default: the aggregate is the tap alone, no hardware sub-device.
        // The usual recipe (AudioCap et al.) adds the default output device
        // as the clock-source sub-device, but that variant delivers empty
        // buffers as soon as a VoiceProcessingIO unit (mic AEC) is running
        // in the same process — 780 IO callbacks, 0 frames, measured.
        // `MEETINGTAP_SUBDEVICE=1` re-enables it for comparison.
        if ProcessInfo.processInfo.environment["MEETINGTAP_SUBDEVICE"] == "1" {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr else { throw TapError("AudioHardwareCreateAggregateDevice", status) }
        aggregateID = aggregate

        // 4. IO proc. The input buffer list carries the tap's stream.
        let sink = self.sink
        let resampler = r
        var procID: AudioDeviceIOProcID?
        let counters = self.counters
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            _, inInputData, _, _, _ in
            counters.bump()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: inInputData,
                                                deallocator: nil),
                  buffer.frameLength > 0,
                  let mono = resampler.convert(buffer)
            else { return }
            sink.append(mono)
        }
        guard status == noErr, let procID else { throw TapError("AudioDeviceCreateIOProcIDWithBlock", status) }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError("AudioDeviceStart", status) }
    }

    public func stop() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { stop() }

    // MARK: helpers

    private func selfProcessObject() throws -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &object)
        // A process that has never touched audio has no process object yet;
        // that is fine — there is nothing of ours to exclude.
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private func defaultOutputDeviceUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw TapError("default output device", status)
        }
        guard let uid = ProcessList.readString(device, kAudioDevicePropertyDeviceUID) else {
            throw TapError("default output device has no UID")
        }
        return uid
    }
}

// MARK: - Which device was actually opened

/// One audio device, named. A meeting that hears nothing is nearly always
/// the wrong device — the default input moved to a Continuity mic on a
/// phone in a pocket, a headset that went to sleep — and "mic silent" does
/// not say *which* device was silent. The name, the UID and the transport
/// do, and they cost one property read at meeting start.
public struct AudioDeviceInfo: Equatable, Sendable {
    public var id: AudioObjectID
    public var name: String
    public var uid: String
    /// "built-in", "Bluetooth", "Continuity (wireless)", … — the transport
    /// is what tells a Mac's own microphone from an iPhone acting as one.
    public var transport: String

    public init(id: AudioObjectID, name: String, uid: String, transport: String) {
        self.id = id
        self.name = name
        self.uid = uid
        self.transport = transport
    }

    /// `MacBook Pro Microphone (built-in) [BuiltInMicrophoneDevice]`
    public var label: String {
        "\(name.isEmpty ? "?" : name)\(transport.isEmpty ? "" : " (\(transport))") [\(uid.isEmpty ? "no UID" : uid)]"
    }
}

public enum AudioDevices {

    public static func info(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard id != kAudioObjectUnknown else { return nil }
        return AudioDeviceInfo(id: id,
                               name: ProcessList.readString(id, kAudioObjectPropertyName) ?? "",
                               uid: ProcessList.readString(id, kAudioDevicePropertyDeviceUID) ?? "",
                               transport: transport(id))
    }

    public static func defaultInput() -> AudioDeviceInfo? {
        info(defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
    }

    /// The microphone an audio unit is on, given what the unit says its
    /// device is.
    ///
    /// A voice processing unit is duplex — one audio unit spanning input and
    /// output — and `AUAudioUnit.deviceID` answers with the output device.
    /// The first meeting to log its device therefore named "MacBook Air
    /// Speakers [BuiltInSpeakerDevice]" as the microphone it had opened,
    /// which is a log that lies about the one fact it exists to record. An
    /// output device has no input channels, and that is the check: the unit
    /// is believed only when the device it names could be a microphone.
    public static func inputDevice(reportedByAudioUnit id: AudioObjectID) -> AudioDeviceInfo? {
        pickInput(reported: info(id), reportedInputChannels: channelCount(id, input: true),
                  defaultInput: defaultInput())
    }

    /// Split out so the rule is testable without a device.
    public static func pickInput(reported: AudioDeviceInfo?, reportedInputChannels: Int,
                                 defaultInput: AudioDeviceInfo?) -> AudioDeviceInfo? {
        if let reported, reportedInputChannels > 0 { return reported }
        return defaultInput
    }

    /// Channels the device has on one scope, summed over its streams. Zero
    /// when the device has none, which is how an output device is told from
    /// a microphone.
    public static func channelCount(_ id: AudioObjectID, input: Bool) -> Int {
        guard id != kAudioObjectUnknown else { return 0 }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func defaultOutput() -> AudioDeviceInfo? {
        info(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    /// The four-character transport type in words. Continuity is spelled
    /// out because "the default input quietly became the iPhone" is the
    /// single most likely reason a meeting's microphone heard nothing.
    static func transport(_ id: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return "" }
        return name(forTransport: value)
    }

    /// Split out so it is testable without a device: the constants are
    /// `kAudioDeviceTransportType*`, spelled as four-character codes.
    public static func name(forTransport value: UInt32) -> String {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity (wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity (wireless)"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeUnknown, 0: return ""
        default: return fourCC(OSStatus(bitPattern: value))
        }
    }
}
