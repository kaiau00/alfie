import CoreMediaIO
import Foundation

/// Is any app using the camera right now?
///
/// `kCMIODevicePropertyDeviceIsRunningSomewhere` on each CMIO device — the
/// same property OverSight watches, the camera twin of Core Audio's
/// `IsRunningSomewhere`. It needs no camera permission: we never open a
/// stream or touch a frame, we ask the hardware layer "is anyone running
/// this device", which is ungated. Like the audio poll it answers
/// *somewhere*, not *which app* — attributing it to a process needs
/// unified-log scraping that breaks every macOS release, and the detector
/// does not need it: a browser holding the microphone *while the camera is
/// on* is a video call and not a dictation site, whichever app has the lens.
enum CameraProbe {

    /// True if at least one camera device is running in some process.
    static func inUse() -> Bool {
        for device in devices() where isRunningSomewhere(device) { return true }
        return false
    }

    private static func devices() -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &addr, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == noErr && value != 0
    }
}
