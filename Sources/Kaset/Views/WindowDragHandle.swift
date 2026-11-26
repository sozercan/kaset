import AppKit
import SwiftUI

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        WindowDragNSView()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }

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
