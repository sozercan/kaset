import Testing
import WebKit
@testable import Kaset

@Suite("Playback WebView teardown", .serialized, .tags(.service))
@MainActor
struct PlaybackWebViewTeardownTests {
    @Test("Music teardown releases its coordinator while the WebView remains retained")
    func musicTeardownReleasesCoordinator() {
        let singleton = SingletonPlayerWebView.makeTestInstance()

        let webKitManager = WebKitManager.makeTestInstance()
        let playerService = PlayerService()
        let retainedWebView = singleton.getWebView(
            webKitManager: webKitManager,
            playerService: playerService
        )
        weak let coordinator = singleton.coordinator

        #expect(coordinator != nil)
        singleton.tearDown()

        #expect(retainedWebView.navigationDelegate == nil)
        #expect(coordinator == nil)
    }

    @Test("YouTube teardown releases its coordinator while the WebView remains retained")
    func youtubeTeardownReleasesCoordinator() {
        let singleton = YouTubeWatchWebView.makeTestInstance()

        let webKitManager = WebKitManager.makeTestInstance()
        let playerService = YouTubePlayerService(webKitManager: webKitManager)
        let retainedWebView = singleton.getWebView(
            webKitManager: webKitManager,
            playerService: playerService
        )
        weak let coordinator = singleton.coordinator

        #expect(coordinator != nil)
        singleton.tearDown()

        #expect(retainedWebView.navigationDelegate == nil)
        #expect(coordinator == nil)
    }

    @Test("Extension host unregister closes its tab and window")
    func extensionHostUnregisterClosesTabAndWindow() {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                let controller = WKWebExtensionController()
                let host = KasetWebExtensionHost(controller: controller)
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.webExtensionController = controller
                let webView = WKWebView(
                    frame: CGRect(x: 0, y: 0, width: 320, height: 180),
                    configuration: configuration
                )
                let tab = host.register(webView: webView, role: .musicPlayer)

                host.unregister(role: .musicPlayer)

                #expect(host.registeredTabCount == 0)
                #expect(host.openWindows.isEmpty)
                #expect(host.focusedWindow == nil)
                #expect(tab?.webView == nil)
                #expect(tab?.window == nil)
            }
        #endif
    }
}
