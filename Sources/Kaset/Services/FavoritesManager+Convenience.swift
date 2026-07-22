import CryptoKit
import Foundation

extension FavoritesManager {
    var isVisible: Bool {
        !self.items.isEmpty
    }

    var canMutate: Bool {
        self.activeScopeID != nil && self.canPersistActiveSnapshot
    }

    static var defaultStorageDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Kaset", isDirectory: true)
    }

    enum LegacyMigrationResult {
        case completed
        case deferred
        case requiresReadOnlyRetry

        var requiresReadOnlyRetry: Bool {
            self == .requiresReadOnlyRetry
        }
    }

    static let recoveryRetryDelays: [Duration] = [
        .milliseconds(100),
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
    ]

    func scheduleRecoveryRetry(
        key: String,
        attempt: Int,
        operation: @escaping @MainActor () -> Bool
    ) {
        self.cancelRecoveryRetry(key: key)
        let cappedAttempt = min(attempt, Self.recoveryRetryDelays.count - 1)
        let delay = Self.recoveryRetryDelays[cappedAttempt]
        self.recoveryRetryTasks[key] = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }

            self.recoveryRetryTasks[key] = nil
            if !operation() {
                self.scheduleRecoveryRetry(
                    key: key,
                    attempt: min(cappedAttempt + 1, Self.recoveryRetryDelays.count - 1),
                    operation: operation
                )
            }
        }
    }

    func cancelRecoveryRetry(key: String) {
        self.recoveryRetryTasks[key]?.cancel()
        self.recoveryRetryTasks[key] = nil
    }

    static func scopeRecoveryRetryKey(scopeID: String) -> String {
        "scope:\(scopeID)"
    }

    static func accountRecoveryRetryKey(accountID: String, scopeID: String) -> String {
        "account:\(accountID):\(scopeID)"
    }

    func reserveLegacySource(_ legacyURL: URL, for scopeID: String) -> Bool {
        let sourceName = legacyURL.lastPathComponent
        if let reservedScopeID = self.legacyRecoveryScopeBySourceName[sourceName] {
            return reservedScopeID == scopeID
        }
        self.legacyRecoveryScopeBySourceName[sourceName] = scopeID
        return true
    }

    func releaseLegacySourceIfBoundOrAbsent(_ legacyURL: URL, from scopeID: String) {
        let sourceName = legacyURL.lastPathComponent
        guard self.legacyRecoveryScopeBySourceName[sourceName] == scopeID,
              !FileManager.default.fileExists(atPath: legacyURL.path)
        else { return }
        self.legacyRecoveryScopeBySourceName.removeValue(forKey: sourceName)
    }

    func retargetPendingLegacyRecovery(
        from sourceScopeID: String,
        into targetScopeID: String,
        accountID: String
    ) {
        let sourceRetryKey = Self.scopeRecoveryRetryKey(scopeID: sourceScopeID)
        let accountRetryKey = Self.accountRecoveryRetryKey(accountID: accountID, scopeID: sourceScopeID)
        let reservedSourceNames = self.legacyRecoveryScopeBySourceName.compactMap { sourceName, scopeID in
            scopeID == sourceScopeID ? sourceName : nil
        }
        guard !reservedSourceNames.isEmpty
            || self.recoveryRetryTasks[sourceRetryKey] != nil
            || self.recoveryRetryTasks[accountRetryKey] != nil
        else { return }

        for sourceName in reservedSourceNames {
            self.legacyRecoveryScopeBySourceName[sourceName] = targetScopeID
        }
        self.cancelRecoveryRetry(key: sourceRetryKey)
        self.cancelRecoveryRetry(key: accountRetryKey)
        self.scheduleScopeRecoveryRetry(
            scopeID: targetScopeID,
            migratesLegacyFavorites: true,
            legacyAccountID: accountID,
            attempt: 0
        )
    }

    func legacyAccountFavoritesURL(accountID: String) -> URL? {
        guard accountID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return self.storageDirectory.appendingPathComponent("favorites-\(accountID).json")
    }

    func legacyClaimURL(for legacyURL: URL, boundTo targetScopeID: String) -> URL {
        let sourceID = Self.hashID(for: Data(legacyURL.lastPathComponent.utf8))
        return self.storageDirectory.appendingPathComponent(
            ".favorites-legacy-claim-\(targetScopeID)-\(sourceID).json"
        )
    }

    func legacyClaimURLs(boundTo scopeID: String, legacyAccountID: String) -> [URL] {
        var legacyURLs = [self.storageDirectory.appendingPathComponent("favorites.json")]
        if let legacyAccountURL = self.legacyAccountFavoritesURL(accountID: legacyAccountID) {
            legacyURLs.append(legacyAccountURL)
        }
        return legacyURLs.map { self.legacyClaimURL(for: $0, boundTo: scopeID) }
    }

    /// Builds an opaque identifier for a provider identity or local alias.
    static func identityID(for identity: String) -> String {
        let data = Data(identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
        return Self.hashID(for: data)
    }

    /// Builds an opaque identifier without altering case-sensitive identity material.
    static func opaqueIdentityID(for identity: String) -> String {
        self.hashID(for: Data(identity.utf8))
    }

    /// Builds an opaque persistence scope from a canonical owner ID and selected YouTube account.
    static func accountScopeID(ownerID: String, accountID: String) -> String {
        var data = Data(ownerID.utf8)
        data.append(0)
        data.append(Data(accountID.utf8))
        return Self.hashID(for: data)
    }

    func toggle(_ item: FavoriteItem) {
        if self.isPinned(contentId: item.contentId) {
            self.remove(contentId: item.contentId)
        } else {
            self.add(item)
        }
    }

    func isPinned(song: Song) -> Bool {
        self.isPinned(contentId: song.videoId)
    }

    func isPinned(album: Album) -> Bool {
        self.isPinned(contentId: album.id)
    }

    func isPinned(playlist: Playlist) -> Bool {
        self.isPinned(contentId: playlist.id)
    }

    func isPinned(artist: Artist) -> Bool {
        self.isPinned(contentId: artist.id)
    }

    func isPinned(podcastShow: PodcastShow) -> Bool {
        self.isPinned(contentId: podcastShow.id)
    }

    func toggle(song: Song) {
        self.toggle(.from(song))
    }

    func toggle(album: Album) {
        self.toggle(.from(album))
    }

    func toggle(playlist: Playlist) {
        self.toggle(.from(playlist))
    }

    func toggle(artist: Artist) {
        self.toggle(.from(artist))
    }

    func toggle(podcastShow: PodcastShow) {
        self.toggle(.from(podcastShow))
    }

    static func merging(_ preferredItems: [FavoriteItem], appending additionalItems: [FavoriteItem]) -> [FavoriteItem] {
        var seenContentIDs = Set(preferredItems.map(\.contentId))
        return preferredItems + additionalItems.filter { seenContentIDs.insert($0.contentId).inserted }
    }

    static func targetOwnedItems(
        baselineItems: [FavoriteItem],
        currentTargetItems: [FavoriteItem],
        previousPreparedItems: [FavoriteItem]?
    ) -> [FavoriteItem] {
        guard let previousPreparedItems else { return currentTargetItems }
        let baselineItemIDs = Set(baselineItems.map(\.id))
        let previousPreparedItemIDs = Set(previousPreparedItems.map(\.id))
        return currentTargetItems.filter { item in
            baselineItemIDs.contains(item.id)
                || !previousPreparedItemIDs.contains(item.id)
        }
    }

    @discardableResult
    static func write(_ items: [FavoriteItem], to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
            return true
        } catch {
            DiagnosticsLogger.ui.error("Failed to save favorites: \(error.localizedDescription)")
            return false
        }
    }

    static func hashID(for data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
