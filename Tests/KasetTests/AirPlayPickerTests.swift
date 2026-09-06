import AppKit
import Testing
import WebKit
@testable import Kaset

// MARK: - AirPlayPickerTests

@Suite("AirPlay picker anchoring", .serialized, .tags(.service))
@MainActor
struct AirPlayPickerTests {
    @Test("The picker uses the button position in flipped and unflipped windows", arguments: [true, false])
    func anchorsPickerAtControl(isFlipped: Bool) throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 640, height: 480),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let contentView = PickerContentView(frame: .zero)
        contentView.usesFlippedCoordinates = isFlipped
        window.contentView = contentView
        let webView = PickerWebView()
        contentView.addSubview(webView)
        webView.frame = NSRect(x: 639, y: 479, width: 1, height: 1)
        let singleton = SingletonPlayerWebView.makeTestInstance(webView: webView)
        defer { singleton.tearDown() }
        let controlPosition = NSPoint(x: 90, y: 42)
        let screenPoint = window.convertPoint(toScreen: contentView.convert(controlPosition, to: nil))

        singleton.showAirPlayPicker(at: screenPoint)

        let event = try #require(webView.anchorEvent)
        #expect(event.locationInWindow == controlPosition)
        #expect(event.type == .leftMouseUp)
        #expect(event.clickCount == 0)
        #expect(webView.actions == ["mouse-up", "picker"])
    }
}

// MARK: - PickerContentView

@MainActor
private final class PickerContentView: NSView {
    var usesFlippedCoordinates = false
    override var isFlipped: Bool {
        self.usesFlippedCoordinates
    }
}

// MARK: - PickerWebView

@MainActor
private final class PickerWebView: WKWebView {
    var anchorEvent: NSEvent?
    var actions: [String] = []

    override func mouseUp(with event: NSEvent) {
        self.anchorEvent = event
        self.actions.append("mouse-up")
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
    ) {
        if javaScriptString.contains("webkitShowPlaybackTargetPicker") {
            self.actions.append("picker")
        }
        completionHandler?(nil, nil)
    }
}
