import AppKit
import Carbon

// MARK: - GlobalHotkeyManager

/// Manages global keyboard shortcuts using macOS Carbon APIs.
@MainActor
final class GlobalHotkeyManager {
    /// Shared singleton instance.
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var isHandlerInstalled = false
    private var callback: (() -> Void)?

    private init() {}

    /// Registers the global shortcut.
    func registerGlobalShortcut(onTrigger: @escaping () -> Void) {
        self.callback = onTrigger
        guard !self.isHandlerInstalled else { return }
        self.isHandlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let getParamStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                if getParamStatus == noErr, hotKeyID.id == 1 {
                    manager.triggerCallback()
                }

                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )

        if status != noErr {
            DiagnosticsLogger.app.error("Failed to install Event Handler for Global Hotkey: \(status)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(1001), id: 1)
        var ref: EventHotKeyRef?

        // Key code 40 is 'k', modifiers cmdKey (0x0100)
        let registerStatus = RegisterEventHotKey(
            40,
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if registerStatus == noErr {
            self.hotKeyRef = ref
            DiagnosticsLogger.app.info("Successfully registered global Cmd+K hotkey")
        } else {
            DiagnosticsLogger.app.error("Failed to register global Cmd+K hotkey: \(registerStatus)")
        }
    }

    private func triggerCallback() {
        self.callback?()
    }
}
