import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey.
///
/// Uses Carbon's RegisterEventHotKey rather than a CGEventTap on purpose:
/// it works with no Accessibility or Input Monitoring permission at all, so
/// Moe answers the very first time you press the key instead of sending
/// you to System Settings.
final class HotKey {

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let onPress: () -> Void

    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    init?(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.id = HotKey.nextID
        HotKey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, _ in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            guard status == noErr else { return status }
            if let hk = HotKey.registry[hkID.id] {
                DispatchQueue.main.async { hk.onPress() }
            }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                callback, 1, &eventType, nil, &handlerRef)
        guard installStatus == noErr else { return nil }
        handler = handlerRef

        let hotKeyID = EventHotKeyID(signature: OSType(0x484D5253 /* "HMRS" */), id: id)
        var hotKeyRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard regStatus == noErr, let hotKeyRef else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        ref = hotKeyRef
        HotKey.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.registry.removeValue(forKey: id)
    }

    /// "⌥Space" for display in the menu.
    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        switch Int(keyCode) {
        case kVK_Space:  s += "Space"
        case kVK_Return: s += "Return"
        case kVK_ANSI_H: s += "H"
        case kVK_ANSI_J: s += "J"
        case kVK_ANSI_K: s += "K"
        case kVK_ANSI_M: s += "M"
        case kVK_Escape: s += "Esc"
        default:         s += "key \(keyCode)"
        }
        return s
    }
}
