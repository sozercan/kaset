import Foundation
import os
import Security
import WebKit

// MARK: - WebKitManager

/// Manages WebKit data store for persistent cookies and session management.
@MainActor
@Observable
final class WebKitManager: NSObject, WebKitManagerProtocol {
    /// Shared singleton instance.
    static let shared = WebKitManager(dataStore: .default(), restoresCookies: true, loadsExtensions: true)

    /// Creates an isolated manager for unit tests.
    static func makeTestInstance() -> WebKitManager {
        WebKitManager(dataStore: .nonPersistent(), restoresCookies: false, loadsExtensions: false)
    }

    /// The persistent website data store used across all WebViews.
    let dataStore: WKWebsiteDataStore

    /// Timestamp of the last cookie change (for observation).
    private(set) var cookiesDidChange: Date = .distantPast

    /// Flag to prevent cookie backups while restoring from Keychain.
    private var isRestoringCookies = false

    /// Task for debouncing cookie change handling.
    private var cookieDebounceTask: Task<Void, Never>?

    /// Task for the one-time startup restore from Keychain into WebKit.
    private var initialCookieRestoreTask: Task<Void, Never>?

    /// Minimum interval between cookie backup operations (in seconds).
    private static let cookieDebounceInterval: Duration = .seconds(5)

    /// The YouTube Music origin URL.
    static let origin = "https://music.youtube.com"

    @MainActor
    let webExtensionController = WKWebExtensionController()

    /// Required cookie name for authentication.
    static let authCookieName = "__Secure-3PAPISID"

    /// Fallback cookie name (non-secure version).
    static let fallbackAuthCookieName = "SAPISID"

    /// Custom user agent to appear as Safari to avoid "browser not supported" errors.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let logger = DiagnosticsLogger.webKit

    private var extensionContexts: [String: WKWebExtensionContext] = [:]

    #if compiler(>=5.9)
        @ObservationIgnored
        @available(macOS 15.4, *)
        private lazy var webExtensionHost = KasetWebExtensionHost(
            controller: self.webExtensionController,
            logger: DiagnosticsLogger.extensions
        )
    #endif

    private init(dataStore: WKWebsiteDataStore, restoresCookies: Bool, loadsExtensions: Bool) {
        self.dataStore = dataStore

        super.init()

        // Observe cookie changes
        self.dataStore.httpCookieStore.add(self)

        // Restore auth cookies on startup.
        // Keychain is the source of truth; in DEBUG builds we also export to cookies.dat for tooling.
        if restoresCookies, !UITestConfig.isRunningUnitTests {
            self.initialCookieRestoreTask = Task { @MainActor in
                await self.restoreAuthCookiesFromBackup()
                self.initialCookieRestoreTask = nil
            }
        }

        self.logger.info("WebKitManager initialized with persistent data store")

        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                self.webExtensionController.delegate = self
            }
        #endif

