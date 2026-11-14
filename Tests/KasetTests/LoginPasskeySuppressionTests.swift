import Foundation
import Testing
import WebKit
@testable import Kaset

// MARK: - LoginPasskeySuppressionTests

/// Tests for LoginPasskeySuppression.
@Suite(.serialized, .tags(.service))
@MainActor
struct LoginPasskeySuppressionTests {
    @Test("User script injects at document start into all frames")
    func userScriptProperties() {
        let script = LoginPasskeySuppression.makeUserScript()
        #expect(script.source == LoginPasskeySuppression.scriptSource)
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.isForMainFrameOnly == false)
    }

    @Test("Session switch WebView configuration attaches the suppression script")
    func sessionSwitchConfigurationAttachesScript() {
        let manager = WebKitManager.makeTestInstance()
        let configuration = manager.createSessionSwitchWebViewConfiguration()
        let suppressionScript = configuration.userContentController.userScripts
            .first { $0.source == LoginPasskeySuppression.scriptSource }
        #expect(suppressionScript != nil)
        #expect(suppressionScript?.injectionTime == .atDocumentStart)
        #expect(suppressionScript?.isForMainFrameOnly == false)
    }

    @Test("WebAuthn API is exposed in a plain WebView", .timeLimit(.minutes(1)))
    func webAuthnExposedWithoutSuppression() async throws {
        // Baseline guard: if WKWebView ever stops exposing WebAuthn on its
        // own, the suppression script becomes redundant and the passkey
        // handling should be revisited.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        try await Self.loadBlankPage(in: webView)

        let credentialType = try await webView.evaluateJavaScript("typeof PublicKeyCredential") as? String
        #expect(credentialType == "function")
    }

    @Test("Session-switch configuration hides WebAuthn from pages", .timeLimit(.minutes(1)))
    func suppressionHidesWebAuthn() async throws {
        let webView = Self.makeSuppressedWebView()
        try await Self.loadBlankPage(in: webView)

        let credentialType = try await webView.evaluateJavaScript("typeof PublicKeyCredential") as? String
        #expect(credentialType == "undefined")
    }

    @Test("Passkey credential requests are rejected by the suppression shim", .timeLimit(.minutes(1)))
    func passkeyRequestsAreRejected() async throws {
        let webView = Self.makeSuppressedWebView()
        try await Self.loadBlankPage(in: webView)

        let errorDescription = try await webView.callAsyncJavaScript(
            """
            try {
                await navigator.credentials.get({ publicKey: { challenge: new Uint8Array(16) } });
                return "resolved";
            } catch (error) {
                return error.name + ": " + error.message;
            }
            """,
            contentWorld: .page
        ) as? String
        #expect(errorDescription == "NotAllowedError: Passkeys are not available in this app.")
    }

    // MARK: - Helpers

    private static func makeSuppressedWebView() -> WKWebView {
        let manager = WebKitManager.makeTestInstance()
        let configuration = manager.createSessionSwitchWebViewConfiguration()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private static func loadBlankPage(in webView: WKWebView) async throws {
        // WebAuthn is only exposed in secure contexts, so give the local page
        // an https origin; no network request is made for the page itself.
        let waiter = NavigationWaiter()
        try await waiter.waitForLoad(
            of: webView,
            html: "<html><body></body></html>",
            baseURL: URL(string: "https://accounts.google.com/")
        )
    }
}

// MARK: - NavigationWaiter

/// Awaits the completion of a single `loadHTMLString` navigation.
///
/// Cancellation-aware so the suite's `timeLimit` trait can end a stuck
/// navigation instead of suspending the test run indefinitely, and treats
/// WebContent process termination as a failure rather than waiting forever.
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private struct ContentProcessTerminatedError: Error {}

    private var continuation: CheckedContinuation<Void, any Error>?

    func waitForLoad(of webView: WKWebView, html: String, baseURL: URL?) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.navigationDelegate = self
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(throwing: CancellationError())
            }
        }
    }

    private func finish(throwing error: (any Error)? = nil) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        self.finish()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        self.finish(throwing: error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
        self.finish(throwing: error)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        self.finish(throwing: ContentProcessTerminatedError())
    }
}
