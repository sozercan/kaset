import Testing
import WebKit
@testable import Kaset

// MARK: - AirPlayNavigationTests

@Suite("AirPlay navigation continuity", .serialized, .tags(.service))
@MainActor
struct AirPlayNavigationTests {
    @Test("Queue recovery for another song keeps the document and uses the SPA router")
    func differentTrackRecoveryPreservesDocument() {
        let webView = RecordingPlaybackWebView()
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "source"
        let generation = singleton.documentGeneration.currentGeneration

        singleton.loadVideo(videoId: "target", strategy: .forceFullPageWhenSameVideoId)

        #expect(webView.scripts.contains { $0.contains("app.resolveCommand") })
        #expect(!webView.scripts.contains { $0.contains("location.replace") })
        #expect(singleton.documentGeneration.currentGeneration == generation)
        #expect(singleton.documentGeneration.pendingGeneration == nil)
        #expect(singleton.documentGeneration.inFlightGeneration == nil)
        singleton.confirmRouterNavigationIfNeeded(videoId: "target")
    }

    @Test("Same-ID recovery still reloads a document whose media no longer matches")
    func sameTrackRecoveryReplacesDocument() {
        let webView = RecordingPlaybackWebView()
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "target"

        singleton.loadVideo(videoId: "target", strategy: .forceFullPageWhenSameVideoId)

        #expect(!webView.scripts.contains { $0.contains("app.resolveCommand") })
        #expect(webView.scripts.contains { $0.contains("location.replace") })
        #expect(singleton.documentGeneration.inFlightGeneration != nil)
    }

    @Test("A pending document replacement cannot be mistaken for a live SPA document")
    func uncommittedDocumentUsesFullNavigation() {
        let webView = RecordingPlaybackWebView()
        var document = WebPlaybackDocumentGeneration()
        _ = document.beginNavigation()
        let singleton = SingletonPlayerWebView.makeTestInstance(webView: webView, documentGeneration: document)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "source"

        singleton.loadVideo(videoId: "target", strategy: .forceFullPageWhenSameVideoId)

        #expect(!webView.scripts.contains { $0.contains("app.resolveCommand") })
        #expect(webView.scripts.contains { $0.contains("location.replace") })
        #expect(singleton.documentGeneration.inFlightGeneration != nil)
    }

    @Test("Content-process loss requires a fresh document even when the recovery target differs")
    func lostDocumentUsesFullNavigation() {
        let webView = RecordingPlaybackWebView()
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "source"
        singleton.invalidateDocumentNavigationState()

        singleton.loadVideo(videoId: "target", strategy: .forceFullPageWhenSameVideoId)

        #expect(!webView.scripts.contains { $0.contains("app.resolveCommand") })
        #expect(webView.scripts.contains { $0.contains("location.replace") })
        #expect(singleton.documentGeneration.inFlightGeneration != nil)
    }

    @Test("An unavailable SPA router retains the full-page recovery path")
    func unavailableRouterFallsBackToDocumentNavigation() {
        let webView = RecordingPlaybackWebView()
        webView.routerSucceeds = false
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "source"

        singleton.loadVideo(videoId: "target")

        #expect(webView.scripts.contains { $0.contains("app.resolveCommand") })
        #expect(webView.scripts.contains { $0.contains("location.replace") })
        #expect(singleton.documentGeneration.inFlightGeneration != nil)
    }

    private static func makePlayer(webView: WKWebView) -> SingletonPlayerWebView {
        var document = WebPlaybackDocumentGeneration()
        let generation = document.beginNavigation()
        document.startNavigation(generation)
        document.commitNavigation(generation)
        let singleton = SingletonPlayerWebView.makeTestInstance(webView: webView, documentGeneration: document)
        singleton.pendingDocumentID = 1
        singleton.beginDocumentNavigation(nil, in: webView)
        singleton.commitDocumentNavigation(nil, webView: webView)
        singleton.finishDocumentNavigation(nil, in: webView)
        return singleton
    }
}

// MARK: - RecordingPlaybackWebView

@MainActor
private final class RecordingPlaybackWebView: WKWebView {
    var scripts: [String] = []
    var routerSucceeds = true

    override var url: URL? {
        URL(string: "https://music.youtube.com/watch?v=source")
    }

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
        completionHandler?(javaScriptString.contains("app.resolveCommand") ? self.routerSucceeds : nil, nil)
    }
}