        if loadsExtensions {
            Task { await self.loadExtensions() }
        }
    }

    /// Returns `true` if any web extension is currently loaded.
    var isExtensionLoaded: Bool {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                return !self.webExtensionController.extensionContexts.isEmpty
            }
        #endif
        return false
    }

    /// Number of currently loaded extensions.
    var loadedExtensionCount: Int {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                return self.webExtensionController.extensionContexts.count
            }
        #endif
        return 0
    }

    /// Returns the version string of the first loaded extension, if any.
    var extensionVersion: String? {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                return self.webExtensionController.extensionContexts.first?.webExtension.version
            }
        #endif
        return nil
    }

    /// Restores auth cookies from Keychain to WebKit.
    /// Handles migration from legacy file-based storage on first run.
    private func restoreAuthCookiesFromBackup() async {
        self.isRestoringCookies = true
        defer { isRestoringCookies = false }

        // Wait a moment for WebKit to fully initialize
        try? await Task.sleep(for: .milliseconds(100))

        // Migrate from legacy file-based storage if needed (one-time operation).
        // Perform file I/O off the main actor.
        _ = await Task(priority: .utility) {
            LegacyCookieMigration.migrateIfNeeded()
        }.value

        let existingCookies = await dataStore.httpCookieStore.allCookies()
        self.logger.info("WebKit has \(existingCookies.count) cookies on startup")

        // Load cookies from Keychain.
        // Perform Keychain I/O off the main actor; decode on main actor.
        let archiveData = await Task(priority: .utility) {
            KeychainCookieStorage.loadArchiveData()
        }.value

        guard let archiveData else {
            self.logger.info("No cookies found in Keychain (first run or signed out)")
            return
        }

        let keychainCookies = KeychainCookieStorage.decodeCookies(from: archiveData)
        guard !keychainCookies.isEmpty else {
            self.logger.info("No valid cookies found in Keychain")
            return
        }

        #if DEBUG
            DebugCookieFileExporter.exportAuthCookiesArchiveData(archiveData)
        #endif

        self.logger.info("Restoring \(keychainCookies.count) auth cookies from Keychain")

        // Set each cookie in WebKit
        for cookie in keychainCookies {
            await self.dataStore.httpCookieStore.setCookie(cookie)
        }

        // Verify restore
        let cookies = await dataStore.httpCookieStore.allCookies()
        let hasAuth = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }

        if hasAuth {
            self.logger.info("✓ Auth cookies restored from Keychain (\(cookies.count) total cookies)")
        } else {
            self.logger.error("✗ Failed to restore auth cookies - Keychain data may be corrupted")
        }
    }

    /// Loads all enabled extensions from `ExtensionsManager`.
    private func loadExtensions() async {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                let resolvedURLs = ExtensionsManager.shared.resolvedURLs()
                guard !resolvedURLs.isEmpty else {
                    self.logger.info("No enabled extensions to load")
                    return
                }

                for (id, url) in resolvedURLs {
                    await self.loadSingleExtension(at: url, id: id)
                }

                self.logger.info("Loaded \(self.webExtensionController.extensionContexts.count) extension(s)")
            }
        #endif
    }

    /// Loads a single web extension from a directory URL.
    @available(macOS 14.0, *)
    private func loadSingleExtension(at url: URL, id: String) async {
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: url)
            let context = WKWebExtensionContext(for: webExtension)
            // WebKit generates a new context identifier by default, which would
            // move extension storage and webkit-extension:// origins every launch.
            // Use Kaset's persisted managed-extension ID as the stable host identity.
            context.uniqueIdentifier = id

            self.extensionContexts[id] = context

            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }

            for matchPattern in webExtension.requestedPermissionMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
            }

            if #available(macOS 15.4, *) {
                for matchPattern in Self.contentScriptMatchPatterns(from: webExtension.manifest) {
                    context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
                }
            }

            try self.webExtensionController.load(context)
            if webExtension.hasBackgroundContent {
                try? await context.loadBackgroundContent()
            }
            self.logger.info("Loaded extension \(webExtension.displayName ?? url.lastPathComponent) (\(webExtension.version ?? "?")). Options: \(context.optionsPageURL?.absoluteString ?? "none")")
        } catch {
            self.logger.error("Failed to load extension at \(url.path): \(error.localizedDescription)")
        }
    }

    @available(macOS 15.4, *)
    static func contentScriptMatchPatterns(from manifest: [AnyHashable: Any]) -> [WKWebExtension.MatchPattern] {
        guard let contentScripts = manifest["content_scripts"] as? [[String: Any]] else {
            return []
        }

        var patterns: [WKWebExtension.MatchPattern] = []
        var seen = Set<String>()

        for contentScript in contentScripts {
            guard let matches = contentScript["matches"] as? [String] else { continue }
            for match in matches where seen.insert(match).inserted {
                guard let pattern = try? WKWebExtension.MatchPattern(string: match) else { continue }
                patterns.append(pattern)
            }
        }

        return patterns
    }

    /// Creates a WebView configuration using the shared persistent data store by default.
    func createWebViewConfiguration(websiteDataStore: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore ?? self.dataStore

        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                configuration.webExtensionController = self.webExtensionController
            }
        #endif

        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Enable AirPlay for streaming to Apple TV, HomePod, etc.
        configuration.allowsAirPlayForMediaPlayback = true

        return configuration
    }

    /// Registers a Kaset-owned playback WebView as a browser tab for Web Extensions.
    ///
    /// WebKit can attach a `WKWebExtensionController` to a `WKWebViewConfiguration`,
    /// but content injection and tab-scoped APIs also require the app to expose a
    /// lightweight `WKWebExtensionTab`/`WKWebExtensionWindow` model.
    func registerExtensionHostWebView(_ webView: WKWebView, role: WebExtensionHostedWebViewRole) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.register(webView: webView, role: role)
            }
        #endif
    }

    func extensionHostWebViewWillNavigate(_ webView: WKWebView, to url: URL?) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteNavigationStarted(for: webView, pendingURL: url)
            }
        #endif
    }

    func extensionHostWebViewDidStartNavigation(_ webView: WKWebView) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteNavigationStarted(for: webView, pendingURL: nil)
            }
        #endif
    }

    func extensionHostWebViewDidBecomeActive(_ webView: WKWebView) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteBecameActive(webView: webView)
            }
        #endif
    }

    func extensionHostWebViewDidDeactivate(role: WebExtensionHostedWebViewRole) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.deactivate(role: role)
            }
        #endif
    }

    func extensionHostWebViewDidFinishNavigation(_ webView: WKWebView) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteNavigationFinished(for: webView)
            }
        #endif
    }

    func extensionHostWebViewDidFailNavigation(_ webView: WKWebView) {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                self.webExtensionHost.noteNavigationFailed(for: webView)
            }
        #endif
    }

    /// Creates the minimal WebView configuration used for hidden account-switch
    /// navigations. It deliberately shares only the website data store (cookies)
    /// and does not attach the app's `WKWebExtensionController`, so enabled
    /// extensions/content scripts cannot observe credential-bearing signin URLs.
    func createSessionSwitchWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = self.dataStore
        return configuration
    }

    /// Metadata required to present an extension-owned page in a dedicated web view.
    struct ExtensionPage: Identifiable {
        let id: String
        let url: URL
        let configuration: WKWebViewConfiguration
    }

    /// Resolves the options or popup page for a loaded extension.
    func extensionPage(forExtensionId id: String) -> ExtensionPage? {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                guard let context = self.extensionContexts[id] else { return nil }
                guard let configuration = context.webViewConfiguration else { return nil }

                if let optionsURL = context.optionsPageURL {
                    return ExtensionPage(id: id, url: optionsURL, configuration: configuration)
                }

                guard let managedExt = ExtensionsManager.shared.extensions.first(where: { $0.id == id }),
                      let relativePath = managedExt.optionsPath ?? managedExt.popupPath,
                      let fallbackURL = Self.extensionResourceURL(relativePath: relativePath, baseURL: context.baseURL)
                else {
                    return nil
                }

                return ExtensionPage(id: id, url: fallbackURL, configuration: configuration)
            }
        #endif
        return nil
    }

    /// Gets the options page URL for a loaded extension by its Kaset internal ID.
    func optionsPageURL(forExtensionId id: String) -> URL? {
        self.extensionPage(forExtensionId: id)?.url
    }

    /// Gets the options page URL for a loaded extension by name (deprecated/fallback).
    func optionsPageURL(forExtensionNamed name: String) -> URL? {
        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                self.logger.info("Looking for options page for extension: \(name)")
                for context in self.webExtensionController.extensionContexts {
                    let displayName = context.webExtension.displayName ?? ""
                    self.logger.debug("Checking context: \(displayName)")
                    if displayName == name {
                        let url = context.optionsPageURL
                        self.logger.info("Found options page URL: \(url?.absoluteString ?? "nil")")
                        return url
                    }
                }
                self.logger.warning("No extension found with display name: \(name)")
            }
        #endif
        return nil
    }

    static func extensionResourceURL(relativePath: String, baseURL: URL) -> URL? {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        if let components = URLComponents(string: trimmedPath), components.scheme != nil || components.host != nil {
            return nil
        }

        let normalizedPath = trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return nil }

        let rootURL = baseURL.hasDirectoryPath ? baseURL : baseURL.appendingPathComponent("", isDirectory: true)
        return URL(string: normalizedPath, relativeTo: rootURL)?.absoluteURL
    }

    /// Waits for the one-time startup cookie restore to finish.
    func waitForInitialCookieRestore() async {
        if let restoreTask = self.initialCookieRestoreTask {
            await restoreTask.value
        }
    }

    /// Retrieves all cookies from the HTTP cookie store.
    func getAllCookies() async -> [HTTPCookie] {
        await self.dataStore.httpCookieStore.allCookies()
    }

    /// Gets cookies for a specific domain.
    /// Uses proper domain matching: exact match or cookie domain with leading dot matches subdomains.
    func getCookies(for domain: String) async -> [HTTPCookie] {
        let allCookies = await getAllCookies()
        let normalizedDomain = domain.lowercased()
        return allCookies.filter { cookie in
            let cookieDomain = cookie.domain.lowercased()
            // Exact match
            if cookieDomain == normalizedDomain {
                return true
            }
            // Cookie domain with leading dot matches the domain and all subdomains
            // e.g., ".youtube.com" matches "music.youtube.com" and "youtube.com"
            if cookieDomain.hasPrefix(".") {
                let withoutDot = String(cookieDomain.dropFirst())
                return normalizedDomain == withoutDot || normalizedDomain.hasSuffix("." + withoutDot)
            }
            // Request domain is a subdomain of cookie domain
            // e.g., cookie for "youtube.com" should match "music.youtube.com"
            if normalizedDomain.hasSuffix("." + cookieDomain) {
                return true
            }
            return false
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
    /// Checks both secure and non-secure cookie variants.
    func getSAPISID() async -> String? {
        let cookies = await getCookies(for: "youtube.com")
        let allCookies = await getAllCookies()
        self.logger.debug("Checking for SAPISID - total cookies: \(allCookies.count), youtube.com cookies: \(cookies.count)")

        // Try secure cookie first, then fallback to non-secure
        let secureCookie = cookies.first { $0.name == Self.authCookieName }
        let fallbackCookie = cookies.first { $0.name == Self.fallbackAuthCookieName }

        if let cookie = secureCookie ?? fallbackCookie {
            // Log cookie expiration for debugging session issues
            if let expiresDate = cookie.expiresDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                let expiresStr = formatter.string(from: expiresDate)
                let isExpired = expiresDate < Date()
                self.logger.debug("Found \(cookie.name) cookie, expires: \(expiresStr), expired: \(isExpired)")

                if isExpired {
                    self.logger.warning("Auth cookie has expired!")
                    return nil
                }
            } else if cookie.isSessionOnly {
                self.logger.debug("Found \(cookie.name) cookie (session-only, no expiration)")
            }
            return cookie.value
        }

        let cookieNames = cookies.map(\.name).joined(separator: ", ")
        self.logger.debug("No auth cookie found. Available cookies: \(cookieNames)")
        return nil
    }

    /// Checks if the required authentication cookies exist.
    func hasAuthCookies() async -> Bool {
        let sapisid = await getSAPISID()
        return sapisid != nil
    }

    /// Logs all authentication-related cookies for debugging.
    /// Call this when troubleshooting login persistence issues.
    func logAuthCookies() async {
        let cookies = await getCookies(for: "youtube.com")
        let authCookieNames = ["SAPISID", "__Secure-3PAPISID", "SID", "HSID", "SSID", "APISID", "__Secure-1PAPISID"]

        self.logger.info("=== Auth Cookie Diagnostic ===")
        self.logger.info("Total youtube.com cookies: \(cookies.count)")

        for name in authCookieNames {
            if let cookie = cookies.first(where: { $0.name == name }) {
                let expiry: String
                if let date = cookie.expiresDate {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    expiry = formatter.string(from: date)
                } else if cookie.isSessionOnly {
                    expiry = "session-only"
                } else {
                    expiry = "unknown"
                }
                self.logger.info("✓ \(name): expires \(expiry)")
            } else {
                self.logger.info("✗ \(name): not found")
            }
        }
        self.logger.info("==============================")
    }

    /// Clears only authentication cookies, preserving public WebKit cache/data.
    func clearAuthCookies() async {
        self.logger.info("Clearing WebKit auth cookies")
        let cookies = await self.dataStore.httpCookieStore.allCookies()
        for cookie in cookies where KeychainCookieStorage.authCookieNames.contains(cookie.name) {
            await self.dataStore.httpCookieStore.deleteCookie(cookie)
        }
        KeychainCookieStorage.deleteCookies()
        self.cookiesDidChange = Date()
    }

    /// Clears all website data (cookies, cache, etc.).
    func clearAllData() async {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let dateFrom = Date.distantPast

        self.logger.info("Clearing all WebKit data")

        await self.dataStore.removeData(ofTypes: allTypes, modifiedSince: dateFrom)

        // Also clear cookies from Keychain
        KeychainCookieStorage.deleteCookies()

        self.logger.info("WebKit data cleared successfully")
    }

    /// Forces an immediate save of all YouTube/Google cookies to Keychain.
    /// Call this after successful login to ensure cookies are persisted.
    func forceBackupCookies() async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        self.logger.info("Force backup: found \(cookies.count) total cookies")

        // Filter for YouTube/Google auth cookies
        let authCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com")
        }

        self.logger.info("Force backup: \(authCookies.count) YouTube/Google cookies to Keychain")
        guard let archive = KeychainCookieStorage.makeArchiveData(from: authCookies) else { return }

        // Perform Keychain/file I/O off the main actor.
        // Fire-and-forget: failures are handled inside KeychainCookieStorage.
        Task(priority: .utility) {
            _ = KeychainCookieStorage.saveArchiveData(archive.data, cookieCount: archive.cookieCount)
            #if DEBUG
                DebugCookieFileExporter.exportAuthCookiesArchiveData(archive.data)
            #endif
        }
    }
}

