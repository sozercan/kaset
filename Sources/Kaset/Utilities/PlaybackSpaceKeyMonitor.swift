import AppKit

// MARK: - PlaybackSpaceKeyMonitor

/// Routes the modifier-less Space key to the Playback play/pause command.
///
/// AppKit never offers a modifier-less key equivalent to the main menu, so the
/// `Space` shortcut declared on the Playback command menu is registered on the menu
/// item but is never dispatched: the key window's view hierarchy declines the event
/// and it dies before the menu is consulted (issue #405). A local key-down monitor
/// is the standard way to reach a bare-Space shortcut.
///
/// Space is only claimed when the native UI holds focus. While a text field is being
/// edited it must type a space, and while the player WebView holds focus the page's
/// own handler already toggles playback — claiming it there would toggle twice.
@MainActor
final class PlaybackSpaceKeyMonitor {
    nonisolated static let spaceKeyCode: UInt16 = 49

    private var monitor: Any?

    /// Whether Space should be claimed for play/pause instead of being delivered normally.
    nonisolated static func handlesSpaceKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isTextInputFocused: Bool,
        isWebContentFocused: Bool,
        isPlaybackCommandEnabled: Bool
    ) -> Bool {
        guard keyCode == self.spaceKeyCode else { return false }
        let significantModifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        guard significantModifiers.isEmpty else { return false }
        return isPlaybackCommandEnabled && !isTextInputFocused && !isWebContentFocused
    }

    /// Whether the responder is inside the player WebView, whose page handles Space itself.
    nonisolated static func isWebContent(_ responderTypeName: String) -> Bool {
        responderTypeName.contains("WebView") || responderTypeName.contains("WKContent")
    }

    /// Whether the responder is a text editor that must receive Space as typed input.
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    func start(
        isPlaybackCommandEnabled: @escaping @MainActor () -> Bool,
        onPlayPause: @escaping @MainActor () -> Void
    ) {
        guard self.monitor == nil else { return }

        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let responder = NSApp.keyWindow?.firstResponder
            let responderTypeName = responder.map { String(describing: type(of: $0)) } ?? ""

            guard Self.handlesSpaceKey(
                keyCode: keyCode,
                modifiers: modifiers,
                isTextInputFocused: MainActor.assumeIsolated { Self.isTextInput(responder) },
                isWebContentFocused: Self.isWebContent(responderTypeName),
                isPlaybackCommandEnabled: MainActor.assumeIsolated { isPlaybackCommandEnabled() }
            ) else { return event }

            MainActor.assumeIsolated { onPlayPause() }
            return nil
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    isolated deinit {
        self.stop()
    }
}
