import AppKit
import WebKit

// MARK: - PlaybackSpaceKeyContext

struct PlaybackSpaceKeyContext {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let isRepeat: Bool
    let isPrimaryWindow: Bool
    let isTextInputFocused: Bool
    let isWebContentFocused: Bool
    let isNativeBrowsingContentFocused: Bool
    let isPlaybackCommandEnabled: Bool
}

// MARK: - PlaybackSpaceKeyMonitor

/// Routes the modifier-less Space key to the Playback play/pause command.
///
/// AppKit does not route bare Space through Kaset's main-menu key equivalent when
/// native navigation content holds focus, so the registered Playback menu shortcut
/// is never dispatched (issue #405). A local key-down monitor bridges that gap.
///
/// Only the initial bare-Space event in the primary window is claimed. Text editors,
/// WebKit content, and controls with standard Space activation retain the event;
/// auxiliary windows and key-repeat events are also left alone.
@MainActor
final class PlaybackSpaceKeyMonitor {
    nonisolated static let spaceKeyCode: UInt16 = 49

    private var monitor: Any?

    /// Whether Space should be claimed for play/pause instead of being delivered normally.
    nonisolated static func handlesSpaceKey(_ context: PlaybackSpaceKeyContext) -> Bool {
        guard context.keyCode == self.spaceKeyCode,
              !context.isRepeat,
              context.isPrimaryWindow
        else { return false }

        let significantModifiers = context.modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad])
        guard significantModifiers.isEmpty else { return false }
        return context.isPlaybackCommandEnabled
            && !context.isTextInputFocused
            && !context.isWebContentFocused
            && context.isNativeBrowsingContentFocused
    }

    /// Whether the responder is inside a WebKit view whose page handles Space itself.
    static func isWebContent(_ responder: NSResponder?) -> Bool {
        var currentResponder = responder
        while let current = currentResponder {
            if current is WKWebView {
                return true
            }
            currentResponder = current.nextResponder
        }
        return false
    }

    /// Whether the responder is a text editor that must receive Space as typed input.
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    /// Whether the responder is the native browsing surface where Kaset assigns
    /// Space to playback. Restricting interception to the table itself avoids
    /// guessing about SwiftUI's private focus bridge types.
    static func isNativeBrowsingContent(_ responder: NSResponder?) -> Bool {
        responder is NSTableView
    }

    func start(
        isPlaybackCommandEnabled: @escaping @MainActor () -> Bool,
        onPlayPause: @escaping @MainActor () -> Void
    ) {
        guard self.monitor == nil else { return }

        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let window = event.window ?? NSApp.keyWindow
            let responder = window?.firstResponder

            let context = PlaybackSpaceKeyContext(
                keyCode: keyCode,
                modifiers: modifiers,
                isRepeat: event.isARepeat,
                isPrimaryWindow: MainActor.assumeIsolated {
                    window.map(MainWindowLayout.isPrimaryWindow) ?? false
                },
                isTextInputFocused: MainActor.assumeIsolated { Self.isTextInput(responder) },
                isWebContentFocused: MainActor.assumeIsolated { Self.isWebContent(responder) },
                isNativeBrowsingContentFocused: MainActor.assumeIsolated {
                    Self.isNativeBrowsingContent(responder)
                },
                isPlaybackCommandEnabled: MainActor.assumeIsolated { isPlaybackCommandEnabled() }
            )
            guard Self.handlesSpaceKey(context) else { return event }

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
