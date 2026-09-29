import AppKit
import WebKit

// MARK: - KasetWebView

/// A WKWebView that leaves hidden-player navigation shortcuts to the app menu.
///
/// The singleton player WebView stays in the main window at 1x1 during audio
/// playback. WebKit handles Command-Left and Command-Right before SwiftUI's
/// Playback menu sees them, so Previous and Next would stop working. Bare Space
/// is handled separately by `PlaybackSpaceKeyMonitor`.
final class KasetWebView: WKWebView {
    nonisolated static let leftArrowKeyCode: UInt16 = 123
    nonisolated static let rightArrowKeyCode: UInt16 = 124

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isHidden = self.bounds.width <= 1 || self.bounds.height <= 1
        if Self.declinesHiddenPlaybackKeyEquivalent(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isHidden: isHidden
        ) {
            return false
        }

        return super.performKeyEquivalent(with: event)
    }

    nonisolated static func declinesHiddenPlaybackKeyEquivalent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isHidden: Bool
    ) -> Bool {
        guard isHidden,
              keyCode == self.leftArrowKeyCode || keyCode == self.rightArrowKeyCode
        else { return false }

        let significantModifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad])
        return significantModifiers == .command
    }
}
