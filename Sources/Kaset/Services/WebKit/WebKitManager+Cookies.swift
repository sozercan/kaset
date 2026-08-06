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

// MARK: - CookieArchiveSaveResult

enum CookieArchiveSaveResult {
    case saved
    case alreadyCurrent
    case superseded
    case failed

    var isPersisted: Bool {
        self == .saved || self == .alreadyCurrent
    }
}

// MARK: - CookieArchiveLoadResult

enum CookieArchiveLoadResult: Sendable {
    case data(Data)
    case notFound
    case failure
}

// MARK: - CookieRestorePolicyLoadResult

enum CookieRestorePolicyLoadResult: Equatable, Sendable {
    case allowed
    case denied
    case notFound
    case failure
}

// MARK: - CookieArchiveEncodingResult

enum CookieArchiveEncodingResult: Equatable, Sendable {
    case archive(data: Data, cookieCount: Int)
    case noPrimarySession
    case failure
}

// MARK: - KeychainCookieStorage

/// Stores auth cookie backups in the configured backing store.
///
/// Release builds use the macOS Keychain for encryption at rest and app-specific
/// access control. DEBUG builds default to a sandboxed file to avoid local
/// ad-hoc signing hangs inside Security.framework; set
/// `KASET_DEBUG_COOKIE_STORAGE=keychain` to exercise the Keychain path locally.
enum KeychainCookieStorage {
    private static let logger = DiagnosticsLogger.webKit
    private static let writeCoordinator = CookieArchiveWriteCoordinator()

    /// Keychain service identifier for cookie storage.
    fileprivate static let service = "com.kaset.auth-cookies"

    /// Keychain account identifier.
    private static let account = "youtube-music-cookies"

    #if DEBUG
        private static let debugCookieStorageEnvironmentKey = "KASET_DEBUG_COOKIE_STORAGE"

        fileprivate static var usesDebugFileStorage: Bool {
            ProcessInfo.processInfo.environment[debugCookieStorageEnvironmentKey]?.lowercased() != "keychain"
        }
    #endif

    /// Explicit YouTube/Google session-cookie allowlist used for native API auth.
    static let authCookieNames = Set([
        "SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID",
        "SID", "HSID", "SSID", "APISID",
        "LOGIN_INFO", "SIDCC",
        "__Secure-1PSID", "__Secure-3PSID",
        "__Secure-1PSIDCC", "__Secure-3PSIDCC",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS",
    ])

    static let loginSessionCookieNames = authCookieNames.union([
        "LSID", "ACCOUNT_CHOOSER", "GAPS", "__Host-GAPS",
        "__Host-1PLSID", "__Host-3PLSID",
        "__Secure-1PLSID", "__Secure-3PLSID",
        "SMSV",
    ])

    static func isAllowedAuthCookieDomain(_ domain: String) -> Bool {
        let normalized = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .drop(while: { $0 == "." })
        guard !normalized.isEmpty else { return false }

        return ["youtube.com", "google.com"].contains { rootDomain in
            normalized == rootDomain || normalized.hasSuffix(".\(rootDomain)")
        }
    }

    static func isAuthCookie(_ cookie: HTTPCookie) -> Bool {
        self.authCookieNames.contains(cookie.name)
            && self.isAllowedAuthCookieDomain(cookie.domain)
    }

    /// Broader in-memory login-transaction boundary. These cookies are never
    /// written to the native API archive; they are captured only so a cancelled
    /// login can restore the complete Google/YouTube WebKit cookie jar.
    static func isLoginDomainCookie(_ cookie: HTTPCookie) -> Bool {
        self.isAllowedAuthCookieDomain(cookie.domain)
    }

    static func isLoginSessionCookie(_ cookie: HTTPCookie) -> Bool {
        self.loginSessionCookieNames.contains(cookie.name)
            && self.isAllowedAuthCookieDomain(cookie.domain)
    }

