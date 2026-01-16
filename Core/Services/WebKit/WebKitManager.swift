import Foundation
import os
import Security
import WebKit

// MARK: - KeychainCookieStorage

/// Securely stores auth cookies in the macOS Keychain.
/// Provides encryption at rest and app-specific access control.
enum KeychainCookieStorage {
    private static let logger = DiagnosticsLogger.webKit

    /// Keychain service identifier for cookie storage.
    private static let service = "com.kaset.auth-cookies"

    /// Keychain account identifier.
    private static let account = "youtube-music-cookies"

    /// Cookie names required for YouTube Music authentication.
    static let authCookieNames = Set([
        "SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID",
        "SID", "HSID", "SSID", "APISID",
    ])

    static func isValidAuthCookie(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        guard self.authCookieNames.contains(cookie.name) else { return false }
        if let expiresDate = cookie.expiresDate, expiresDate < now {
            return false
        }
        return true
    }

    /// Creates the serialized archive we persist to Keychain (and in DEBUG to `cookies.dat`).
    /// Returns nil if there are no valid auth cookies to store.
    static func makeArchiveData(from cookies: [HTTPCookie]) -> (data: Data, cookieCount: Int)? {
        let now = Date()
        let authCookies = cookies.filter { cookie in
            Self.isValidAuthCookie(cookie, now: now)
        }

        guard !authCookies.isEmpty else { return nil }

        let cookieData = authCookies.compactMap { cookie -> Data? in
            guard let properties = cookie.properties else { return nil }
            var stringProperties: [String: Any] = [:]
            for (key, value) in properties {
                stringProperties[key.rawValue] = value
            }
            return try? NSKeyedArchiver.archivedData(
                withRootObject: stringProperties,
                requiringSecureCoding: false
            )
        }

        guard !cookieData.isEmpty,
              let data = try? NSKeyedArchiver.archivedData(
                  withRootObject: cookieData,
                  requiringSecureCoding: false
              )
        else {
            Self.logger.error("Failed to serialize cookies for Keychain")
            return nil
        }

        return (data: data, cookieCount: cookieData.count)
    }

    /// Saves YouTube auth cookies to the Keychain.
    static func saveCookies(_ cookies: [HTTPCookie]) {
        guard let archive = makeArchiveData(from: cookies) else { return }

        Self.saveArchiveData(archive.data, cookieCount: archive.cookieCount)
    }

    /// Saves an already-serialized cookie archive to the Keychain.
    static func saveArchiveData(_ data: Data, cookieCount: Int) {
        // Update existing item or add new one (atomic upsert)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var newQuery = query
            for (key, value) in attributes {
                newQuery[key] = value
            }
            status = SecItemAdd(newQuery as CFDictionary, nil)
        }

        if status == errSecSuccess {
            self.logger.debug("Saved \(cookieCount) auth cookies to Keychain")
        } else {
            self.logger.error("Failed to save cookies to Keychain: \(status)")
        }
    }

    /// Returns `true` if a Keychain item exists for our cookie storage.
    static func hasCookieItem() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Loads the raw serialized cookie archive data from Keychain.
    static func loadArchiveData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                Self.logger.info("No cookies found in Keychain (first run or signed out)")
            } else {
                Self.logger.error("Failed to load cookies from Keychain: \(status)")
            }
            return nil
        }

        return result as? Data
    }

    /// Decodes cookies from a serialized archive created by `makeArchiveData(from:)`.
    static func decodeCookies(from archiveData: Data) -> [HTTPCookie] {
        guard let cookieDataArray = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, NSData.self],
            from: archiveData
        ) as? [Data]
        else {
            self.logger.error("Failed to decode cookie archive data")
            return []
        }

        let cookies = cookieDataArray.compactMap { cookieData -> HTTPCookie? in
            guard let stringProperties = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSDictionary.self, NSString.self, NSDate.self, NSNumber.self],
                from: cookieData
            ) as? [String: Any] else {
                return nil
            }

            var convertedProperties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in stringProperties {
                convertedProperties[HTTPCookiePropertyKey(key)] = value
            }
            return HTTPCookie(properties: convertedProperties)
        }

        if !cookies.isEmpty {
            Self.logger.info("Loaded \(cookies.count) auth cookies from Keychain")
        }
        return cookies
    }

    /// Retrieves YouTube auth cookies from the Keychain.
    /// Returns the cookies if found, nil otherwise.
    static func loadCookies() -> [HTTPCookie]? {
        guard let archiveData = loadArchiveData() else { return nil }
        let cookies = Self.decodeCookies(from: archiveData)
        return cookies.isEmpty ? nil : cookies
    }

    /// Deletes cookies from the Keychain.
    static func deleteCookies() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess {
            self.logger.info("Deleted cookies from Keychain")
        } else if status != errSecItemNotFound {
            self.logger.error("Failed to delete cookies from Keychain: \(status)")
        }
    }
}

// MARK: - LegacyCookieMigration

/// Handles one-time migration from file-based cookie storage to Keychain.
/// This ensures existing users don't lose their login session.
enum LegacyCookieMigration {
    private static let logger = DiagnosticsLogger.webKit

