import Testing
import WebKit
@testable import Kaset

// MARK: - AirPlayNavigationTests

@Suite("AirPlay navigation continuity", .serialized, .tags(.service))
@MainActor
struct AirPlayNavigationTests {
    @Test("Same-ID queue drift recovery retries the SPA router without replacing the document")
    func sameTrackRouterRecoveryPreservesDocument() {
        let webView = RecordingPlaybackWebView()
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "target"
        let generation = singleton.documentGeneration.currentGeneration

        singleton.loadVideo(videoId: "target", strategy: .preferRouterWhenSameVideoId)

        #expect(webView.scripts.contains { $0.contains("app.resolveCommand") })
        #expect(!webView.scripts.contains { $0.contains("location.replace") })
        #expect(singleton.documentGeneration.currentGeneration == generation)
        #expect(singleton.documentGeneration.inFlightGeneration == nil)
        #expect(singleton.isRouterNavigationPending(for: "target"))
        singleton.confirmRouterNavigationIfNeeded(videoId: "target")
    }

    @Test("Only the pending router target coalesces recovery until its media is confirmed")
    func pendingRouterRecoveryTracksConfirmationAndTarget() {
        let webView = RecordingPlaybackWebView()
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "source"
        #expect(!singleton.isRouterNavigationPending(for: "target"))

        singleton.loadVideo(videoId: "target")
        singleton.confirmRouterNavigationIfNeeded(videoId: "source")

        #expect(singleton.isRouterNavigationPending(for: "target"))
        #expect(!singleton.isRouterNavigationPending(for: "source"))

        singleton.loadVideo(videoId: "new-target")

        #expect(!singleton.isRouterNavigationPending(for: "target"))
        #expect(singleton.isRouterNavigationPending(for: "new-target"))

        singleton.confirmRouterNavigationIfNeeded(videoId: "new-target")

        #expect(!singleton.isRouterNavigationPending(for: "new-target"))
    }

    @Test("Losing the document releases a pending router recovery and requires a fresh page")
    func lostDocumentDoesNotCoalesceRouterRecovery() {
        let webView = RecordingPlaybackWebView()
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "source"
        singleton.loadVideo(videoId: "target")
        singleton.invalidateDocumentNavigationState()

        #expect(!singleton.isRouterNavigationPending(for: "target"))
        webView.scripts.removeAll()
        singleton.loadVideo(videoId: "target", strategy: .preferRouterWhenSameVideoId)

        #expect(!webView.scripts.contains { $0.contains("app.resolveCommand") })
        #expect(webView.scripts.contains { $0.contains("location.replace") })
    }

    @Test("Unconfirmed same-ID router recovery still falls back to a fresh document")
    func unconfirmedSameTrackRouterRecoveryTimesOut() async throws {
        let webView = RecordingPlaybackWebView()
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = "target"

        singleton.loadVideo(videoId: "target", strategy: .preferRouterWhenSameVideoId)

        #expect(singleton.isRouterNavigationPending(for: "target"))
        #expect(!webView.scripts.contains { $0.contains("location.replace") })
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while singleton.isRouterNavigationPending(for: "target"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(!singleton.isRouterNavigationPending(for: "target"))
        #expect(webView.scripts.contains { $0.contains("location.replace") })
        #expect(singleton.documentGeneration.inFlightGeneration != nil)
    }

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

    @Test("An unavailable SPA router retains the full-page recovery path", arguments: [
        SingletonPlayerWebView.VideoLoadStrategy.standard,
        .preferRouterWhenSameVideoId,
    ])
    func unavailableRouterFallsBackToDocumentNavigation(strategy: SingletonPlayerWebView.VideoLoadStrategy) {
        let webView = RecordingPlaybackWebView()
        webView.routerSucceeds = false
        let singleton = Self.makePlayer(webView: webView)
        defer { singleton.tearDown() }
        singleton.currentVideoId = strategy == .standard ? "source" : "target"

        singleton.loadVideo(videoId: "target", strategy: strategy)

        #expect(webView.scripts.contains { $0.contains("app.resolveCommand") })
        #expect(webView.scripts.contains { $0.contains("location.replace") })
        #expect(singleton.documentGeneration.inFlightGeneration != nil)
        #expect(!singleton.isRouterNavigationPending(for: "target"))
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
