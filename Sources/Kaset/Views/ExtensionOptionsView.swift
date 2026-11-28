import SwiftUI
import WebKit

struct ExtensionOptionsView: NSViewRepresentable {
    let page: WebKitManager.ExtensionPage

    func makeNSView(context: Context) -> WKWebView {
        let config = (self.page.configuration.copy() as? WKWebViewConfiguration) ?? self.page.configuration

        let consoleProxyScript = WKUserScript(
            source: """
            (function() {
                var oldLog = console.log;
                var oldError = console.error;
                var oldWarn = console.warn;
                console.log = function() {
                    window.webkit.messageHandlers.optionsDebug.postMessage("LOG: " + Array.from(arguments).join(" "));
                    oldLog.apply(console, arguments);
                };
                console.error = function() {
                    window.webkit.messageHandlers.optionsDebug.postMessage("ERROR: " + Array.from(arguments).join(" "));
                    oldError.apply(console, arguments);
                };
                console.warn = function() {
                    window.webkit.messageHandlers.optionsDebug.postMessage("WARN: " + Array.from(arguments).join(" "));
                    oldWarn.apply(console, arguments);
                };
                window.onerror = function(msg, url, line, col, error) {
                    window.webkit.messageHandlers.optionsDebug.postMessage("UNCAUGHT ERROR: " + msg + " at " + url + ":" + line + ":" + col);
                    return false;
                };
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(consoleProxyScript)
        config.userContentController.add(context.coordinator, name: "optionsDebug")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true

        webView.navigationDelegate = context.coordinator
        context.coordinator.load(page: self.page, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.loadedPageID != self.page.id || coordinator.loadedURL != self.page.url else {
            return
        }
        coordinator.load(page: self.page, into: webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private(set) var loadedPageID: String?
        private(set) var loadedURL: URL?
        private var activeNavigation: WKNavigation?
        private var pendingLoadTask: Task<Void, Never>?

        deinit {
            self.pendingLoadTask?.cancel()
        }

        func load(
            page: WebKitManager.ExtensionPage,
            into webView: WKWebView,
            isContextReady: @escaping @MainActor (String) -> Bool = { WebKitManager.shared.extensionPage(forExtensionId: $0) != nil }
        ) {
            self.loadedPageID = page.id
            self.loadedURL = page.url
            self.activeNavigation = nil
            self.pendingLoadTask?.cancel()

            let targetID = page.id
            let targetURL = page.url
            self.pendingLoadTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                let deadline = ContinuousClock.now + .seconds(5)
                while !isContextReady(targetID), ContinuousClock.now < deadline {
                    if Task.isCancelled {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                guard !Task.isCancelled,
                      self.loadedPageID == targetID,
                      self.loadedURL == targetURL
                else { return }
                guard isContextReady(targetID) else {
                    DiagnosticsLogger.extensions.warning("ExtensionOptionsView timed out waiting for extension context readiness")
                    self.loadedPageID = nil
                    self.loadedURL = nil
                    return
                }
                DiagnosticsLogger.extensions.info("ExtensionOptionsView loading URL: \(targetURL.absoluteString)")
                self.activeNavigation = webView.load(URLRequest(url: targetURL))
            }
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "optionsDebug" {
                DiagnosticsLogger.extensions.info("Options Console: \(String(describing: message.body))")
            }
        }

        func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            DiagnosticsLogger.extensions.info("Options page: Provisional navigation started.")
        }

        func webView(_: WKWebView, didCommit _: WKNavigation!) {
            DiagnosticsLogger.extensions.info("Options page: Navigation committed.")
        }

        func webView(_: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            DiagnosticsLogger.extensions.error("Options page navigation failed (Code \(nsError.code)): \(error.localizedDescription)")
            guard navigation === self.activeNavigation else { return }
            self.activeNavigation = nil
            self.loadedPageID = nil
            self.loadedURL = nil
        }

        func webView(_: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            DiagnosticsLogger.extensions.error("Options page load failed (Code \(nsError.code)): \(error.localizedDescription)")
            guard navigation === self.activeNavigation else { return }
            self.activeNavigation = nil
            self.loadedPageID = nil
            self.loadedURL = nil
        }

        func webView(_: WKWebView, didFinish navigation: WKNavigation!) {
            if navigation === self.activeNavigation {
                self.activeNavigation = nil
            }
            DiagnosticsLogger.extensions.info("Options page loaded successfully.")
        }
    }
}
