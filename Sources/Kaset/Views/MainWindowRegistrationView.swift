import AppKit
import SwiftUI

// MARK: - MainWindowRegistrationView

/// Reports the underlying AppKit window when SwiftUI attaches the main scene.
struct MainWindowRegistrationView: NSViewRepresentable {
    let register: @MainActor (NSWindow) -> Void
    let unregister: @MainActor (NSWindow) -> Void

    func makeNSView(context _: Context) -> MainWindowRegistrationNSView {
        let view = MainWindowRegistrationNSView(frame: .zero)
        view.windowDidChange = self.register
        view.windowDidDetach = self.unregister
        return view
    }

    func updateNSView(_ view: MainWindowRegistrationNSView, context _: Context) {
        view.windowDidChange = self.register
        view.windowDidDetach = self.unregister
        view.registerCurrentWindowIfNeeded()
    }

    static func dismantleNSView(_ view: MainWindowRegistrationNSView, coordinator _: Void) {
        view.unregisterCurrentWindow()
        view.windowDidChange = nil
        view.windowDidDetach = nil
    }
}

// MARK: - MainWindowRegistrationNSView

@MainActor
final class MainWindowRegistrationNSView: NSView {
    var windowDidChange: (@MainActor (NSWindow) -> Void)?
    var windowDidDetach: (@MainActor (NSWindow) -> Void)?
    private weak var registeredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.registerCurrentWindowIfNeeded()
    }

    func registerCurrentWindowIfNeeded() {
        guard self.registeredWindow !== self.window else { return }
        self.unregisterCurrentWindow()
        self.registeredWindow = self.window
        if let window = self.window {
            self.windowDidChange?(window)
        }
    }

    func unregisterCurrentWindow() {
        guard let registeredWindow else { return }
        self.registeredWindow = nil
        self.windowDidDetach?(registeredWindow)
    }
}
