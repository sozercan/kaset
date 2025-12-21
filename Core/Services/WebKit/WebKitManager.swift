import Foundation
import os
import Security
import WebKit

// MARK: - CookieBackupManager

/// Manages backup storage of auth cookies in Keychain for resilience against WebKit data loss.
enum CookieBackupManager {
    private static let service = "com.sertacozercan.Kaset.cookies"
    private static let account = "youtube-auth-cookies"
    private static let logger = DiagnosticsLogger.webKit

    /// Saves YouTube auth cookies to Keychain as a backup.
    static func backupCookies(_ cookies: [HTTPCookie]) {
        // Filter to only YouTube auth cookies
        let authCookieNames = Set([
            "SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID",
            "SID", "HSID", "SSID", "APISID",
        ])
        let authCookies = cookies.filter { authCookieNames.contains($0.name) }

        guard !authCookies.isEmpty else { return }

        // Use NSKeyedArchiver since cookie properties contain Date objects
        // that can't be serialized with JSONSerialization
        let cookieData = authCookies.compactMap { cookie -> Data? in
            guard let properties = cookie.properties else { return nil }
            // Convert to [String: Any] for archiving
            var stringProperties: [String: Any] = [:]
            for (key, value) in properties {
                stringProperties[key.rawValue] = value
            }
            return try? NSKeyedArchiver.archivedData(
                withRootObject: stringProperties,
                requiringSecureCoding: false
            )
        }

        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: cookieData,
            requiringSecureCoding: false
        ) else {
            self.logger.error("Failed to serialize cookies for backup")
            return
        }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item using the data protection keychain (no password prompts)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            self.logger.info("Backed up \(authCookies.count) auth cookies to Keychain")
        } else {
            self.logger.error("Failed to backup cookies to Keychain: \(status)")
        }
    }

    /// Restores YouTube auth cookies from Keychain backup.
    /// Returns the cookies if found, nil otherwise.
    static func restoreCookies() -> [HTTPCookie]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            self.logger.info("No cookie backup found in Keychain (first run or cleared)")
            return nil
        }

        guard status == errSecSuccess,
              let data = result as? Data,
              let cookieDataArray = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSArray.self, NSData.self],
                  from: data
              ) as? [Data]
        else {
            self.logger.error("Failed to read cookie backup from Keychain: status=\(status)")
            return nil
        }

        let cookies = cookieDataArray.compactMap { cookieData -> HTTPCookie? in
            guard let stringProperties = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSDictionary.self, NSString.self, NSDate.self, NSNumber.self],
                from: cookieData
            ) as? [String: Any] else {
                return nil
            }

            // Convert string keys back to HTTPCookiePropertyKey
            var convertedProperties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in stringProperties {
                convertedProperties[HTTPCookiePropertyKey(key)] = value
            }
            return HTTPCookie(properties: convertedProperties)
        }

        if !cookies.isEmpty {
            self.logger.info("Restored \(cookies.count) auth cookies from Keychain backup")
        }
        return cookies.isEmpty ? nil : cookies
    }

    /// Clears the cookie backup from Keychain.
    static func clearBackup() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        self.logger.info("Cleared cookie backup from Keychain")
    }
}

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

        // Always restore auth cookies from Keychain on startup
        // Keychain is our source of truth since WebKit storage is unreliable
        // during development (sandbox container changes with code signing)
        Task {
            await self.restoreAuthCookiesFromKeychain()
        }

        self.logger.info("WebKitManager initialized with persistent data store")
    }

    /// Restores auth cookies from Keychain to WebKit.
    /// Keychain is the source of truth - always restore on startup.
    private func restoreAuthCookiesFromKeychain() async {
        // Wait a moment for WebKit to fully initialize
        try? await Task.sleep(for: .milliseconds(100))

        let existingCookies = await dataStore.httpCookieStore.allCookies()
        self.logger.info("WebKit has \(existingCookies.count) cookies on startup")

        // Always restore from Keychain if we have a backup
        guard let backupCookies = CookieBackupManager.restoreCookies() else {
            self.logger.info("No cookie backup in Keychain (first run or signed out)")
            return
        }

        self.logger.info("Restoring \(backupCookies.count) auth cookies from Keychain")

        // Set each cookie in WebKit
        for cookie in backupCookies {
            await self.dataStore.httpCookieStore.setCookie(cookie)
        }

        // Verify restore
        let cookies = await dataStore.httpCookieStore.allCookies()
        let hasAuth = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }

        if hasAuth {
            self.logger.info("✓ Auth cookies restored from Keychain (\(cookies.count) total cookies)")
        } else {
            self.logger.error("✗ Failed to restore auth cookies - backup may be corrupted")
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

        // Also clear the Keychain backup
        CookieBackupManager.clearBackup()

        self.logger.info("WebKit data cleared successfully")
    }

    /// Forces an immediate backup of all YouTube/Google cookies to Keychain.
    /// Call this after successful login to ensure cookies are persisted.
    func forceBackupCookies() async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        self.logger.info("Force backup: found \(cookies.count) total cookies")

        // Filter for YouTube/Google auth cookies
        let authCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.hasSuffix("youtube.com") ||
                domain.hasSuffix("google.com") ||
                domain == ".youtube.com" ||
                domain == ".google.com"
        }

        self.logger.info("Force backup: \(authCookies.count) YouTube/Google cookies to backup")
        if !authCookies.isEmpty {
            CookieBackupManager.backupCookies(authCookies)
        }
    }
}

// MARK: WKHTTPCookieStoreObserver

extension WebKitManager: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            self.cookiesDidChange = Date()
            self.logger.debug("Cookies changed at \(self.cookiesDidChange)")

            // Backup cookies to Keychain whenever they change
            let cookies = await cookieStore.allCookies()
            self.logger.debug("Cookie change detected - total cookies: \(cookies.count)")

            // Filter for YouTube/Google auth cookies
            let authCookies = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                // Match youtube.com, .youtube.com, google.com, .google.com
                return domain.hasSuffix("youtube.com") ||
                    domain.hasSuffix("google.com") ||
                    domain == ".youtube.com" ||
                    domain == ".google.com"
            }

            self.logger.debug("Found \(authCookies.count) YouTube/Google cookies")
            if !authCookies.isEmpty {
                CookieBackupManager.backupCookies(authCookies)
            }
        }
    }
}