    /// Returns the URL for the legacy cookie backup file.
    private static var legacyFileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("Kaset", isDirectory: true)
            .appendingPathComponent("cookies.dat")
    }

    /// Migrates cookies from the legacy file to Keychain if needed.
    /// Returns true if migration occurred, false if no migration was needed.
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        // If Keychain already has cookies, do not repeatedly migrate on every startup.
        guard !KeychainCookieStorage.hasCookieItem() else { return false }

        guard let fileURL = legacyFileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            // No legacy file exists, nothing to migrate
            return false
        }

        self.logger.info("Found legacy cookie file, migrating to Keychain...")

        // Read cookies from legacy file
        guard let data = try? Data(contentsOf: fileURL),
              let cookieDataArray = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSArray.self, NSData.self],
                  from: data
              ) as? [Data]
        else {
            self.logger.error("Failed to read legacy cookie file for migration")
            // Delete corrupted file
            Self.deleteLegacyFile()
            return false
        }

        let cookies = cookieDataArray.compactMap { cookieData -> HTTPCookie? in
            guard let stringProperties = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSDictionary.self, NSString.self, NSDate.self, NSNumber.self],
                from: cookieData
            ) as? [String: Any] else {
                return nil
            }

            var convertedProperties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in stringProperties {
                convertedProperties[HTTPCookiePropertyKey(key)] = value
            }
            return HTTPCookie(properties: convertedProperties)
        }

        let now = Date()
        let validCookies = cookies.filter { cookie in
            KeychainCookieStorage.isValidAuthCookie(cookie, now: now)
        }

        guard !validCookies.isEmpty else {
            self.logger.info("Legacy file contained no valid cookies")
            #if !DEBUG
                Self.deleteLegacyFile()
            #endif
            return false
        }

        // Save to Keychain
        KeychainCookieStorage.saveCookies(validCookies)

        // Verify migration succeeded by checking if cookies were actually saved
        // Note: loadCookies() returns nil if Keychain access fails (e.g., unsigned builds)
        guard let savedCookies = KeychainCookieStorage.loadCookies(), !savedCookies.isEmpty else {
            self.logger.error("Migration verification failed - keeping legacy file as backup")
            // Don't delete the file - Keychain may not be accessible
            return false
        }

        self.logger.info("✓ Successfully migrated \(validCookies.count) cookies to Keychain")
        #if !DEBUG
            Self.deleteLegacyFile()
        #endif
        return true
    }

    /// Deletes the legacy cookie file.
    private static func deleteLegacyFile() {
        guard let fileURL = legacyFileURL else { return }

        do {
            try FileManager.default.removeItem(at: fileURL)
            self.logger.info("Deleted legacy cookie file")
        } catch {
            self.logger.warning("Failed to delete legacy cookie file: \(error.localizedDescription)")
        }
    }
}

#if DEBUG

    // MARK: - DebugCookieFileExporter

    /// Debug-only cookie export to the legacy `cookies.dat` file used by `Tools/api-explorer.swift`.
    ///
    /// In release builds we store cookies only in Keychain and do not export to disk.
    enum DebugCookieFileExporter {
        private static let logger = DiagnosticsLogger.webKit

        private static var fileURL: URL? {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                return nil
            }

            let appFolder = appSupport.appendingPathComponent("Kaset", isDirectory: true)

            do {
                try FileManager.default.createDirectory(
                    at: appFolder,
                    withIntermediateDirectories: true
                )
            } catch {
                Self.logger.error("Failed to create Kaset folder: \(error.localizedDescription)")
                return nil
            }

            return appFolder.appendingPathComponent("cookies.dat")
        }

        static func exportAuthCookiesArchiveData(_ archiveData: Data) {
            guard let destinationURL = fileURL else { return }

            do {
                try archiveData.write(to: destinationURL, options: .atomic)
                // Restrict permissions: owner read/write only.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationURL.path
                )
            } catch {
                Self.logger.warning("Failed to export cookies.dat for debug tools: \(error.localizedDescription)")
            }
        }
    }
#endif

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

    /// Minimum interval between cookie backup operations (in seconds).
    private static let cookieDebounceInterval: Duration = .seconds(5)

    /// The YouTube Music origin URL.
    static let origin = "https://music.youtube.com"

    /// Required cookie name for authentication.
    static let authCookieName = "__Secure-3PAPISID"

    /// Fallback cookie name (non-secure version).
    static let fallbackAuthCookieName = "SAPISID"

    /// Custom user agent to appear as Safari to avoid "browser not supported" errors.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let logger = DiagnosticsLogger.webKit

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
        Task {
            await self.restoreAuthCookiesFromBackup()
        }

        self.logger.info("WebKitManager initialized with persistent data store")
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

    /// Creates a WebView configuration using the shared persistent data store.
    func createWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = self.dataStore
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Enable AirPlay for streaming to Apple TV, HomePod, etc.
        configuration.allowsAirPlayForMediaPlayback = true

        return configuration
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
            KeychainCookieStorage.saveArchiveData(archive.data, cookieCount: archive.cookieCount)
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
            KeychainCookieStorage.saveArchiveData(archive.data, cookieCount: archive.cookieCount)
            #if DEBUG
                DebugCookieFileExporter.exportAuthCookiesArchiveData(archive.data)
            #endif
        }
    }
}
