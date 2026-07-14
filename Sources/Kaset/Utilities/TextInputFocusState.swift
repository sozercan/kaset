import AppKit
import SwiftUI

// MARK: - TextInputFocusState

/// Tracks whether a text field is first responder so playback menu shortcuts defer to editing.
@MainActor
@Observable
final class TextInputFocusState {
    private(set) var isEditing = false

    init() {
        let names = [
            NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]

        for name in names {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.syncFromFirstResponder()
            }
        }

        self.syncFromFirstResponder()
    }

    private func syncFromFirstResponder() {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else {
            self.isEditing = false
            return
        }

        self.isEditing = firstResponder is NSTextView || firstResponder is NSTextField
    }
}
