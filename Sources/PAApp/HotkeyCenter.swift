import Carbon
import Foundation

/// One global hotkey, via the Carbon API that still backs system-wide shortcuts.
/// `action` runs on the main queue.
final class HotkeyCenter {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    /// Retained for the Carbon handler's lifetime, released in `unregister`.
    private var actionBoxPointer: UnsafeMutableRawPointer?

    init() {}

    deinit {
        unregister()
    }

    /// `keyCode` is a virtual key code (49 = space); `carbonModifiers` e.g. `optionKey`.
    @discardableResult
    func register(keyCode: UInt32, carbonModifiers: UInt32, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passRetained(ActionBox(action)).toOpaque()
        actionBoxPointer = pointer

        var handler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                // The box is only alive while registered, so the event must be ours.
                let box = Unmanaged<ActionBox>.fromOpaque(userData!)
                Task { @MainActor in
                    box.takeUnretainedValue().action()
                }
                return noErr
            },
            1,
            &eventSpec,
            pointer,
            &handler
        )
        guard installStatus == noErr else {
            actionBoxPointer = nil
            Unmanaged<ActionBox>.fromOpaque(pointer).release()
            return false
        }
        eventHandler = handler

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            EventHotKeyID(signature: fourCC("PAHK"), id: 1),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else {
            unregister()
            return false
        }
        hotKeyRef = reference
        return true
    }

    func unregister() {
        if let reference = hotKeyRef {
            UnregisterEventHotKey(reference)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        if let pointer = actionBoxPointer {
            Unmanaged<ActionBox>.fromOpaque(pointer).release()
            actionBoxPointer = nil
        }
    }

    /// Retained for the Carbon handler's lifetime, released in `unregister`.
    /// `action` is only ever invoked on the main queue, which is what makes the
    /// unchecked conformance safe.
    private final class ActionBox: @unchecked Sendable {
        let action: @MainActor () -> Void

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }
    }
}

private func fourCC(_ text: String) -> OSType {
    var value: OSType = 0
    for scalar in text.unicodeScalars.prefix(4) {
        value = (value << 8) | OSType(scalar.value & 0xFF)
    }
    return value
}