    static func isValidAuthCookie(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        guard self.isAuthCookie(cookie) else { return false }
        if let expiresDate = cookie.expiresDate, expiresDate < now {
            return false
        }
        return true
    }

    /// Creates the serialized archive persisted by the active cookie backup store.
    static func makeArchiveResult(from cookies: [HTTPCookie]) -> CookieArchiveEncodingResult {
        self.makeArchiveResult(
            from: cookies,
            serializeCookie: { properties in
                try? NSKeyedArchiver.archivedData(
                    withRootObject: properties,
                    requiringSecureCoding: false
                )
            },
            serializeArchive: { cookieData in
                try? NSKeyedArchiver.archivedData(
                    withRootObject: cookieData as NSArray,
                    requiringSecureCoding: true
                )
            }
        )
    }

    static func makeArchiveResult(
        from cookies: [HTTPCookie],
        serializeCookie: ([String: Any]) -> Data?,
        serializeArchive: ([Data]) -> Data?
    ) -> CookieArchiveEncodingResult {
        let now = Date()
        let authCookies = cookies
            .filter { cookie in
                Self.isValidAuthCookie(cookie, now: now)
            }
            .sorted { lhs, rhs in
                let lhsKey = [lhs.domain.lowercased(), lhs.path, lhs.name]
                let rhsKey = [rhs.domain.lowercased(), rhs.path, rhs.name]
                return lhsKey.lexicographicallyPrecedes(rhsKey)
            }

        let youtubeCookies = WebKitManager.cookies(authCookies, matching: "youtube.com")
        let hasPrimarySession = youtubeCookies.contains { cookie in
            cookie.name == WebKitManager.authCookieName
                || cookie.name == WebKitManager.fallbackAuthCookieName
        }
        guard hasPrimarySession else { return .noPrimarySession }

        var cookieData: [Data] = []
        cookieData.reserveCapacity(authCookies.count)
        for cookie in authCookies {
            guard let properties = cookie.properties else {
                Self.logger.error("Cookie properties were unavailable during backup serialization")
                return .failure
            }
            var stringProperties: [String: Any] = [:]
            for (key, value) in properties {
                stringProperties[key.rawValue] = value
            }
            // Cookie properties contain Foundation value types. Secure coding is
            // enforced by the explicit class allowlist on the unarchive side.
            guard let data = serializeCookie(stringProperties) else {
                Self.logger.error("Failed to serialize a cookie for backup storage")
                return .failure
            }
            cookieData.append(data)
        }

        guard let data = serializeArchive(cookieData) else {
            Self.logger.error("Failed to serialize cookies for backup storage")
            return .failure
        }

        return .archive(data: data, cookieCount: cookieData.count)
    }

    /// Compatibility wrapper for callers that treat an absent session and an
    /// encoding failure identically without deleting the last persisted archive.
    static func makeArchiveData(from cookies: [HTTPCookie]) -> (data: Data, cookieCount: Int)? {
        guard case let .archive(data, cookieCount) = self.makeArchiveResult(from: cookies) else {
            return nil
        }
        return (data: data, cookieCount: cookieCount)
    }

    /// Saves YouTube auth cookies to the active cookie backup store.
    static func saveCookies(_ cookies: [HTTPCookie]) {
        guard let archive = makeArchiveData(from: cookies) else { return }

        _ = Self.saveArchiveData(archive.data, cookieCount: archive.cookieCount)
    }

