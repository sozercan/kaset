import ObjectiveC
import SwiftUI
import WebKit

private func echoExtensionLog(_ level: String, _ message: String) {
    fputs("[Kaset][Extensions][\(level)] \(message)\n", stderr)
}

// MARK: - AssociatedKeys

private enum AssociatedKeys {
    @MainActor static var retryActionKey: UInt8 = 0
}

// MARK: - ExtensionOptionsView

/// A view that displays the options page of a WebKit extension.
@available(macOS 26.0, *)
struct ExtensionOptionsView: NSViewRepresentable {
    let page: WebKitManager.ExtensionPage

    func makeNSView(context: Context) -> NSView {
        let config = self.page.configuration

        // Inject script to pipe console to native
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
        // Ensure we don't double-register message handlers when the view is recreated.
        config.userContentController.removeScriptMessageHandler(forName: "optionsDebug")

        // Only add the script if it isn't already there to prevent duplicates
        let hasScript = config.userContentController.userScripts.contains { $0.source.contains("optionsDebug.postMessage") }
        if !hasScript {
            config.userContentController.addUserScript(consoleProxyScript)
        }

        config.userContentController.add(context.coordinator, name: "optionsDebug")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true

        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: self.page.url))
        return ExtensionWebViewContainer(webView: webView)
    }

    func updateNSView(_ container: NSView, context _: Context) {
        guard let container = container as? ExtensionWebViewContainer else { return }
        let webView = container.webView
        if webView.url != self.page.url, !webView.isLoading {
            // Tiny delay to ensure WebKit's internal extension registry has catch up with the ID
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                let msg = "ExtensionOptionsView loading URL: \(self.page.url.absoluteString)"
                DiagnosticsLogger.extensions.info("\(msg, privacy: .public)")
                echoExtensionLog("INFO", msg)
                webView.load(URLRequest(url: self.page.url))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        // URL to retry loading when an error occurs (set by makeNSView)
        var pageURL: URL?
        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "optionsDebug" {
                let msg = "Options Console: \(String(describing: message.body))"
                DiagnosticsLogger.extensions.info("\(msg, privacy: .public)")
                echoExtensionLog("INFO", msg)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            let msg = "Options page: Provisional navigation started."
            DiagnosticsLogger.extensions.info("\(msg, privacy: .public)")
            echoExtensionLog("INFO", msg)
            if let container = webView.superview as? ExtensionWebViewContainer {
                container.hideError()
            }
        }

        func webView(_: WKWebView, didCommit _: WKNavigation!) {
            let msg = "Options page: Navigation committed."
            DiagnosticsLogger.extensions.info("\(msg, privacy: .public)")
            echoExtensionLog("INFO", msg)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            let msg = "Options page navigation failed (Code \(nsError.code)): \(error.localizedDescription)"
            DiagnosticsLogger.extensions.error("\(msg, privacy: .public)")
            echoExtensionLog("ERROR", msg)
            if let container = webView.superview as? ExtensionWebViewContainer {
                container.showError(message: "Failed to load options page: \(nsError.localizedDescription)") { [weak self] in
                    if let url = self?.pageURL {
                        webView.load(URLRequest(url: url))
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            let msg = "Options page load failed (Code \(nsError.code)): \(error.localizedDescription)"
            DiagnosticsLogger.extensions.error("\(msg, privacy: .public)")
            echoExtensionLog("ERROR", msg)
            if let container = webView.superview as? ExtensionWebViewContainer {
                container.showError(message: "Failed to load options page: \(nsError.localizedDescription)") {
                    webView.reload()
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            let msg = "Options page loaded successfully."
            DiagnosticsLogger.extensions.info("\(msg, privacy: .public)")
            echoExtensionLog("INFO", msg)
            if let container = webView.superview as? ExtensionWebViewContainer {
                container.hideError()
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let msg = "Options page WebContent process terminated for \(webView.url?.absoluteString ?? "unknown")"
            DiagnosticsLogger.extensions.error("\(msg, privacy: .public)")
            echoExtensionLog("ERROR", msg)
        }
    }
}

// MARK: - ExtensionPopupView

/// A view that hosts the WebKit-managed browser-action popup WebView.
@available(macOS 26.0, *)
struct ExtensionPopupView: NSViewRepresentable {
    let page: WebKitManager.ExtensionPopupPage

    func makeNSView(context: Context) -> NSView {
        let webView = self.page.action.popupWebView ?? WKWebView()
        webView.isInspectable = true
        webView.navigationDelegate = context.coordinator
        context.coordinator.logPopupState(for: webView, label: "makeNSView")
        return ExtensionWebViewContainer(webView: webView)
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? ExtensionWebViewContainer else { return }
        context.coordinator.logPopupState(for: container.webView, label: "updateNSView")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            self.logPopupState(for: webView, label: "didFinish")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            DiagnosticsLogger.extensions.error("Popup WebContent process terminated for \(webView.url?.absoluteString ?? "unknown")")
        }

        func logPopupState(for webView: WKWebView, label: String) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                let script = """
                (() => JSON.stringify({
                    url: location.href,
                    readyState: document.readyState,
                    title: document.title,
                    bodyClass: document.body ? document.body.className : null,
                    bodyText: document.body ? document.body.innerText.slice(0, 160) : null,
                    hasBrowser: typeof browser,
                    hasChrome: typeof chrome,
                    hasVAPI: typeof vAPI,
                    hasMessaging: typeof vAPI === 'object' && vAPI !== null ? typeof vAPI.messaging : 'missing',
                    bodySize: document.body ? {
                        width: document.body.scrollWidth,
                        height: document.body.scrollHeight
                    } : null
                }))()
                """
                do {
                    let result = try await webView.evaluateJavaScript(script)
                    let resultStr = String(describing: result)
                    let msg = "Popup state [\(label)]: \(resultStr)"
                    DiagnosticsLogger.extensions.info("\(msg, privacy: .public)")
                    echoExtensionLog("INFO", msg)
                } catch {
                    let msg = "Popup state [\(label)] failed: \(error.localizedDescription)"
                    DiagnosticsLogger.extensions.error("\(msg, privacy: .public)")
                    echoExtensionLog("ERROR", msg)
                }

                // Additional diagnostics: outerHTML snippet and chrome/browser APIs presence
                let diagScript = """
                (() => JSON.stringify({
                    outerHTMLSnippet: document.documentElement ? document.documentElement.outerHTML.slice(0, 300) : null,
                    nodeCount: document.getElementsByTagName('*').length,
                    chromeKeys: typeof chrome === 'object' && chrome !== null ? Object.keys(chrome).slice(0,10) : null,
                    browserKeys: typeof browser === 'object' && browser !== null ? Object.keys(browser).slice(0,10) : null
                }))()
                """
                do {
                    let diag = try await webView.evaluateJavaScript(diagScript)
                    let diagStr = String(describing: diag)
                    let msg = "Popup diag [\(label)]: \(diagStr)"
                    DiagnosticsLogger.extensions.info("\(msg, privacy: .public)")
                    echoExtensionLog("INFO", msg)
                } catch {
                    let msg = "Popup diag [\(label)] failed: \(error.localizedDescription)"
                    DiagnosticsLogger.extensions.error("\(msg, privacy: .public)")
                    echoExtensionLog("ERROR", msg)
                }
            }
        }
    }
}

// MARK: - ExtensionWebViewContainer

@available(macOS 26.0, *)
private final class ExtensionWebViewContainer: NSView {
    let webView: WKWebView
    private var overlayView: NSView?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.webView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.webView)
        NSLayoutConstraint.activate([
            self.webView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.webView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.webView.topAnchor.constraint(equalTo: self.topAnchor),
            self.webView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
        ])
    }

    func showError(message: String, retryAction: @escaping () -> Void) {
        // Remove existing overlay
        self.hideError()

        let overlay = NSView(frame: .zero)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3

        let button = NSButton(title: "Retry", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(label)
        overlay.addSubview(button)
        self.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: self.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: self.bottomAnchor),

            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -10),
            label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.8),

            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            button.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        ])

        button.action = #selector(self.retryButtonPressed(_:))
        button.target = self

        // Store retry action via associated object
        objc_setAssociatedObject(button, &AssociatedKeys.retryActionKey, retryAction, .OBJC_ASSOCIATION_COPY_NONATOMIC)

        self.overlayView = overlay
    }

    func hideError() {
        if let overlay = self.overlayView {
            overlay.removeFromSuperview()
            self.overlayView = nil
        }
    }

    @objc private func retryButtonPressed(_ sender: NSButton) {
        if let action = objc_getAssociatedObject(sender, &AssociatedKeys.retryActionKey) as? () -> Void {
            action()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