// MARK: WKHTTPCookieStoreObserver

extension WebKitManager: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            self.cookiesDidChange = Date()

            guard !self.isRestoringCookies else { return }

            // Debounce cookie backup to avoid excessive writes
            // WebKit fires this callback for each individual cookie change,
            // which can result in dozens of calls in rapid succession
            self.cookieDebounceTask?.cancel()
            self.cookieDebounceTask = Task {
                do {
                    try await Task.sleep(for: Self.cookieDebounceInterval)
                } catch is CancellationError {
                    // Task was cancelled (new cookie change came in), skip backup
                    return
                } catch {
                    // Unexpected error during sleep - log and continue with backup
                    self.logger.warning("Unexpected error during cookie debounce: \(error.localizedDescription)")
                }

                // Perform debounced backup
                await self.performCookieBackup(cookieStore: cookieStore)
            }
        }
    }

    /// Performs the actual cookie backup after debouncing.
    private func performCookieBackup(cookieStore: WKHTTPCookieStore) async {
        let cookies = await cookieStore.allCookies()

        // Filter for YouTube/Google auth cookies
        let authCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com")
        }

        guard let archive = KeychainCookieStorage.makeArchiveData(from: authCookies) else { return }

        // Perform Keychain/file I/O off the main thread.
        Task.detached(priority: .utility) {
            _ = KeychainCookieStorage.saveArchiveData(archive.data, cookieCount: archive.cookieCount)
            #if DEBUG
                DebugCookieFileExporter.exportAuthCookiesArchiveData(archive.data)
            #endif
        }
    }
}

