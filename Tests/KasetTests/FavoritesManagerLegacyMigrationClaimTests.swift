import Foundation
import Testing
@testable import Kaset

/// Crash-recovery coverage for destination-bound legacy Favorites claims.
@Suite(.serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct FavoritesManagerTestsLegacyMigrationClaims {
    @Test("Owner-state backup round-trips beside favorites data")
    func ownerStateBackupRoundTrips() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupData = Data("opaque-owner-state".utf8)

        let writer = FavoritesManager(storageDirectory: directory)
        #expect(writer.saveOwnerStateBackup(backupData))

        let reader = FavoritesManager(storageDirectory: directory)
        #expect(reader.loadOwnerStateBackup() == backupData)
    }

    @Test("Resolved owner claims legacy files for every listed account")
    func resolvedOwnerClaimsEveryLegacyAccountFile() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primaryScopeID = FavoritesManager.accountScopeID(
            ownerID: "owner",
            accountID: "primary"
        )
        let brandAccountID = "brand-account"
        let brandScopeID = FavoritesManager.accountScopeID(
            ownerID: "owner",
            accountID: brandAccountID
        )
        let unrelatedPrimaryScopeID = FavoritesManager.accountScopeID(
            ownerID: "unrelated-owner",
            accountID: "primary"
        )
        let primaryItem = FavoriteItem.from(TestFixtures.makeSong(id: "legacy-all-primary"))
        let brandItem = FavoriteItem.from(TestFixtures.makeSong(id: "legacy-all-brand"))
        try JSONEncoder().encode([primaryItem])
            .write(to: directory.appendingPathComponent("favorites-primary.json"))
        try JSONEncoder().encode([brandItem])
            .write(to: directory.appendingPathComponent("favorites-\(brandAccountID).json"))

        let manager = FavoritesManager(storageDirectory: directory)
        manager.recoverLegacyAccountFavorites(accountID: "primary", toScopeID: primaryScopeID)
        manager.recoverLegacyAccountFavorites(accountID: brandAccountID, toScopeID: brandScopeID)

        manager.setActiveAccountScopeID(brandScopeID)
        #expect(manager.isPinned(contentId: brandItem.contentId))
        manager.setActiveAccountScopeID(primaryScopeID)
        #expect(manager.isPinned(contentId: primaryItem.contentId))
        manager.setActiveAccountScopeID(unrelatedPrimaryScopeID)
        #expect(!manager.isPinned(contentId: primaryItem.contentId))
    }

    @Test("Empty accounts do not block owner migration finalization")
    func emptyAccountFinalizationCompletes() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceOwnerID = "source-owner"
        let targetOwnerID = "target-owner"
        let populatedAccountID = "primary"
        let emptyAccountID = "empty-brand"
        let sourceScopeID = FavoritesManager.accountScopeID(
            ownerID: sourceOwnerID,
            accountID: populatedAccountID
        )
        let targetScopeID = FavoritesManager.accountScopeID(
            ownerID: targetOwnerID,
            accountID: populatedAccountID
        )
        let sourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "empty-finalization-source"))
        let manager = FavoritesManager(storageDirectory: directory)
        manager.setActiveAccountScopeID(sourceScopeID)
        manager.add(sourceItem)
        manager.setActiveAccountScopeID(nil)

        let accountIDs = [populatedAccountID, emptyAccountID]
        #expect(manager.prepareAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: accountIDs
        ))
        #expect(manager.commitAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: accountIDs
        ))
        #expect(manager.finalizeAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: accountIDs
        ))

        manager.setActiveAccountScopeID(targetScopeID)
        #expect(manager.isPinned(contentId: sourceItem.contentId))
    }

    @Test("Guest mode restores account-scoped legacy claim recovery")
    func guestModeRestoresLegacyAccountID() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: "primary")
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        let legacyURL = directory.appendingPathComponent("favorites-primary.json")
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "guest-retry-primary"))
        try Data("not-json".utf8).write(to: scopedURL)
        try JSONEncoder().encode([legacyItem]).write(to: legacyURL)

        let diskManager = FavoritesManager(storageDirectory: directory)
        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")
        let claimURL = try #require(self.legacyClaimURLs(in: directory).first)
        diskManager.enterGuestMode()

        try FileManager.default.removeItem(at: scopedURL)
        diskManager.exitGuestMode()

        #expect(diskManager.isPinned(contentId: legacyItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: claimURL.path))
    }

    @Test("A post-commit global legacy claim cannot replay into another scope")
    func globalLegacyClaimIsDestinationBound() throws {
        try self.assertLegacyClaimIsDestinationBound(
            legacyFileName: "favorites.json",
            legacyAccountID: nil
        )
    }

    @Test("A post-commit account legacy claim cannot replay into another scope")
    func accountLegacyClaimIsDestinationBound() throws {
        try self.assertLegacyClaimIsDestinationBound(
            legacyFileName: "favorites-primary.json",
            legacyAccountID: "primary"
        )
    }

    @Test("Finalization preserves recovery copies while target is invalid")
    func finalizationRejectsInvalidTarget() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceOwnerID = "source-owner"
        let targetOwnerID = "target-owner"
        let accountID = "primary"
        let sourceScopeID = FavoritesManager.accountScopeID(
            ownerID: sourceOwnerID,
            accountID: accountID
        )
        let targetScopeID = FavoritesManager.accountScopeID(
            ownerID: targetOwnerID,
            accountID: accountID
        )
        let sourceURL = directory.appendingPathComponent("favorites-\(sourceScopeID).json")
        let targetURL = directory.appendingPathComponent("favorites-\(targetScopeID).json")
        let sourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "invalid-target-source"))
        let targetItem = FavoriteItem.from(TestFixtures.makeSong(id: "invalid-target-existing"))
        let manager = FavoritesManager(storageDirectory: directory)

        manager.setActiveAccountScopeID(sourceScopeID)
        manager.reset(with: [sourceItem])
        manager.setActiveAccountScopeID(targetScopeID)
        manager.reset(with: [targetItem])
        #expect(manager.prepareAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(manager.commitAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        manager.setActiveAccountScopeID(nil)
        try Data("not-json".utf8).write(to: targetURL, options: .atomic)

        #expect(!manager.finalizeAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        try JSONEncoder().encode([targetItem, sourceItem]).write(to: targetURL, options: .atomic)
        #expect(manager.finalizeAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test("Finalization flushes active target edits before reload")
    func finalizationFlushesActiveTargetEdits() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceOwnerID = "source-owner"
        let targetOwnerID = "target-owner"
        let accountID = "primary"
        let targetScopeID = FavoritesManager.accountScopeID(
            ownerID: targetOwnerID,
            accountID: accountID
        )
        let sourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "flush-source"))
        let targetItem = FavoriteItem.from(TestFixtures.makeSong(id: "flush-target"))
        let recentItem = FavoriteItem.from(TestFixtures.makeSong(id: "flush-recent"))
        let manager = FavoritesManager(storageDirectory: directory)

        manager.setActiveAccountScopeID(
            FavoritesManager.accountScopeID(ownerID: sourceOwnerID, accountID: accountID)
        )
        manager.reset(with: [sourceItem])
        manager.setActiveAccountScopeID(targetScopeID)
        manager.reset(with: [targetItem])

        #expect(manager.prepareAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(manager.commitAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))

        // Simulate a later retry after a prior finalization attempt reloaded the
        // committed target but left cleanup pending. The new edit is still only
        // debounced in memory when finalization resumes.
        let retryManager = FavoritesManager(storageDirectory: directory)
        retryManager.setActiveAccountScopeID(targetScopeID)
        retryManager.add(recentItem)

        #expect(retryManager.finalizeAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(retryManager.isPinned(contentId: sourceItem.contentId))
        #expect(retryManager.isPinned(contentId: targetItem.contentId))
        #expect(retryManager.isPinned(contentId: recentItem.contentId))

        let reloaded = FavoritesManager(storageDirectory: directory)
        reloaded.setActiveAccountScopeID(targetScopeID)
        #expect(reloaded.isPinned(contentId: recentItem.contentId))
    }

    @Test("Owner migration preserves and finalizes source-bound legacy claims")
    func ownerMigrationIncludesLegacyClaims() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let provisionalOwnerID = "provisional-owner"
        let resolvedOwnerID = "resolved-owner"
        let accountID = "primary"
        let sourceScopeID = FavoritesManager.accountScopeID(
            ownerID: provisionalOwnerID,
            accountID: accountID
        )
        let targetScopeID = FavoritesManager.accountScopeID(
            ownerID: resolvedOwnerID,
            accountID: accountID
        )
        let sourceURL = directory.appendingPathComponent("favorites-\(sourceScopeID).json")
        let targetURL = directory.appendingPathComponent("favorites-\(targetScopeID).json")
        let globalLegacyURL = directory.appendingPathComponent("favorites.json")
        let accountLegacyURL = directory.appendingPathComponent("favorites-primary.json")
        let globalLegacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "claimed-global"))
        let accountLegacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "claimed-primary"))
        let targetItem = FavoriteItem.from(TestFixtures.makeSong(id: "resolved-target"))

        try Data("not-json".utf8).write(to: sourceURL)
        try JSONEncoder().encode([globalLegacyItem]).write(to: globalLegacyURL)
        try JSONEncoder().encode([accountLegacyItem]).write(to: accountLegacyURL)

        do {
            let claimingManager = FavoritesManager(storageDirectory: directory)
            claimingManager.setActiveAccountScopeID(sourceScopeID, legacyAccountID: accountID)
            #expect(!FileManager.default.fileExists(atPath: globalLegacyURL.path))
            #expect(!FileManager.default.fileExists(atPath: accountLegacyURL.path))
            #expect(try self.legacyClaimURLs(in: directory).count == 2)
        }

        try FileManager.default.removeItem(at: sourceURL)
        try JSONEncoder().encode([targetItem]).write(to: targetURL)

        let migratingManager = FavoritesManager(storageDirectory: directory)
        migratingManager.setActiveAccountScopeID(targetScopeID, legacyAccountID: accountID)
        #expect(migratingManager.isPinned(contentId: targetItem.contentId))
        #expect(migratingManager.prepareAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        let claimsAfterPrepare = try self.legacyClaimURLs(in: directory)
        #expect(claimsAfterPrepare.count == 2)

        #expect(migratingManager.commitAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        let committedItems = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: targetURL))
        #expect(Set(committedItems.map(\.contentId)) == Set([
            globalLegacyItem.contentId,
            accountLegacyItem.contentId,
            targetItem.contentId,
        ]))
        #expect(claimsAfterPrepare.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        migratingManager.finalizeAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        )

        #expect(try self.legacyClaimURLs(in: directory).isEmpty)
        migratingManager.setActiveAccountScopeID(targetScopeID, legacyAccountID: accountID)
        #expect(migratingManager.isPinned(contentId: globalLegacyItem.contentId))
        #expect(migratingManager.isPinned(contentId: accountLegacyItem.contentId))
        #expect(migratingManager.isPinned(contentId: targetItem.contentId))
    }

    @Test("Same-scope activation retries legacy migration")
    func sameScopeActivationRetriesLegacyMigration() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: "primary")
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        try Data("not-json".utf8).write(to: scopedURL)
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "same-scope-legacy"))
        let legacyURL = directory.appendingPathComponent("favorites.json")
        try JSONEncoder().encode([legacyItem]).write(to: legacyURL)

        let diskManager = FavoritesManager(storageDirectory: directory)
        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")
        #expect(!diskManager.isPinned(contentId: legacyItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        let claimURL = try #require(self.legacyClaimURLs(in: directory).first)

        try FileManager.default.removeItem(at: scopedURL)
        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")

        #expect(diskManager.isPinned(contentId: legacyItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: claimURL.path))
    }

    private func assertLegacyClaimIsDestinationBound(
        legacyFileName: String,
        legacyAccountID: String?
    ) throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let claimedScopeID = FavoritesManager.accountScopeID(
            ownerID: "claiming-owner",
            accountID: "primary"
        )
        let unrelatedScopeID = FavoritesManager.accountScopeID(
            ownerID: "unrelated-owner",
            accountID: "primary"
        )
        let claimedTargetURL = directory.appendingPathComponent("favorites-\(claimedScopeID).json")
        let legacyURL = directory.appendingPathComponent(legacyFileName)
        let existingItem = FavoriteItem.from(TestFixtures.makeSong(id: "claim-existing-\(legacyFileName)"))
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "claim-legacy-\(legacyFileName)"))

        try Data("not-json".utf8).write(to: claimedTargetURL)
        try JSONEncoder().encode([legacyItem]).write(to: legacyURL)

        do {
            let claimingManager = FavoritesManager(storageDirectory: directory)
            claimingManager.setActiveAccountScopeID(claimedScopeID, legacyAccountID: legacyAccountID)
            #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        }

        let claimURL = try #require(self.legacyClaimURLs(in: directory).first)

        // Simulate the process terminating after the atomic target write but before claim cleanup.
        try JSONEncoder().encode([existingItem, legacyItem]).write(to: claimedTargetURL, options: .atomic)

        let unrelatedManager = FavoritesManager(storageDirectory: directory)
        unrelatedManager.setActiveAccountScopeID(unrelatedScopeID, legacyAccountID: legacyAccountID)
        #expect(!unrelatedManager.isPinned(contentId: legacyItem.contentId))
        #expect(FileManager.default.fileExists(atPath: claimURL.path))

        let recoveryManager = FavoritesManager(storageDirectory: directory)
        recoveryManager.setActiveAccountScopeID(claimedScopeID, legacyAccountID: legacyAccountID)
        #expect(recoveryManager.isPinned(contentId: existingItem.contentId))
        #expect(recoveryManager.isPinned(contentId: legacyItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: claimURL.path))
    }

    @Test("External legacy recovery refreshes an active scope before its next flush")
    func externalLegacyRecoveryRefreshesActiveScope() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = "primary"
        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: accountID)
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        let legacyURL = directory.appendingPathComponent("favorites-\(accountID).json")
        let existingItem = FavoriteItem.from(TestFixtures.makeSong(id: "active-existing"))
        let recoveredItem = FavoriteItem.from(TestFixtures.makeSong(id: "active-recovered"))
        try JSONEncoder().encode([existingItem]).write(to: scopedURL)

        let manager = FavoritesManager(storageDirectory: directory)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        try JSONEncoder().encode([recoveredItem]).write(to: legacyURL)

        manager.recoverLegacyAccountFavorites(accountID: accountID, toScopeID: scopeID)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)

        #expect(manager.isPinned(contentId: existingItem.contentId))
        #expect(manager.isPinned(contentId: recoveredItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("A committed claim with failed cleanup keeps its scope read-only until recovery completes")
    func committedClaimCleanupFailureKeepsScopeReadOnly() throws {
        let directory = try self.makeTemporaryDirectory()
        defer {
            for claimURL in (try? self.legacyClaimURLs(in: directory)) ?? [] {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: claimURL.path)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let accountID = "primary"
        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: accountID)
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        let legacyURL = directory.appendingPathComponent("favorites-\(accountID).json")
        let existingItem = FavoriteItem.from(TestFixtures.makeSong(id: "cleanup-existing"))
        let recoveredItem = FavoriteItem.from(TestFixtures.makeSong(id: "cleanup-recovered"))

        try Data("not-json".utf8).write(to: scopedURL)
        try JSONEncoder().encode([recoveredItem]).write(to: legacyURL)

        let manager = FavoritesManager(storageDirectory: directory)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        let claimURL = try #require(self.legacyClaimURLs(in: directory).first)
        try JSONEncoder().encode([existingItem]).write(to: scopedURL, options: .atomic)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: claimURL.path)

        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)

        #expect(manager.isPinned(contentId: existingItem.contentId))
        #expect(manager.isPinned(contentId: recoveredItem.contentId))
        #expect(!manager.canMutate)
        manager.remove(contentId: recoveredItem.contentId)
        #expect(manager.isPinned(contentId: recoveredItem.contentId))

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: claimURL.path)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        #expect(manager.canMutate)
        #expect(!FileManager.default.fileExists(atPath: claimURL.path))

        manager.remove(contentId: recoveredItem.contentId)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        #expect(!manager.isPinned(contentId: recoveredItem.contentId))
    }

    @Test("Pending snapshot retry completes legacy recovery before restoring mutability")
    func pendingSnapshotRetryCompletesLegacyRecovery() async throws {
        let parentDirectory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }

        let blockedStorageURL = parentDirectory.appendingPathComponent("blocked-storage")
        try Data("not-a-directory".utf8).write(to: blockedStorageURL)

        let diskManager = FavoritesManager(storageDirectory: blockedStorageURL)
        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: "primary")
        let pendingItem = FavoriteItem.from(TestFixtures.makeSong(id: "pending-retry"))
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "legacy-during-retry"))
        let laterItem = FavoriteItem.from(TestFixtures.makeSong(id: "after-retry"))

        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")
        diskManager.add(pendingItem)
        diskManager.setActiveAccountScopeID(nil)
        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")
        #expect(!diskManager.canMutate)

        // Keep storage unavailable through the first retry so bounded backoff
        // must schedule another full recovery attempt.
        try await Task.sleep(for: .milliseconds(180))
        try FileManager.default.removeItem(at: blockedStorageURL)
        try FileManager.default.createDirectory(at: blockedStorageURL, withIntermediateDirectories: true)
        try JSONEncoder().encode([legacyItem])
            .write(to: blockedStorageURL.appendingPathComponent("favorites.json"))
        try await Task.sleep(for: .milliseconds(500))

        #expect(diskManager.canMutate)
        #expect(diskManager.isPinned(contentId: pendingItem.contentId))
        #expect(diskManager.isPinned(contentId: legacyItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: blockedStorageURL.appendingPathComponent("favorites.json").path))
        diskManager.add(laterItem)
        diskManager.setActiveAccountScopeID(nil)
        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")
        #expect(diskManager.isPinned(contentId: laterItem.contentId))
        #expect(diskManager.isPinned(contentId: legacyItem.contentId))
    }

    @Test("Malformed uncommitted legacy data does not lock a valid canonical scope")
    func malformedLegacyDataLeavesValidScopeMutable() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = "primary"
        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: accountID)
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        let legacyURL = directory.appendingPathComponent("favorites-\(accountID).json")
        let existingItem = FavoriteItem.from(TestFixtures.makeSong(id: "valid-canonical"))
        let addedItem = FavoriteItem.from(TestFixtures.makeSong(id: "valid-after-malformed-legacy"))
        try JSONEncoder().encode([existingItem]).write(to: scopedURL)
        try Data("not-json".utf8).write(to: legacyURL)

        let manager = FavoritesManager(storageDirectory: directory)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)

        #expect(manager.canMutate)
        #expect(manager.isPinned(contentId: existingItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(try self.legacyClaimURLs(in: directory).count == 1)

        manager.add(addedItem)
        manager.setActiveAccountScopeID(nil)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        #expect(manager.isPinned(contentId: existingItem.contentId))
        #expect(manager.isPinned(contentId: addedItem.contentId))
    }

    @Test("Inactive legacy recovery retries for its reserved destination")
    func inactiveLegacyRecoveryKeepsOriginalDestination() async throws {
        let directory = try self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let accountID = "primary"
        let originalScopeID = FavoritesManager.accountScopeID(ownerID: "original-owner", accountID: accountID)
        let competingScopeID = FavoritesManager.accountScopeID(ownerID: "competing-owner", accountID: accountID)
        let legacyURL = directory.appendingPathComponent("favorites-\(accountID).json")
        let originalTargetURL = directory.appendingPathComponent("favorites-\(originalScopeID).json")
        let competingTargetURL = directory.appendingPathComponent("favorites-\(competingScopeID).json")
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "inactive-reserved"))
        try JSONEncoder().encode([legacyItem]).write(to: legacyURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)

        let manager = FavoritesManager(storageDirectory: directory)
        manager.recoverLegacyAccountFavorites(accountID: accountID, toScopeID: originalScopeID)
        manager.recoverLegacyAccountFavorites(accountID: accountID, toScopeID: competingScopeID)

        // Let the first retry fail while the directory remains unavailable.
        try await Task.sleep(for: .milliseconds(180))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
        try await Task.sleep(for: .milliseconds(500))

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(atPath: originalTargetURL.path))
        #expect(!FileManager.default.fileExists(atPath: competingTargetURL.path))
        let recoveredItems = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: originalTargetURL))
        #expect(recoveredItems.map(\.contentId) == [legacyItem.contentId])
    }

    @Test("Transient legacy claim read failures keep the canonical scope read-only")
    func transientClaimReadFailureRemainsRetryable() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = "primary"
        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: accountID)
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        let legacyURL = directory.appendingPathComponent("favorites-\(accountID).json")
        let existingItem = FavoriteItem.from(TestFixtures.makeSong(id: "read-existing"))
        let recoveredItem = FavoriteItem.from(TestFixtures.makeSong(id: "read-recovered"))
        try Data("not-json".utf8).write(to: scopedURL)
        try JSONEncoder().encode([recoveredItem]).write(to: legacyURL)

        let manager = FavoritesManager(storageDirectory: directory)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        let claimURL = try #require(self.legacyClaimURLs(in: directory).first)
        let claimData = try Data(contentsOf: claimURL)
        try FileManager.default.removeItem(at: claimURL)
        try FileManager.default.createDirectory(at: claimURL, withIntermediateDirectories: true)
        try JSONEncoder().encode([existingItem]).write(to: scopedURL, options: .atomic)

        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        #expect(!manager.canMutate)
        #expect(manager.isPinned(contentId: existingItem.contentId))

        try FileManager.default.removeItem(at: claimURL)
        try claimData.write(to: claimURL)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)

        #expect(manager.canMutate)
        #expect(manager.isPinned(contentId: existingItem.contentId))
        #expect(manager.isPinned(contentId: recoveredItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: claimURL.path))
    }

    @Test("Pending legacy recovery follows a finalized owner scope")
    func pendingRecoveryRetargetsAfterOwnerFinalization() async throws {
        let directory = try self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let accountID = "primary"
        let provisionalOwnerID = "provisional-owner"
        let resolvedOwnerID = "resolved-owner"
        let provisionalScopeID = FavoritesManager.accountScopeID(ownerID: provisionalOwnerID, accountID: accountID)
        let resolvedScopeID = FavoritesManager.accountScopeID(ownerID: resolvedOwnerID, accountID: accountID)
        let legacyURL = directory.appendingPathComponent("favorites-\(accountID).json")
        let provisionalTargetURL = directory.appendingPathComponent("favorites-\(provisionalScopeID).json")
        let resolvedTargetURL = directory.appendingPathComponent("favorites-\(resolvedScopeID).json")
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "retargeted-recovery"))
        try JSONEncoder().encode([legacyItem]).write(to: legacyURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)

        let manager = FavoritesManager(storageDirectory: directory)
        manager.recoverLegacyAccountFavorites(accountID: accountID, toScopeID: provisionalScopeID)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)

        #expect(manager.prepareAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        #expect(manager.commitAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        #expect(manager.finalizeAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        try await Task.sleep(for: .milliseconds(300))

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(!FileManager.default.fileExists(atPath: provisionalTargetURL.path))
        let recoveredItems = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: resolvedTargetURL))
        #expect(recoveredItems.map(\.contentId) == [legacyItem.contentId])
    }

    @Test("Foreground activation supersedes an inactive recovery retry")
    func foregroundActivationCancelsInactiveRetry() async throws {
        let directory = try self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let accountID = "primary"
        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: accountID)
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        let legacyURL = directory.appendingPathComponent("favorites-\(accountID).json")
        let existingItem = FavoriteItem.from(TestFixtures.makeSong(id: "foreground-existing"))
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "foreground-legacy"))
        let addedItem = FavoriteItem.from(TestFixtures.makeSong(id: "foreground-added"))
        try JSONEncoder().encode([existingItem]).write(to: scopedURL)
        try JSONEncoder().encode([legacyItem]).write(to: legacyURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)

        let manager = FavoritesManager(storageDirectory: directory)
        manager.recoverLegacyAccountFavorites(accountID: accountID, toScopeID: scopeID)
        try await Task.sleep(for: .milliseconds(60))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)

        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        manager.add(addedItem)
        try await Task.sleep(for: .milliseconds(80))

        #expect(manager.isPinned(contentId: existingItem.contentId))
        #expect(manager.isPinned(contentId: legacyItem.contentId))
        #expect(manager.isPinned(contentId: addedItem.contentId))
        manager.setActiveAccountScopeID(nil)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        #expect(manager.isPinned(contentId: addedItem.contentId))
    }

    @Test("Delayed scope recovery flushes edits made after account recovery unlocks the scope")
    func scopeRecoveryRetryFlushesNewActiveEdits() async throws {
        let directory = try self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let accountID = "primary"
        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: accountID)
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        let globalLegacyURL = directory.appendingPathComponent("favorites.json")
        let existingItem = FavoriteItem.from(TestFixtures.makeSong(id: "scope-retry-existing"))
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "scope-retry-legacy"))
        let addedItem = FavoriteItem.from(TestFixtures.makeSong(id: "scope-retry-added"))
        try JSONEncoder().encode([existingItem]).write(to: scopedURL)
        try JSONEncoder().encode([legacyItem]).write(to: globalLegacyURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)

        let manager = FavoritesManager(storageDirectory: directory)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        #expect(!manager.canMutate)

        try await Task.sleep(for: .milliseconds(60))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path)
        manager.recoverLegacyAccountFavorites(accountID: accountID, toScopeID: scopeID)
        #expect(manager.canMutate)
        manager.add(addedItem)
        try await Task.sleep(for: .milliseconds(160))

        #expect(manager.isPinned(contentId: existingItem.contentId))
        #expect(manager.isPinned(contentId: legacyItem.contentId))
        #expect(manager.isPinned(contentId: addedItem.contentId))
        manager.setActiveAccountScopeID(nil)
        manager.setActiveAccountScopeID(scopeID, legacyAccountID: accountID)
        #expect(manager.isPinned(contentId: legacyItem.contentId))
        #expect(manager.isPinned(contentId: addedItem.contentId))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesManagerTestsLegacyMigrationClaims-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func legacyClaimURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".favorites-legacy-claim-") }
    }
}
