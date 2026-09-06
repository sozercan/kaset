import AppKit
import SwiftUI

// MARK: - AirPlayPickerAnchor

/// Resolves the control's current position for mouse, keyboard, and accessibility activation.
@MainActor
final class AirPlayPickerAnchor {
    fileprivate weak var view: NSView?

    var screenPoint: CGPoint? {
        guard let view = self.view, let window = view.window else { return nil }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        return window.convertPoint(toScreen: view.convert(center, to: nil))
    }
}

// MARK: - AirPlayPickerAnchorView

struct AirPlayPickerAnchorView: NSViewRepresentable {
    let anchor: AirPlayPickerAnchor

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        self.anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        self.anchor.view = view
    }
}