#if compiler(>=5.9)
    @available(macOS 14.0, *)
    extension WebKitManager: WKWebExtensionControllerDelegate {
        func webExtensionController(_: WKWebExtensionController, shouldShowPromptFor permissions: Set<WKWebExtension.Permission>, in _: WKWebExtensionContext) async -> Bool {
            self.logger.info("Showing permission prompt for: \(permissions.map(\.rawValue).joined(separator: ", "))")
            return true
        }

        func webExtensionController(_: WKWebExtensionController, shouldShowPromptFor matchPatterns: Set<WKWebExtension.MatchPattern>, in _: WKWebExtensionContext) async -> Bool {
            self.logger.info("Showing match-pattern prompt for: \(matchPatterns.map(\.string).joined(separator: ", "))")
            return true
        }

        @available(macOS 15.4, *)
        func webExtensionController(_: WKWebExtensionController, openWindowsFor _: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
            self.webExtensionHost.openWindows
        }

        @available(macOS 15.4, *)
        func webExtensionController(_: WKWebExtensionController, focusedWindowFor _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
            self.webExtensionHost.focusedWindow
        }
    }
#endif

// MARK: - SessionSwitchError

/// Errors raised while switching the WebView session's active delegated identity.
enum SessionSwitchError: LocalizedError {
    /// The page loaded but its `DATASYNC_ID` did not reflect the expected identity.
    case identityNotApplied(expectedBrandId: String?)
    /// The switch navigation failed to load.
    case navigationFailed(underlying: String)
    /// The switch did not complete within the allotted time.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .identityNotApplied:
            "The account session could not be switched. Please try again."
        case .navigationFailed:
            "Failed to load the account switch page."
        case .timedOut:
            "Switching accounts timed out. Please try again."
        }
    }
}

