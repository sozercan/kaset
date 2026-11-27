import AppKit
import WebKit

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

@MainActor
final class PlaybackSpaceKeyMonitor {
    nonisolated static let spaceKeyCode: UInt16 = 49

    private var monitor: Any?

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

    static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

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
