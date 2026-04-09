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
    static let shared = WebKitManager()

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

    override private init() {
        // Use the default persistent data store
        // This is more reliable than custom identifiers as it:
        // 1. Is the standard WebKit approach
        // 2. Shares cookies with the system's standard location
        // 3. Doesn't get reset when WebKit detects issues
        self.dataStore = WKWebsiteDataStore.default()

        super.init()

        // Observe cookie changes
        self.dataStore.httpCookieStore.add(self)

        // Restore auth cookies on startup.
        // Keychain is the source of truth; in DEBUG builds we also export to cookies.dat for tooling.
        if !UITestConfig.isRunningUnitTests {
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

        Task { await self.loadExtensions() }
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

            self.extensionContexts[id] = context

            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }

            for matchPattern in webExtension.requestedPermissionMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
            }

            try self.webExtensionController.load(context)
            try? await context.loadBackgroundContent()
            self.logger.info("Loaded extension \(webExtension.displayName ?? url.lastPathComponent) (\(webExtension.version ?? "?")). Options: \(context.optionsPageURL?.absoluteString ?? "none")")
        } catch {
            self.logger.error("Failed to load extension at \(url.path): \(error.localizedDescription)")
        }
    }

    /// Creates a WebView configuration using the shared persistent data store.
    func createWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = self.dataStore

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
    }
#endif