extension WebKitManager {
    /// Switches the shared cookie session's active delegated identity by
    /// navigating a transient WebView to a server-issued account-switch URL.
    ///
    /// History is recorded by the playback page's own stats pings, which
    /// attribute to the identity baked into the served document's
    /// `ytcfg.DATASYNC_ID` (`"<delegatedSessionId>||<userSessionId>"` for a brand,
    /// `"<userSessionId>||"` for primary). Navigating the brand's `signinUrl`
    /// (which carries `&pageid=<brandId>`) re-points that identity for the single
    /// shared `WKWebsiteDataStore`, so subsequent watch loads — and their history
    /// pings — attribute to the brand.
    ///
    /// The method is verification-gated: it reads `DATASYNC_ID` after the
    /// navigation settles and throws ``SessionSwitchError/identityNotApplied(expectedBrandId:)``
    /// unless the result matches `expectedBrandId` (or, for `nil`, an empty
    /// delegated half indicating the primary identity). Callers should perform
    /// this switch *before* committing the new account so a failure can be
    /// surfaced and reverted rather than silently recording to the wrong account.
    ///
    /// - Parameters:
    ///   - signinURL: The server-issued `accountSigninToken.signinUrl`.
    ///   - expectedBrandId: The brand pageId to verify, or `nil` for the primary.
    func switchSessionIdentity(to signinURL: URL, expectedBrandId: String?) async throws {
        self.logger.info("Switching session identity (expecting \(expectedBrandId ?? "primary"))")
        guard AccountsListParser.isAllowedSigninURL(signinURL) else {
            throw SessionSwitchError.navigationFailed(underlying: "Refusing non-YouTube signin URL")
        }

        let configuration = self.createSessionSwitchWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent

        // Keep the navigation driver alive for the lifetime of the load.
        let driver = SessionSwitchNavigationDriver()
        webView.navigationDelegate = driver

        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }

