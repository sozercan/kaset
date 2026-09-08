import AppKit
import SwiftUI
import WebKit

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

    /// Updates WebKit's native picker anchor before requesting the device list.
    static func preparePicker(in webView: WKWebView, at screenPoint: CGPoint?) {
        guard let screenPoint, let window = webView.window, let contentView = window.contentView else { return }

        // WebKit treats its last native mouse position as content-view coordinates,
        // including a flipped SwiftUI host. A zero-click mouse-up updates that point
        // without pressing any of YouTube's controls. See ADR-0010 for the WebKit paths.
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let pickerPoint = contentView.convert(windowPoint, from: nil)
        if let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pickerPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) {
            webView.mouseUp(with: event)
        }
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
