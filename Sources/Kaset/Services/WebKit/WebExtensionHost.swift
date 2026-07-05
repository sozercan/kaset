import AppKit
import Foundation
import os
import WebKit

// MARK: - WebExtensionHostedWebViewRole

/// Browser-tab identity for Kaset-owned playback WebViews exposed to WebKit Web Extensions.
///
/// Kaset does not have browser tabs in its UI, but WebKit's extension runtime still
/// needs a tab/window model so content scripts and extension APIs can resolve the
/// `WKWebView` they operate on.
enum WebExtensionHostedWebViewRole: String {
    case musicPlayer
    case youtubeWatch

    var displayTitle: String {
        switch self {
        case .musicPlayer:
            "YouTube Music Playback"
        case .youtubeWatch:
            "YouTube Video Playback"
        }
    }
}

#if compiler(>=5.9)
    @available(macOS 15.4, *)
    @MainActor
    final class KasetWebExtensionHost {
        private let controller: WKWebExtensionController
        private let logger: Logger
        private let window = KasetWebExtensionWindow()
        private var tabsByRole: [WebExtensionHostedWebViewRole: KasetWebExtensionTab] = [:]
        private var tabsByWebViewID: [ObjectIdentifier: KasetWebExtensionTab] = [:]
        private weak var activeTab: KasetWebExtensionTab?
        private var didOpenWindow = false

        init(controller: WKWebExtensionController, logger: Logger = DiagnosticsLogger.extensions) {
            self.controller = controller
            self.logger = logger
        }

        var registeredTabCount: Int {
            self.tabsByRole.count
        }

        var openWindows: [any WKWebExtensionWindow] {
            guard !self.tabsByRole.isEmpty else { return [] }
            return [self.window]
        }

        var focusedWindow: (any WKWebExtensionWindow)? {
            self.tabsByRole.isEmpty ? nil : self.window
        }

        @discardableResult
        func register(webView: WKWebView, role: WebExtensionHostedWebViewRole) -> KasetWebExtensionTab? {
            guard webView.configuration.webExtensionController === self.controller else {
                self.logger.warning("Skipping WebExtension tab registration for \(role.rawValue): configuration uses a different controller")
                return nil
            }

            let webViewID = ObjectIdentifier(webView)
            if let existing = self.tabsByRole[role] {
                if existing.webView !== webView {
                    if let oldWebView = existing.webView {
                        self.tabsByWebViewID.removeValue(forKey: ObjectIdentifier(oldWebView))
                    }
                    existing.webView = webView
                    existing.pendingNavigationURL = nil
                    self.tabsByWebViewID[webViewID] = existing
                    self.controller.didChangeTabProperties([.loading, .title, .URL, .size], for: existing)
                }
                self.activate(existing)
                return existing
            }

            let tab = KasetWebExtensionTab(role: role, webView: webView)
            tab.window = self.window
            self.tabsByRole[role] = tab
            self.tabsByWebViewID[webViewID] = tab
            self.window.append(tab)

            self.openWindowIfNeeded()
            self.controller.didOpenTab(tab)
            self.activate(tab)

            self.logger.info("Registered WebExtension tab for \(role.rawValue)")
            return tab
        }

        func noteNavigationStarted(for webView: WKWebView, pendingURL: URL?) {
            guard let tab = self.tab(for: webView) else { return }
            tab.pendingNavigationURL = pendingURL ?? tab.pendingNavigationURL
            if tab.pendingNavigationURL?.scheme?.hasPrefix("http") == true {
                self.activate(tab)
            }
            self.controller.didChangeTabProperties([.loading, .URL], for: tab)
        }

        func noteBecameActive(webView: WKWebView) {
            guard let tab = self.tab(for: webView) else { return }
            self.activate(tab)
        }

        func deactivate(role: WebExtensionHostedWebViewRole) {
            guard let tab = self.tabsByRole[role], self.activeTab === tab else { return }

            let fallbackTab = self.window.firstTab(excluding: tab)
            self.activeTab = nil
            self.window.activeTab = nil
            self.controller.didDeselectTabs([tab])

            if let fallbackTab {
                self.activate(fallbackTab)
            } else {
                self.controller.didFocusWindow(self.window)
            }
        }

        func noteNavigationFinished(for webView: WKWebView) {
            guard let tab = self.tab(for: webView) else { return }
            tab.pendingNavigationURL = nil
            self.controller.didChangeTabProperties([.loading, .title, .URL], for: tab)
        }

        func noteNavigationFailed(for webView: WKWebView) {
            guard let tab = self.tab(for: webView) else { return }
            tab.pendingNavigationURL = nil
            self.controller.didChangeTabProperties([.loading, .URL], for: tab)
        }

        private func tab(for webView: WKWebView) -> KasetWebExtensionTab? {
            self.tabsByWebViewID[ObjectIdentifier(webView)]
        }

        private func openWindowIfNeeded() {
            guard !self.didOpenWindow else { return }
            self.didOpenWindow = true
            self.controller.didOpenWindow(self.window)
            self.controller.didFocusWindow(self.window)
        }

        private func activate(_ tab: KasetWebExtensionTab) {
            guard self.activeTab !== tab else {
                self.controller.didFocusWindow(self.window)
                return
            }

            let previousTab = self.activeTab
            self.activeTab = tab
            self.window.activeTab = tab
            if let previousTab {
                self.controller.didDeselectTabs([previousTab])
            }
            self.controller.didActivateTab(tab, previousActiveTab: previousTab)
            self.controller.didSelectTabs([tab])
            self.controller.didFocusWindow(self.window)
        }
    }

    // MARK: - KasetWebExtensionTab

    @available(macOS 15.4, *)
    @MainActor
    final class KasetWebExtensionTab: NSObject, WKWebExtensionTab {
        let role: WebExtensionHostedWebViewRole
        weak var webView: WKWebView?
        weak var window: KasetWebExtensionWindow?
        var pendingNavigationURL: URL?

        init(role: WebExtensionHostedWebViewRole, webView: WKWebView) {
            self.role = role
            self.webView = webView
            super.init()
        }

        func window(for _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
            self.window
        }

        func indexInWindow(for _: WKWebExtensionContext) -> Int {
            guard let window = self.window else { return NSNotFound }
            return window.index(of: self) ?? NSNotFound
        }

        func webView(for _: WKWebExtensionContext) -> WKWebView? {
            self.webView
        }

        func title(for _: WKWebExtensionContext) -> String? {
            self.webView?.title ?? self.role.displayTitle
        }

        func url(for _: WKWebExtensionContext) -> URL? {
            self.webView?.url
        }

        func pendingURL(for _: WKWebExtensionContext) -> URL? {
            self.pendingNavigationURL
        }

        func isSelected(for _: WKWebExtensionContext) -> Bool {
            self.window?.activeTab === self
        }

        func isLoadingComplete(for _: WKWebExtensionContext) -> Bool {
            self.pendingNavigationURL == nil && self.webView?.isLoading == false
        }

        func size(for _: WKWebExtensionContext) -> CGSize {
            self.webView?.bounds.size ?? .zero
        }
    }

    // MARK: - KasetWebExtensionWindow

    @available(macOS 15.4, *)
    @MainActor
    final class KasetWebExtensionWindow: NSObject, WKWebExtensionWindow {
        private var tabs: [KasetWebExtensionTab] = []
        weak var activeTab: KasetWebExtensionTab?

        func append(_ tab: KasetWebExtensionTab) {
            guard !self.tabs.contains(where: { $0 === tab }) else { return }
            self.tabs.append(tab)
            if self.activeTab == nil {
                self.activeTab = tab
            }
        }

        func index(of tab: KasetWebExtensionTab) -> Int? {
            self.tabs.firstIndex { $0 === tab }
        }

        func firstTab(excluding excludedTab: KasetWebExtensionTab) -> KasetWebExtensionTab? {
            self.tabs.first { $0 !== excludedTab }
        }

        func tabs(for _: WKWebExtensionContext) -> [any WKWebExtensionTab] {
            self.tabs
        }

        func activeTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
            self.activeTab
        }

        func windowType(for _: WKWebExtensionContext) -> WKWebExtension.WindowType {
            .normal
        }

        func windowState(for _: WKWebExtensionContext) -> WKWebExtension.WindowState {
            guard let nsWindow = self.representativeNSWindow else { return .normal }
            if nsWindow.styleMask.contains(.fullScreen) { return .fullscreen }
            if nsWindow.isMiniaturized { return .minimized }
            if nsWindow.isZoomed { return .maximized }
            return .normal
        }

        func isPrivate(for _: WKWebExtensionContext) -> Bool {
            false
        }

        func screenFrame(for _: WKWebExtensionContext) -> CGRect {
            self.representativeNSWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null
        }

        func frame(for _: WKWebExtensionContext) -> CGRect {
            self.representativeNSWindow?.frame ?? .null
        }

        func focus(for _: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
            self.representativeNSWindow?.makeKeyAndOrderFront(nil)
            completionHandler(nil)
        }

        private var representativeNSWindow: NSWindow? {
            for tab in self.tabs {
                if let window = tab.webView?.window {
                    return window
                }
            }
            return nil
        }
    }
#endif