        // Bail before mutating the shared cookie session if already cancelled
        // (e.g. a stale launch pin superseded by a newer switch).
        try Task.checkCancellation()

        do {
            try await driver.load(signinURL, in: webView, timeout: .seconds(20))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SessionSwitchError {
            throw error
        } catch {
            throw SessionSwitchError.navigationFailed(underlying: error.localizedDescription)
        }

        // The page's ytcfg may be emitted slightly after didFinish; poll briefly.
        // Note: the navigation above is the session MUTATION; this poll is
        // read-only verification. Correctness across concurrent pins relies on
        // ordering (the surviving navigation runs last), not on cancellation —
        // stopLoading() cannot revert cookies already set mid-redirect.
        for attempt in 0 ..< 5 {
            if let dataSyncId = try? await Self.readDataSyncId(from: webView),
               Self.dataSyncId(dataSyncId, matches: expectedBrandId)
            {
                self.logger.info("Session identity switch verified")
                return
            }
            if attempt < 4 {
                // Use a throwing sleep so cancellation breaks the poll loop.
                try await Task.sleep(for: .milliseconds(400))
            }
        }

        self.logger.error("Session identity switch could not be verified")
        throw SessionSwitchError.identityNotApplied(expectedBrandId: expectedBrandId)
    }

    /// Reads `ytcfg.DATASYNC_ID` from a loaded WebView.
    private static func readDataSyncId(from webView: WKWebView) async throws -> String? {
        let script = """
        (function() {
            try {
                if (window.ytcfg && typeof window.ytcfg.get === 'function') {
                    return window.ytcfg.get('DATASYNC_ID') || '';
                }
                if (window.ytcfg && window.ytcfg.data_) {
                    return window.ytcfg.data_['DATASYNC_ID'] || '';
                }
            } catch (e) {}
            return '';
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    /// Returns `true` when a `DATASYNC_ID` reflects the expected identity.
    ///
    /// `DATASYNC_ID` is `"<delegatedSessionId>||<userSessionId>"` for a brand
    /// (delegated/secondary channel) and `"<userSessionId>||"` for the primary
    /// account — i.e. the primary has a non-empty first half and an empty second
    /// half. A blank or malformed value (e.g. `""` or `"||"`, which the page JS
    /// returns when `ytcfg` has not populated yet) is treated as *no match* for
    /// either identity, so an unread page never falsely "verifies" as primary.
    static func dataSyncId(_ dataSyncId: String, matches expectedBrandId: String?) -> Bool {
        // A well-formed value has exactly two "||"-separated halves with a
        // non-empty first half (the user/delegated session id).
        let parts = dataSyncId.components(separatedBy: "||")
        guard parts.count == 2, !parts[0].isEmpty else {
            return false
        }
        let firstHalf = parts[0]
        let hasUserSessionSuffix = !parts[1].isEmpty
        // delegatedSessionId is present only for a secondary (brand) identity:
        // "<delegated>||<user>". Primary is "<user>||" (empty second half).
        let delegatedSessionId: String? = hasUserSessionSuffix ? firstHalf : nil
        if let expectedBrandId {
            return delegatedSessionId == expectedBrandId
        }
        return delegatedSessionId == nil
    }
}

// MARK: - SessionSwitchNavigationDriver

/// Drives a one-shot navigation to completion for ``WebKitManager/switchSessionIdentity(to:expectedBrandId:)``.
///
/// Bridges `WKNavigationDelegate` callbacks into a single awaitable result and
/// enforces a timeout so a hung redirect chain cannot block the switch forever.
@MainActor
private final class SessionSwitchNavigationDriver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    func load(_ url: URL, in webView: WKWebView, timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The enclosing Task may have been cancelled between the call and
                // this body running; bail out immediately if so.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard let self, !self.finished else { return }
                    self.complete(with: .failure(SessionSwitchError.timedOut))
                }
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            // Cooperative cancellation: resolve promptly with CancellationError so
            // a stale pin does not block a newer switch for the full navigation.
            Task { @MainActor [weak self] in
                self?.complete(with: .failure(CancellationError()))
            }
        }
    }

    private func complete(with result: Result<Void, Error>) {
        guard !self.finished else { return }
        self.finished = true
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        self.complete(with: .success(()))
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        self.complete(with: .failure(SessionSwitchError.navigationFailed(underlying: error.localizedDescription)))
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        self.complete(with: .failure(SessionSwitchError.navigationFailed(underlying: error.localizedDescription)))
    }
}
