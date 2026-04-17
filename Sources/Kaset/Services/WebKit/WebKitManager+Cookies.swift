import Foundation
import os
import Security
import WebKit

// MARK: - CookieArchiveWriteCoordinator

/// Tracks the last persisted archive so identical cookie backups can be skipped safely.
final class CookieArchiveWriteCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSavedArchiveData: Data?
    private var pendingArchiveData: Data?

    @discardableResult
    func beginSaveIfNeeded(_ data: Data) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard self.pendingArchiveData != data, self.lastSavedArchiveData != data else {
            return false
        }

        self.pendingArchiveData = data
        return true
    }

    func finishSave(_ data: Data, success: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }

        if self.pendingArchiveData == data {
            self.pendingArchiveData = nil
        }

        if success {
            self.lastSavedArchiveData = data
        }
    }

    func seedPersistedArchive(_ data: Data?) {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.lastSavedArchiveData = data

        if data == nil || self.pendingArchiveData == data {
            self.pendingArchiveData = nil
        }
    }
}

// MARK: - KeychainCookieStorage

/// Securely stores auth cookies in the macOS Keychain.
/// Provides encryption at rest and app-specific access control.
enum KeychainCookieStorage {
    private static let logger = DiagnosticsLogger.webKit
    private static let writeCoordinator = CookieArchiveWriteCoordinator()

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
            // Note: Cookie properties dictionary contains types like String, Date, Number, Bool
            // which all support NSSecureCoding. However, using requiringSecureCoding: false here
            // because [String: Any] doesn't directly conform to NSSecureCoding.
            // The unarchive side uses explicit class allowlists for security.
            return try? NSKeyedArchiver.archivedData(
                withRootObject: stringProperties,
                requiringSecureCoding: false
            )
        }

        guard !cookieData.isEmpty,
              let data = try? NSKeyedArchiver.archivedData(
                  withRootObject: cookieData as NSArray,
                  requiringSecureCoding: true
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

        _ = Self.saveArchiveData(archive.data, cookieCount: archive.cookieCount)
    }

    /// Saves an already-serialized cookie archive to the Keychain.
    @discardableResult
    static func saveArchiveData(_ data: Data, cookieCount: Int) -> Bool {
        guard self.writeCoordinator.beginSaveIfNeeded(data) else {
            self.logger.debug("Skipping Keychain cookie save because archive is already saved or a write is in progress")
            return false
        }

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

        let didSave = status == errSecSuccess
        self.writeCoordinator.finishSave(data, success: didSave)

        if didSave {
            Self.logger.debug("Saved \(cookieCount) auth cookies to Keychain")
            return true
        } else {
            Self.logger.error("Failed to save cookies to Keychain: \(status)")
            return false
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
            Self.writeCoordinator.seedPersistedArchive(nil)
            if status == errSecItemNotFound {
                Self.logger.info("No cookies found in Keychain (first run or signed out)")
            } else {
                Self.logger.error("Failed to load cookies from Keychain: \(status)")
            }
            return nil
        }

        guard let data = result as? Data else {
            Self.writeCoordinator.seedPersistedArchive(nil)
            Self.logger.error("Loaded Keychain cookie item had an unexpected type")
            return nil
        }

        Self.writeCoordinator.seedPersistedArchive(data)
        return data
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
        Self.writeCoordinator.seedPersistedArchive(nil)

        if status == errSecSuccess {
            Self.logger.info("Deleted cookies from Keychain")
        } else if status != errSecItemNotFound {
            Self.logger.error("Failed to delete cookies from Keychain: \(status)")
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
