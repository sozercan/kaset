import AppKit
import Foundation
import Testing
@testable import Kaset

// MARK: - AppDelegateWindowLifecycleTests

@Suite("AppDelegate window lifecycle", .serialized)
@MainActor
struct AppDelegateWindowLifecycleTests {
    @Test("Registration bridge routes red close and reopen without replacing content")
    func registrationBridgeRoutesCloseAndReopen() {
        let windowReference = WeakWindowReference()
        let auxiliaryWindowsBeforeClose = self.auxiliaryPlayerWindowIDs()

        autoreleasepool {
            self.exerciseRegistrationBridge(windowReference: windowReference)
        }

        #expect(windowReference.window == nil)
        #expect(self.auxiliaryPlayerWindowIDs() == auxiliaryWindowsBeforeClose)
    }

    private func exerciseRegistrationBridge(windowReference: WeakWindowReference) {
        let delegate = AppDelegate()
        let frameAutosaveDefaultsKey = "NSWindow Frame \(MainWindowLayout.autosaveName)"
        let defaults = UserDefaults.standard
        let previousFrameAutosaveValue = defaults.object(forKey: frameAutosaveDefaultsKey)
        var registeredWindowID: ObjectIdentifier?
        let registrationView = MainWindowRegistrationNSView(frame: .zero)
        registrationView.windowDidChange = { [weak delegate] window in
            registeredWindowID = ObjectIdentifier(window)
            delegate?.registerMainWindow(window)
        }
        registrationView.windowDidDetach = { [weak delegate] window in
            delegate?.unregisterMainWindow(window)
        }
        let window = MainWindowLifecycleSpy(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        windowReference.window = window
        window.title = "Home"
        // Exercise the concrete NSView used by the SwiftUI representable. Its
        // viewDidMoveToWindow callback is the registration timing boundary.
        window.contentView = registrationView
        defer {
            registrationView.unregisterCurrentWindow()
            registrationView.windowDidChange = nil
            registrationView.windowDidDetach = nil
            window.setFrameAutosaveName("")
            if let previousFrameAutosaveValue {
                defaults.set(previousFrameAutosaveValue, forKey: frameAutosaveDefaultsKey)
            } else {
                defaults.removeObject(forKey: frameAutosaveDefaultsKey)
            }
        }

        #expect(registeredWindowID == ObjectIdentifier(window))
        #expect(window.delegate === delegate)
        #expect(window.contentMinSize == MainWindowLayout.minimumContentSize)

        let originalContentView = window.contentView
        let shouldClose = delegate.windowShouldClose(window)

        #expect(!shouldClose)
        #expect(window.orderOutCallCount == 1)
        #expect(window.contentView === originalContentView)

        let handledReopen = delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )

        #expect(handledReopen)
        #expect(window.makeKeyAndOrderFrontCallCount == 1)
        #expect(window.contentView === originalContentView)
    }

    private func auxiliaryPlayerWindowIDs() -> Set<ObjectIdentifier> {
        Set(
            NSApplication.shared.windows.compactMap { window in
                guard AccessibilityID.isAuxiliaryPlayerWindowIdentifier(window.identifier?.rawValue) else {
                    return nil
                }
                return ObjectIdentifier(window)
            }
        )
    }
}

// MARK: - WeakWindowReference

@MainActor
private final class WeakWindowReference {
    weak var window: NSWindow?
}

// MARK: - MainWindowLifecycleSpy

@MainActor
private final class MainWindowLifecycleSpy: NSWindow {
    private(set) var orderOutCallCount = 0
    private(set) var makeKeyAndOrderFrontCallCount = 0

    override func orderOut(_ sender: Any?) {
        self.orderOutCallCount += 1
        super.orderOut(sender)
    }

    override func makeKeyAndOrderFront(_: Any?) {
        self.makeKeyAndOrderFrontCallCount += 1
    }
}
