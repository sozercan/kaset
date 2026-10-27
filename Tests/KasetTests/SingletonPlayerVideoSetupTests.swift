import AppKit
import Testing
import WebKit
@testable import Kaset

// MARK: - SingletonPlayerVideoSetupTests

@Suite(.serialized, .tags(.service))
@MainActor
struct SingletonPlayerVideoSetupTests {
    @Test("A queued bounds retry cannot restart video setup after returning to audio")
    func boundsRetryStopsInAudioMode() async throws {
        let webView = VideoSetupRecordingWebView()
        let container = NSView(frame: .zero)
        container.addSubview(webView)
        let player = SingletonPlayerWebView.makeTestInstance(webView: webView)
        player.updateDisplayMode(.video)
        player.updateDisplayMode(.hidden)
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        let scriptsBeforeRetry = webView.scripts.count

        try await Task.sleep(for: .milliseconds(250))

        #expect(webView.scripts.count == scriptsBeforeRetry)
        #expect(player.displayMode == .hidden)
    }

    @Test("Delayed video styling cannot reappear after the TV toggle turns off")
    func delayedStylesStopInAudioMode() async throws {
        let webView = VideoSetupRecordingWebView()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        container.addSubview(webView)
        let player = SingletonPlayerWebView.makeTestInstance(webView: webView)
        player.updateDisplayMode(.video)
        player.updateDisplayMode(.hidden)
        let scriptsBeforeDelay = webView.scripts.count

        try await Task.sleep(for: .milliseconds(650))

        #expect(webView.scripts.count == scriptsBeforeDelay)
        #expect(player.displayMode == .hidden)
    }
}

// MARK: - VideoSetupRecordingWebView

@MainActor
private final class VideoSetupRecordingWebView: WKWebView {
    var scripts: [String] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
    ) {
        self.scripts.append(javaScriptString)
        completionHandler?(["clicked": true], nil)
    }
}