    fileprivate static var debugCookieFileURL: URL? {
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

    /// Saves an already-serialized cookie archive to the active cookie backup store.
    @discardableResult
    static func saveArchiveData(_ data: Data, cookieCount: Int) -> Bool {
        guard self.writeCoordinator.beginSaveIfNeeded(data) else {
            self.logger.debug("Skipping cookie save because archive is already saved or a write is in progress")
            return false
        }

        #if DEBUG
            if self.usesDebugFileStorage {
                return self.saveArchiveDataToDebugFile(data, cookieCount: cookieCount)
            }
        #endif

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

    #if DEBUG
        private static func saveArchiveDataToDebugFile(_ data: Data, cookieCount: Int) -> Bool {
            guard let fileURL = debugCookieFileURL else {
                self.logger.error("Debug cookie file storage is unavailable")
                self.writeCoordinator.finishSave(data, success: false)
                return false
            }

            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
                self.writeCoordinator.finishSave(data, success: true)
                Self.logger.info("Saved \(cookieCount) auth cookies to debug file storage")
                return true
            } catch {
                self.writeCoordinator.finishSave(data, success: false)
                Self.logger.error("Failed to save debug cookies file: \(error.localizedDescription)")
                return false
            }
        }
    #endif

    /// Returns `true` if a cookie backup exists in the active backing store.
    static func hasCookieItem() -> Bool {
        #if DEBUG
            if self.usesDebugFileStorage {
                guard let fileURL = self.debugCookieFileURL else { return false }
                return FileManager.default.fileExists(atPath: fileURL.path)
            }
        #endif

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

    /// Loads the raw serialized cookie archive data from the active backing store.
    static func loadArchiveData() -> Data? {
        guard case let .data(data) = self.loadArchiveResult() else { return nil }
        return data
    }

    static func loadArchiveResult() -> CookieArchiveLoadResult {
        #if DEBUG
            if self.usesDebugFileStorage {
                return self.loadArchiveResultFromDebugFile()
            }
        #endif

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
                Self.writeCoordinator.seedPersistedArchive(nil)
                Self.logger.info("No cookies found in Keychain (first run or signed out)")
                return .notFound
            } else {
                Self.logger.error("Failed to load cookies from Keychain: \(status)")
                return .failure
            }
        }

        guard let data = result as? Data else {
            Self.logger.error("Loaded Keychain cookie item had an unexpected type")
            return .failure
        }

        Self.writeCoordinator.seedPersistedArchive(data)
        return .data(data)
    }

    #if DEBUG
        private static func loadArchiveResultFromDebugFile() -> CookieArchiveLoadResult {
            guard let fileURL = self.debugCookieFileURL else {
                self.logger.error("Debug cookie file storage is unavailable")
                return .failure
            }

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                Self.logger.info("No debug cookies file found")
                self.writeCoordinator.seedPersistedArchive(nil)
                return .notFound
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                Self.logger.error("Failed to load debug cookies file")
                return .failure
            }

            self.writeCoordinator.seedPersistedArchive(data)
            Self.logger.info("Loaded cookies from debug file storage")
            return .data(data)
        }
    #endif

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
            Self.logger.info("Loaded \(cookies.count) auth cookies from cookie backup storage")
        }
        return cookies
    }

    static func isRestorableArchiveData(_ archiveData: Data) -> Bool {
        let cookies = self.decodeCookies(from: archiveData)
        guard case .snapshot = CookieArchiveVerificationState.make(from: cookies) else {
            return false
        }
        return true
    }

    /// Retrieves YouTube auth cookies from the active cookie backup store.
    /// Returns the cookies if found, nil otherwise.
    static func loadCookies() -> [HTTPCookie]? {
        guard let archiveData = loadArchiveData() else { return nil }
        let cookies = Self.decodeCookies(from: archiveData)
        return cookies.isEmpty ? nil : cookies
    }

    /// Deletes cookies from the active cookie backup store.
    /// Returns true when no persisted archive remains in the active store.
    @discardableResult
    static func deleteCookies() -> Bool {
        #if DEBUG
            if self.usesDebugFileStorage {
                return self.deleteDebugCookieFile()
            }

            // When explicitly testing the Keychain path in DEBUG, also clear
            // the default debug file so switching backends cannot resurrect a
            // session the developer just signed out from.
            let didDeleteDebugFile = self.deleteDebugCookieFile()
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        let didDeleteKeychainItem = status == errSecSuccess || status == errSecItemNotFound
        if didDeleteKeychainItem {
            Self.writeCoordinator.seedPersistedArchive(nil)
        }

        if status == errSecSuccess {
            Self.logger.info("Deleted cookies from Keychain")
        } else if status != errSecItemNotFound {
            Self.logger.error("Failed to delete cookies from Keychain: \(status)")
        }

        #if DEBUG
            return didDeleteKeychainItem && didDeleteDebugFile
        #else
            return didDeleteKeychainItem
        #endif
    }

    #if DEBUG
        @discardableResult
        private static func deleteDebugCookieFile() -> Bool {
            guard let fileURL = self.debugCookieFileURL else {
                self.logger.error("Debug cookie file storage is unavailable")
                return false
            }

            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                    Self.logger.info("Deleted cookies from debug file storage")
                }
                self.writeCoordinator.seedPersistedArchive(nil)
                return true
            } catch {
                Self.logger.warning("Failed to delete debug cookies file: \(error.localizedDescription)")
                return false
            }
        }
    #endif
}

