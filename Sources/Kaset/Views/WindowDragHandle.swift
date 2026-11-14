import AppKit
import SwiftUI

// MARK: - WindowDragHandle

/// Native region that moves its containing window when dragged.
///
/// Use this only over noninteractive content. SwiftUI and WebKit views can
/// consume mouse events before `isMovableByWindowBackground` sees them, so this
/// view starts the AppKit window drag directly.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        WindowDragNSView()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

// MARK: - WindowDragNSView

private final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// The first click can move a floating window without activating it first.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize":
                self.window?.miniaturize(nil)
            case "None":
                break
            default:
                self.window?.performZoom(nil)
            }
        } else {
            self.window?.performDrag(with: event)
        }
    }
}
