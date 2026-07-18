import Foundation
import Testing
import WebKit
@testable import Kaset

/// Tests for `ExtensionContentScriptInjector` — the mechanism that actually
/// runs user-installed WebExtension content scripts inside Kaset's playback
/// WebViews (WebKit's WKWebExtensionController does not inject content into
/// these dedicated WebViews on current macOS).
@Suite(.serialized, .tags(.service))
@MainActor
struct ExtensionContentScriptInjectorTests {

    /// Writes an extension source folder and registers it with the shared
    /// `ExtensionsManager` via its public `addExtension(at:)` API.
    private func installExtension(named name: String, manifest: [String: Any], files: [String: String]) throws -> String {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-ext-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: source.appendingPathComponent("manifest.json"))
        for (file, contents) in files {
            try contents.write(to: source.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        try ExtensionsManager.shared.addExtension(at: source)
        return name
    }

    private func removeExtension(_ name: String) {
        let manager = ExtensionsManager.shared
        if let ext = manager.extensions.first(where: { $0.name == name }) {
            manager.removeExtension(id: ext.id)
        }
    }

    @Test("Produces a content script for a music.youtube.com extension")
    func buildsMusicContentScript() throws {
        let id = try self.installExtension(
            named: "MusicExt",
            manifest: [
                "manifest_version": 3,
                "name": "MusicExt",
                "version": "1.0.0",
                "content_scripts": [
                    [
                        "matches": ["https://music.youtube.com/*"],
                        "js": ["content.js"],
                        "run_at": "document_start",
                    ],
                ],
            ],
            files: ["content.js": "window.__musicExtRan = true;"]
        )
        defer { self.removeExtension(id) }

        let scripts = ExtensionContentScriptInjector.userScripts(for: .musicPlayer)
        #expect(scripts.count == 1)
        #expect(scripts.first?.injectionTime == .atDocumentStart)
        #expect((scripts.first?.source ?? "").contains("window.__musicExtRan = true;"))
    }

    @Test("Does not surface a music extension in the video player")
    func scopesMusicScriptToMusicPlayer() throws {
        let id = try self.installExtension(
            named: "MusicExt",
            manifest: [
                "manifest_version": 3,
                "name": "MusicExt",
                "version": "1.0.0",
                "content_scripts": [
                    ["matches": ["https://music.youtube.com/*"], "js": ["content.js"]],
                ],
            ],
            files: ["content.js": "window.__musicExtRan = true;"]
        )
        defer { self.removeExtension(id) }

        #expect(ExtensionContentScriptInjector.userScripts(for: .youtubeWatch).isEmpty)
    }

    @Test("Builds a stylesheet script for a youtube.com extension")
    func buildsStyleSheet() throws {
        let id = try self.installExtension(
            named: "CssExt",
            manifest: [
                "manifest_version": 3,
                "name": "CssExt",
                "version": "1.0.0",
                "content_scripts": [
                    [
                        "matches": ["*://*.youtube.com/*"],
                        "css": ["style.css"],
                    ],
                ],
            ],
            files: ["style.css": "body { color: red; }"]
        )
        defer { self.removeExtension(id) }

        let styles = ExtensionContentScriptInjector.styleSheets(for: .youtubeWatch)
        #expect(styles.count == 1)
        #expect((styles.first?.source ?? "").contains("body { color: red; }"))
    }

    @Test("Ignores disabled extensions")
    func skipsDisabledExtensions() throws {
        let name = try self.installExtension(
            named: "DisabledExt",
            manifest: [
                "manifest_version": 3, "name": "DisabledExt", "version": "1.0.0",
                "content_scripts": [["matches": ["https://music.youtube.com/*"], "js": ["c.js"]]],
            ],
            files: ["c.js": "window.x=1;"]
        )
        defer { self.removeExtension(name) }

        // Disable it via the public toggle, then it should no longer contribute scripts.
        if let ext = ExtensionsManager.shared.extensions.first(where: { $0.name == name }) {
            ExtensionsManager.shared.toggleExtension(id: ext.id)
        }
        #expect(ExtensionContentScriptInjector.userScripts(for: .musicPlayer).isEmpty)
    }

    /// End-to-end: the generated content script actually runs inside a WebView
    /// that loads the matching origin (this is what WKWebExtensionController
    /// fails to do on current macOS).
    @Test("Injected content script runs in a matching WebView")
    func scriptRunsInWebView() async throws {
        let id = try self.installExtension(
            named: "RunExt",
            manifest: [
                "manifest_version": 3,
                "name": "RunExt",
                "version": "1.0.0",
                "content_scripts": [
                    ["matches": ["<all_urls>"], "js": ["c.js"], "run_at": "document_start"],
                ],
            ],
            files: ["c.js": "document.documentElement.setAttribute('data-kaset-ext', 'ran');"]
        )
        defer { self.removeExtension(id) }

        let scripts = ExtensionContentScriptInjector.userScripts(for: .musicPlayer)
        #expect(!scripts.isEmpty)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = config.userContentController
        for script in scripts { controller.addUserScript(script) }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), configuration: config)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = webView

        let loaded = self.load(html: "<!doctype html><html><head></head><body>hi</body></html>", in: webView)
        _ = await loaded.value

        let ran = try? await webView.evaluateJavaScript("document.documentElement.getAttribute('data-kaset-ext')") as? String
        #expect(ran == "ran")
    }

    private func load(html: String, in webView: WKWebView) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let delegate = LoadAwaitDelegate { continuation.resume() }
                webView.navigationDelegate = delegate
                webView.loadHTMLString(html, baseURL: URL(string: "https://music.youtube.com/"))
                // Retain the delegate until the load completes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withExtendedLifetime(delegate) {}
                }
            }
        }
    }
}

private final class LoadAwaitDelegate: NSObject, WKNavigationDelegate {
    private let onLoad: () -> Void
    init(onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func webView(_: WKWebView, didFinish _: WKNavigation!) { self.onLoad() }
    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) { self.onLoad() }
}
