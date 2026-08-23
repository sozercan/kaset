import AppKit
import SwiftUI

// MARK: - TextInputFocusState

/// Tracks whether a text field is first responder so playback menu shortcuts defer to editing.
@MainActor
@Observable
final class TextInputFocusState {
    private(set) var isFocused = false

    private var observers: [NSObjectProtocol] = []
    private var isMonitoring = false

    func startMonitoring() {
        guard !self.isMonitoring else { return }
        self.isMonitoring = true

        let names = [
            NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]

        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateFromFirstResponder()
                }
            }
            self.observers.append(observer)
        }

        self.updateFromFirstResponder()
    }

    isolated deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateFromFirstResponder() {
        guard let firstResponder = NSApplication.shared.keyWindow?.firstResponder else {
            self.isFocused = false
            return
        }

        self.isFocused = firstResponder is NSTextView || firstResponder is NSTextField
    }
}
