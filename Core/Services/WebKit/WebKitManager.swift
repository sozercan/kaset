import Foundation
import os
import WebKit

// MARK: - WebKitManager

/// Manages WebKit data store for persistent cookies and session management.
@MainActor
@Observable
final class WebKitManager: NSObject {
    /// Shared singleton instance.
    static let shared = WebKitManager()

    /// The persistent website data store used across all WebViews.
    let dataStore: WKWebsiteDataStore

    /// Timestamp of the last cookie change (for observation).
    private(set) var cookiesDidChange: Date = .distantPast

    /// The YouTube Music origin URL.
    static let origin = "https://music.youtube.com"

    /// Required cookie name for authentication.
    static let authCookieName = "__Secure-3PAPISID"

    /// Custom user agent to appear as Safari to avoid "browser not supported" errors.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let logger = DiagnosticsLogger.webKit

    override private init() {
        // Create a persistent data store with a stable identifier
        // Using a known UUID ensures cookies persist across app launches
        let storeIdentifier = UUID(uuidString: "E5000000-0000-0000-0000-000000000001")!
        dataStore = WKWebsiteDataStore(forIdentifier: storeIdentifier)

        super.init()

        // Observe cookie changes
        dataStore.httpCookieStore.add(self)

        logger.info("WebKitManager initialized with persistent data store")
    }

    /// Creates a WebView configuration using the shared persistent data store.
    func createWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }

    /// Retrieves all cookies from the HTTP cookie store.
    func getAllCookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
    }

    /// Gets cookies for a specific domain.
    func getCookies(for domain: String) async -> [HTTPCookie] {
        let allCookies = await getAllCookies()
        return allCookies.filter { cookie in
            domain.hasSuffix(cookie.domain) || cookie.domain.hasSuffix(domain)
        }
    }

    /// Builds a Cookie header string for the given domain.
    func cookieHeader(for domain: String) async -> String? {
        let cookies = await getCookies(for: domain)
        guard !cookies.isEmpty else { return nil }

        let headerFields = HTTPCookie.requestHeaderFields(with: cookies)
        return headerFields["Cookie"]
    }

    /// Retrieves the SAPISID cookie value used for authentication.
    func getSAPISID() async -> String? {
        let cookies = await getCookies(for: "youtube.com")
        return cookies.first { $0.name == Self.authCookieName }?.value
    }

    /// Checks if the required authentication cookies exist.
    func hasAuthCookies() async -> Bool {
        let sapisid = await getSAPISID()
        return sapisid != nil
    }

    /// Clears all website data (cookies, cache, etc.).
    func clearAllData() async {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let dateFrom = Date.distantPast

        logger.info("Clearing all WebKit data")

        await dataStore.removeData(ofTypes: allTypes, modifiedSince: dateFrom)

        logger.info("WebKit data cleared successfully")
    }
}

// MARK: WKHTTPCookieStoreObserver

extension WebKitManager: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in _: WKHTTPCookieStore) {
        Task { @MainActor in
            self.cookiesDidChange = Date()
            logger.debug("Cookies changed at \(self.cookiesDidChange)")
        }
    }
}