// MARK: - CookieRestorePolicyStorage

enum CookieRestorePolicyStorage {
    private static let logger = DiagnosticsLogger.webKit
    private static let keychainAccount = "youtube-music-cookies-restore-policy"

    static func loadResult() -> CookieRestorePolicyLoadResult {
        #if DEBUG
            if KeychainCookieStorage.usesDebugFileStorage {
                guard let url = self.debugFileURL else { return .failure }
                guard FileManager.default.fileExists(atPath: url.path) else { return .notFound }
                do {
                    return try self.decode(Data(contentsOf: url))
                } catch {
                    self.logger.error("Failed to read cookie restore policy: \(error.localizedDescription)")
                    return .failure
                }
            }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainCookieStorage.service,
            kSecAttrAccount as String: self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return .notFound
            }
            self.logger.error("Failed to read cookie restore policy from Keychain: \(status)")
            return .failure
        }
        guard let data = result as? Data else { return .failure }
        return self.decode(data)
    }

    static func decode(_ data: Data) -> CookieRestorePolicyLoadResult {
        guard data.count == 1, let byte = data.first else { return .failure }
        return switch byte {
        case 0:
            .denied
        case 1:
            .allowed
        default:
            .failure
        }
    }

    @discardableResult
    static func save(_ allowed: Bool) -> Bool {
        let data = Data([allowed ? 1 : 0])
        #if DEBUG
            if KeychainCookieStorage.usesDebugFileStorage {
                guard let url = self.debugFileURL else { return false }
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: url.path
                    )
                    return true
                } catch {
                    self.logger.error("Failed to persist cookie restore policy: \(error.localizedDescription)")
                    return false
                }
            }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainCookieStorage.service,
            kSecAttrAccount as String: self.keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            for (key, value) in attributes {
                insertion[key] = value
            }
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    #if DEBUG
        private static var debugFileURL: URL? {
            KeychainCookieStorage.debugCookieFileURL?
                .appendingPathExtension("restore-policy")
        }
    #endif
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
            _ = Self.deleteLegacyFileIfPresent()
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
                _ = Self.deleteLegacyFileIfPresent()
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
            _ = Self.deleteLegacyFileIfPresent()
        #endif
        return true
    }

    /// Deletes the legacy cookie file when present.
    @discardableResult
    static func deleteLegacyFileIfPresent() -> Bool {
        guard let fileURL = legacyFileURL else { return false }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }

        do {
            try FileManager.default.removeItem(at: fileURL)
            self.logger.info("Deleted legacy cookie file")
            return !FileManager.default.fileExists(atPath: fileURL.path)
        } catch {
            self.logger.warning("Failed to delete legacy cookie file: \(error.localizedDescription)")
            return false
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

        @discardableResult
        static func deleteExport() -> Bool {
            guard let destinationURL = fileURL else { return false }
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                return true
            } catch {
                Self.logger.warning("Failed to delete cookies.dat debug export: \(error.localizedDescription)")
                return false
            }
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
