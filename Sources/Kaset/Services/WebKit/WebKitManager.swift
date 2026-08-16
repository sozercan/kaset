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

    /// Creates an isolated manager for unit tests. The cookie archive queue is private to the
    /// instance and backed by in-memory storage, so parallel suites cannot clear or overwrite
    /// each other's archive through the process-wide `CookieArchiveWriteQueue.shared`.
    static func makeTestInstance() -> WebKitManager {
        WebKitManager(
            dataStore: .nonPersistent(),
            restoresCookies: false,
            loadsExtensions: false,
            cookieArchiveQueue: CookieArchiveWriteQueue(storage: .inMemory())
        )
    }

    /// The persistent website data store used across all WebViews.
    let dataStore: WKWebsiteDataStore

    /// Serializes archive reads and writes for this manager's cookies. Defaults to the
    /// process-wide queue so production keeps a single archive; tests inject their own.
    let cookieArchiveQueue: CookieArchiveWriteQueue

    /// Timestamp of the last cookie change (for observation).
    private(set) var cookiesDidChange: Date = .distantPast

    func recordCookieChange() {
        self.cookiesDidChange = Date()
    }

    /// Flag to prevent cookie backups while restoring from Keychain.
    var isRestoringCookies = false

    /// Flag to prevent observer-driven backups while auth cookies are being cleared.
    var isClearingAuthCookies = false

    /// Serializes and coalesces every auth-cookie/data clearing operation.
    let authCookieClearCoordinator = AuthCookieClearCoordinator()

    /// Task for debouncing cookie change handling.
    var cookieDebounceTask: Task<Void, Never>?

    /// Coalesces callers that require the latest cookie snapshot to be persisted.
    var forcedCookieBackupTask: Task<Bool, Never>?

    /// Suppresses observer-driven persistence while a login baseline is captured.
    var isPreparingLoginCookieBackup = false

    /// Suppresses observer-driven persistence while a login backup is staged.
    var activeLoginCookieBackupTransaction: CookieBackupTransaction?

    /// Whether transaction setup failed to restore its prior durable state.
    var loginCookieBackupSetupRequiresCleanup = false

    /// Records cookie changes delivered while a forced snapshot is being persisted.
    var forcedCookieBackupDirty = false

    /// Task for the one-time startup restore from Keychain into WebKit.
    private var initialCookieRestoreTask: Task<Bool, Never>?

    /// Whether startup left authentication cookies safe to evaluate.
    private var initialCookieRestoreAllowsAuthentication = true

    /// Invalidates startup restores and backups that began before an auth-cookie clear.
    var authCookieOperationFence = AuthCookieOperationFence()

    /// Minimum interval between cookie backup operations (in seconds).
    static let cookieDebounceInterval: Duration = .seconds(5)

    /// The YouTube Music origin URL.
    static let origin = "https://music.youtube.com"

    @MainActor
    let webExtensionController = WKWebExtensionController()

    /// Required cookie name for authentication.
    nonisolated static let authCookieName = "__Secure-3PAPISID"

    /// Fallback cookie name (non-secure version).
    nonisolated static let fallbackAuthCookieName = "SAPISID"

    /// Custom user agent to appear as Safari to avoid "browser not supported" errors.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    let logger = DiagnosticsLogger.webKit

    private var extensionContexts: [String: WKWebExtensionContext] = [:]

    #if compiler(>=5.9)
        @ObservationIgnored
        @available(macOS 15.4, *)
        private lazy var webExtensionHost = KasetWebExtensionHost(
            controller: self.webExtensionController,
            logger: DiagnosticsLogger.extensions
        )
    #endif

    private init(
        dataStore: WKWebsiteDataStore,
        restoresCookies: Bool,
        loadsExtensions: Bool,
        cookieArchiveQueue: CookieArchiveWriteQueue = .shared
    ) {
        self.dataStore = dataStore
        self.cookieArchiveQueue = cookieArchiveQueue

        super.init()

        // Observe cookie changes
        self.dataStore.httpCookieStore.add(self)

        // Restore auth cookies on startup.
        // Keychain is the source of truth; in DEBUG builds we also export to cookies.dat for tooling.
        if restoresCookies, !UITestConfig.isRunningUnitTests {
            let restoreGeneration = self.authCookieOperationFence.generation
            self.initialCookieRestoreTask = Task { @MainActor in
                let allowsAuthentication = await self.restoreAuthCookiesFromBackup(
                    expectedGeneration: restoreGeneration
                )
                self.initialCookieRestoreAllowsAuthentication = allowsAuthentication
                self.initialCookieRestoreTask = nil
                return allowsAuthentication
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
    func waitForInitialCookieRestore() async -> Bool {
        if let restoreTask = self.initialCookieRestoreTask {
            return await restoreTask.value
        }
        return self.initialCookieRestoreAllowsAuthentication
    }

    /// Retrieves all cookies from the HTTP cookie store.
    func getAllCookies() async -> [HTTPCookie] {
        await self.dataStore.httpCookieStore.allCookies()
    }

    /// Gets cookies for a specific domain.
    /// Uses proper domain matching: exact match or cookie domain with leading dot matches subdomains.
    func getCookies(for domain: String) async -> [HTTPCookie] {
        let allCookies = await getAllCookies()
        return Self.cookies(allCookies, matching: domain)
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
    @discardableResult
    func clearAuthCookies() async -> Bool {
        await self.authCookieClearCoordinator.run(scope: .authenticationCookies) { [weak self] in
            guard let self else { return false }
            return await self.performAuthCookieClear()
        }
    }

    private func performAuthCookieClear() async -> Bool {
        self.logger.info("Clearing WebKit auth cookies")
        self.isClearingAuthCookies = true
        defer { self.isClearingAuthCookies = false }

        await self.fenceAuthCookieOperationsAndInvalidateBackup()

        // Invalidate once more after the initial fence so no operation that was
        // already queued before it can leave a durable stale snapshot. All live
        // verification happens after this final persistence suspension.
        let didInvalidatePersistedCookies = await self.cookieArchiveQueue.invalidateAndDelete()

        let liveClearResult = await LiveAuthCookieStoreClearer.clear(
            operations: LiveAuthCookieStoreClearer.Operations(
                readCookies: {
                    await self.dataStore.httpCookieStore.allCookies()
                },
                deleteCookie: { cookie in
                    await self.dataStore.httpCookieStore.deleteCookie(cookie)
                },
                removeAllCookies: {
                    await self.dataStore.removeData(
                        ofTypes: [WKWebsiteDataTypeCookies],
                        modifiedSince: .distantPast
                    )
                }
            )
        )
        if liveClearResult.usedCookieStoreFallback {
            self.logger.warning("Escalated authentication cleanup to the WebKit cookie data store")
        }
        if !liveClearResult.didClear {
            self.logger.error("Could not clear live authentication cookies")
        }

        let didClear = liveClearResult.didClear && didInvalidatePersistedCookies
        self.initialCookieRestoreAllowsAuthentication = didClear
        self.loginCookieBackupSetupRequiresCleanup = !didClear
        self.cookiesDidChange = Date()
        return didClear
    }

    /// Clears all website data (cookies, cache, etc.).
    @discardableResult
    func clearAllData() async -> Bool {
        await self.authCookieClearCoordinator.run(scope: .allWebsiteData) { [weak self] in
            guard let self else { return false }
            return await self.performAllWebsiteDataClear()
        }
    }

    private func performAllWebsiteDataClear() async -> Bool {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let dateFrom = Date.distantPast

        self.logger.info("Clearing all WebKit data")
        self.isClearingAuthCookies = true
        defer { self.isClearingAuthCookies = false }

        await self.fenceAuthCookieOperationsAndInvalidateBackup()
        await self.dataStore.removeData(ofTypes: allTypes, modifiedSince: dateFrom)

        // Repeat the invalidation after WebKit finishes clearing to close the
        // window for any already-enqueued observer or backup work.
        let didInvalidatePersistedCookies = await self.cookieArchiveQueue.invalidateAndDelete()
        let remainingCookies = await self.dataStore.httpCookieStore.allCookies()
        let didClearLiveCookies = !remainingCookies.contains(where: KeychainCookieStorage.isLoginDomainCookie)
        let didClear = didInvalidatePersistedCookies && didClearLiveCookies
        self.initialCookieRestoreAllowsAuthentication = didClear
        self.loginCookieBackupSetupRequiresCleanup = !didClear
        if didClear {
            self.logger.info("WebKit data cleared successfully")
        } else {
            self.logger.error("WebKit data or durable cookie invalidation could not be cleared")
        }
        self.cookiesDidChange = Date()
        return didClear
    }

    private func fenceAuthCookieOperationsAndInvalidateBackup() async {
        self.authCookieOperationFence.invalidate()
        self.activeLoginCookieBackupTransaction = nil
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil

        let restoreTask = self.initialCookieRestoreTask
        let backupTask = self.forcedCookieBackupTask
        restoreTask?.cancel()
        backupTask?.cancel()

        _ = await self.cookieArchiveQueue.invalidateAndDelete()
        _ = await restoreTask?.value
        _ = await backupTask?.value
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
