import Foundation
import Testing
@testable import Kaset

/// Tests for FavoritesManager using Swift Testing.
@Suite(.serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct FavoritesManagerTests {
    /// Use a fresh manager for each test (skipLoad to avoid disk state)
    var manager: FavoritesManager

    init() {
        self.manager = FavoritesManager(skipLoad: true)
        self.manager.setActiveAccountScopeID("test-scope")
    }

    // MARK: - Basic Operations

    @Test("Initial state is empty")
    func initialState() {
        #expect(self.manager.items.isEmpty)
        #expect(self.manager.isVisible == false)
    }

    @Test("Add song succeeds")
    func addSong() {
        let song = TestFixtures.makeSong(id: "test-song-1")
        let item = FavoriteItem.from(song)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isVisible == true)
        #expect(self.manager.isPinned(song: song) == true)
    }

    @Test("Add album succeeds")
    func addAlbum() {
        let album = TestFixtures.makeAlbum(id: "MPRE-test-album")
        let item = FavoriteItem.from(album)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isPinned(album: album) == true)
    }

    @Test("Add playlist succeeds")
    func addPlaylist() {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist")
        let item = FavoriteItem.from(playlist)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isPinned(playlist: playlist) == true)
    }

    @Test("Add artist succeeds")
    func addArtist() {
        let artist = TestFixtures.makeArtist(id: "UC-test-artist")
        let item = FavoriteItem.from(artist)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isPinned(artist: artist) == true)
    }

    @Test("Add podcast show succeeds")
    func addPodcastShow() {
        let podcastShow = TestFixtures.makePodcastShow(id: "MPSPP-test-podcast", title: "Test Podcast Show")
        let item = FavoriteItem.from(podcastShow)

        self.manager.add(item)

        #expect(self.manager.items.count == 1)
        #expect(self.manager.isVisible == true)
        #expect(self.manager.isPinned(podcastShow: podcastShow) == true)
    }

    @Test("Add duplicate is ignored")
    func addDuplicateIgnored() {
        let song = TestFixtures.makeSong(id: "duplicate-song")
        let item1 = FavoriteItem.from(song)
        let item2 = FavoriteItem.from(song)

        self.manager.add(item1)
        self.manager.add(item2)

        #expect(self.manager.items.count == 1)
    }

    @Test("New items added to front")
    func newItemsAddedToFront() {
        let song1 = TestFixtures.makeSong(id: "song-1", title: "First Song")
        let song2 = TestFixtures.makeSong(id: "song-2", title: "Second Song")

        self.manager.add(.from(song1))
        self.manager.add(.from(song2))

        #expect(self.manager.items.count == 2)
        #expect(self.manager.items[0].title == "Second Song")
        #expect(self.manager.items[1].title == "First Song")
    }

    // MARK: - Remove Operations

    @Test("Remove by contentId succeeds")
    func removeByContentId() {
        let song = TestFixtures.makeSong(id: "remove-test")
        self.manager.add(.from(song))
        #expect(self.manager.items.count == 1)

        self.manager.remove(contentId: song.videoId)

        #expect(self.manager.items.isEmpty)
        #expect(self.manager.isPinned(song: song) == false)
    }

    @Test("Remove non-existent item is no-op")
    func removeNonExistent() {
        let song = TestFixtures.makeSong(id: "existing")
        self.manager.add(.from(song))

        self.manager.remove(contentId: "non-existent")

        #expect(self.manager.items.count == 1)
    }

    // MARK: - Toggle Operations

    @Test("Toggle adds then removes")
    func toggleAddsAndRemoves() {
        let song = TestFixtures.makeSong(id: "toggle-test")

        // First toggle should add
        self.manager.toggle(song: song)
        #expect(self.manager.isPinned(song: song) == true)
        #expect(self.manager.items.count == 1)

        // Second toggle should remove
        self.manager.toggle(song: song)
        #expect(self.manager.isPinned(song: song) == false)
        #expect(self.manager.items.isEmpty)
    }

    @Test("Toggle podcast show adds then removes")
    func togglePodcastShowAddsAndRemoves() {
        let podcastShow = TestFixtures.makePodcastShow(id: "MPSPP-toggle-podcast", title: "Toggle Podcast")

        self.manager.toggle(podcastShow: podcastShow)
        #expect(self.manager.isPinned(podcastShow: podcastShow) == true)
        #expect(self.manager.items.count == 1)

        self.manager.toggle(podcastShow: podcastShow)
        #expect(self.manager.isPinned(podcastShow: podcastShow) == false)
        #expect(self.manager.items.isEmpty)
    }

    // MARK: - Move Operations

    @Test("Move item changes position")
    func moveItem() {
        let song1 = TestFixtures.makeSong(id: "move-1", title: "Song 1")
        let song2 = TestFixtures.makeSong(id: "move-2", title: "Song 2")
        let song3 = TestFixtures.makeSong(id: "move-3", title: "Song 3")

        self.manager.add(.from(song1))
        self.manager.add(.from(song2))
        self.manager.add(.from(song3))

        // Order is now: song3, song2, song1 (newest first)
        #expect(self.manager.items[0].title == "Song 3")
        #expect(self.manager.items[1].title == "Song 2")
        #expect(self.manager.items[2].title == "Song 1")

        // Move song1 (index 2) to index 0
        self.manager.move(from: IndexSet(integer: 2), to: 0)

        #expect(self.manager.items[0].title == "Song 1")
        #expect(self.manager.items[1].title == "Song 3")
        #expect(self.manager.items[2].title == "Song 2")
    }

    @Test("Move to top succeeds")
    func moveToTop() {
        let song1 = TestFixtures.makeSong(id: "top-1", title: "Song 1")
        let song2 = TestFixtures.makeSong(id: "top-2", title: "Song 2")
        let song3 = TestFixtures.makeSong(id: "top-3", title: "Song 3")

        self.manager.add(.from(song1))
        self.manager.add(.from(song2))
        self.manager.add(.from(song3))

        // Order is: song3, song2, song1
        // Move song1 to top
        self.manager.moveToTop(contentId: song1.videoId)

        #expect(self.manager.items[0].title == "Song 1")
    }

    @Test("Move to end succeeds")
    func moveToEnd() {
        let song1 = TestFixtures.makeSong(id: "end-1", title: "Song 1")
        let song2 = TestFixtures.makeSong(id: "end-2", title: "Song 2")
        let song3 = TestFixtures.makeSong(id: "end-3", title: "Song 3")

        self.manager.add(.from(song1))
        self.manager.add(.from(song2))
        self.manager.add(.from(song3))

        // Order is: song3, song2, song1
        // Move song3 to end
        self.manager.moveToEnd(contentId: song3.videoId)

        #expect(self.manager.items[2].title == "Song 3")
    }

    // MARK: - isPinned Checks

    @Test("isPinned returns correct state")
    func isPinnedReturnsCorrectState() {
        let song = TestFixtures.makeSong(id: "pinned-test")

        #expect(self.manager.isPinned(song: song) == false)
        #expect(self.manager.isPinned(contentId: song.videoId) == false)

        self.manager.add(.from(song))

        #expect(self.manager.isPinned(song: song) == true)
        #expect(self.manager.isPinned(contentId: song.videoId) == true)
    }

    // MARK: - Clear All

    @Test("Clear all removes all items")
    func clearAllRemovesAll() {
        self.manager.add(.from(TestFixtures.makeSong(id: "clear-1")))
        self.manager.add(.from(TestFixtures.makeSong(id: "clear-2")))
        self.manager.add(.from(TestFixtures.makeSong(id: "clear-3")))

        #expect(self.manager.items.count == 3)

        self.manager.clearAll()

        #expect(self.manager.items.isEmpty)
        #expect(self.manager.isVisible == false)
    }

    // MARK: - Account Scope

    @Test("Switching accounts isolates favorites")
    func switchingAccountsIsolatesFavorites() {
        let songA = TestFixtures.makeSong(id: "account-a-song")
        let songB = TestFixtures.makeSong(id: "account-b-song")

        self.manager.setActiveAccountScopeID("account-a")
        self.manager.add(.from(songA))

        self.manager.setActiveAccountScopeID("account-b")
        #expect(self.manager.items.isEmpty)
        self.manager.add(.from(songB))

        self.manager.setActiveAccountScopeID("account-a")
        #expect(self.manager.isPinned(song: songA))
        #expect(!self.manager.isPinned(song: songB))
    }

    @Test("Inactive scope clears visible favorites without losing stored pins")
    func inactiveScopeClearsVisibleFavorites() {
        let song = TestFixtures.makeSong(id: "logout-song")

        self.manager.setActiveAccountScopeID("brand-account")
        self.manager.add(.from(song))
        self.manager.setActiveAccountScopeID(nil)

        #expect(self.manager.items.isEmpty)
        #expect(self.manager.activeScopeID == nil)

        self.manager.setActiveAccountScopeID("brand-account")
        #expect(self.manager.isPinned(song: song))
    }

    @Test("Primary scopes differ across Google users")
    func primaryScopesDifferAcrossGoogleUsers() {
        let firstScope = FavoritesManager.accountScopeID(
            ownerID: FavoritesManager.identityID(for: "first@example.test"),
            accountID: "primary"
        )
        let secondScope = FavoritesManager.accountScopeID(
            ownerID: FavoritesManager.identityID(for: "second@example.test"),
            accountID: "primary"
        )

        #expect(firstScope != secondScope)
        #expect(firstScope == FavoritesManager.accountScopeID(
            ownerID: FavoritesManager.identityID(for: " FIRST@example.test "),
            accountID: "primary"
        ))
    }

    @Test("Opaque identity IDs preserve case-sensitive distinctions")
    func opaqueIdentityIDsPreserveCase() {
        #expect(
            FavoritesManager.opaqueIdentityID(for: "identity-value-A")
                != FavoritesManager.opaqueIdentityID(for: "identity-value-a")
        )
    }

    @Test("Inactive scope rejects mutations")
    func inactiveScopeRejectsMutations() {
        let song = TestFixtures.makeSong(id: "pending-scope-song")
        let inactiveManager = FavoritesManager(skipLoad: true)

        inactiveManager.add(.from(song))
        inactiveManager.toggle(song: song)
        inactiveManager.clearAll()
        inactiveManager.reset(with: [.from(song)])

        #expect(!inactiveManager.canMutate)
        #expect(inactiveManager.items.isEmpty)
    }

    @Test("Guest mode restores the last signed-in scope")
    func guestModeRestoresLastSignedInScope() {
        let song = TestFixtures.makeSong(id: "personal-song")
        self.manager.setActiveAccountScopeID("personal-scope")
        self.manager.add(.from(song))

        self.manager.enterGuestMode()
        #expect(self.manager.items.isEmpty)

        self.manager.exitGuestMode()
        #expect(self.manager.isPinned(song: song))
    }

    @Test("Account scope changes stay deferred while Guest Mode is active")
    func accountScopeChangeWhileGuestDefersActivation() {
        let firstItem = FavoriteItem.from(TestFixtures.makeSong(id: "first-personal"))
        let secondItem = FavoriteItem.from(TestFixtures.makeSong(id: "second-personal"))
        let guestItem = FavoriteItem.from(TestFixtures.makeSong(id: "guest-item"))

        self.manager.setActiveAccountScopeID("first-scope")
        self.manager.add(firstItem)
        self.manager.setActiveAccountScopeID("second-scope")
        self.manager.add(secondItem)
        self.manager.setActiveAccountScopeID("first-scope")
        self.manager.enterGuestMode()
        self.manager.add(guestItem)

        self.manager.setActiveAccountScopeID("second-scope", legacyAccountID: "secondary")

        #expect(self.manager.isPinned(contentId: guestItem.contentId))
        #expect(!self.manager.isPinned(contentId: secondItem.contentId))

        self.manager.setDeferredAccountScopeID(nil)
        #expect(self.manager.isPinned(contentId: guestItem.contentId))
        self.manager.setDeferredAccountScopeID("second-scope", legacyAccountID: "secondary")
        self.manager.exitGuestMode()

        #expect(!self.manager.isPinned(contentId: guestItem.contentId))
        #expect(self.manager.isPinned(contentId: secondItem.contentId))
    }

    @Test("Legacy favorites migrate when the first account scope activates")
    func legacyFavoritesMigrateOnFirstScopeActivation() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "legacy-song"))
        let legacyURL = directory.appendingPathComponent("favorites.json")
        try JSONEncoder().encode([legacyItem]).write(to: legacyURL)

        let diskManager = FavoritesManager(storageDirectory: directory)
        let scopeID = FavoritesManager.accountScopeID(
            ownerID: FavoritesManager.identityID(for: "owner@example.test"),
            accountID: "primary"
        )
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")

        #expect(diskManager.activeScopeID == nil)
        #expect(!FileManager.default.fileExists(atPath: scopedURL.path))

        diskManager.setActiveAccountScopeID(scopeID)

        #expect(diskManager.isPinned(contentId: legacyItem.contentId))
        #expect(FileManager.default.fileExists(atPath: scopedURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(try self.legacyClaimURLs(in: directory).isEmpty)
    }

    @Test("Primary favorites survive logout and relogin")
    func primaryFavoritesSurviveLogoutAndRelogin() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let diskManager = FavoritesManager(storageDirectory: directory)
        let scopeID = FavoritesManager.accountScopeID(
            ownerID: FavoritesManager.identityID(for: "owner@example.test"),
            accountID: "primary"
        )
        let song = TestFixtures.makeSong(id: "persisted-primary-song")

        diskManager.setActiveAccountScopeID(scopeID)
        diskManager.add(.from(song))
        diskManager.setActiveAccountScopeID(nil)

        #expect(diskManager.activeScopeID == nil)
        #expect(diskManager.items.isEmpty)

        diskManager.setActiveAccountScopeID(scopeID)
        #expect(diskManager.isPinned(song: song))
    }

    @Test("Activating a brand after logout does not overwrite primary favorites")
    func brandActivationAfterLogoutPreservesPrimaryFavorites() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let diskManager = FavoritesManager(storageDirectory: directory)
        let primaryScope = FavoritesManager.accountScopeID(
            ownerID: FavoritesManager.identityID(for: "owner@example.test"),
            accountID: "primary"
        )
        let brandScope = FavoritesManager.accountScopeID(
            ownerID: FavoritesManager.identityID(for: "owner@example.test"),
            accountID: "brand-account"
        )
        let primaryItem = FavoriteItem.from(TestFixtures.makeSong(id: "primary-song"))

        diskManager.setActiveAccountScopeID(primaryScope)
        diskManager.add(primaryItem)
        diskManager.setActiveAccountScopeID(nil)

        let primaryURL = directory.appendingPathComponent("favorites-\(primaryScope).json")
        let primaryDataBeforeBrandActivation = try Data(contentsOf: primaryURL)

        diskManager.setActiveAccountScopeID(brandScope)

        #expect(diskManager.items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryDataBeforeBrandActivation)
    }

    @Test("Prepared owner migration keeps sources until finalization")
    func preparedOwnerMigrationKeepsSourcesUntilFinalization() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let diskManager = FavoritesManager(storageDirectory: directory)
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
        let sourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "provisional-item"))
        let targetItem = FavoriteItem.from(TestFixtures.makeSong(id: "resolved-item"))

        diskManager.setActiveAccountScopeID(sourceScopeID)
        diskManager.add(sourceItem)
        diskManager.setActiveAccountScopeID(targetScopeID)
        diskManager.add(targetItem)
        diskManager.setActiveAccountScopeID(sourceScopeID)

        let sourceURL = directory.appendingPathComponent("favorites-\(sourceScopeID).json")
        let targetURL = directory.appendingPathComponent("favorites-\(targetScopeID).json")

        #expect(diskManager.prepareAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        let targetItemsBeforeCommit = try JSONDecoder().decode(
            [FavoriteItem].self,
            from: Data(contentsOf: targetURL)
        )
        #expect(targetItemsBeforeCommit.map(\.contentId) == [targetItem.contentId])

        #expect(diskManager.prepareAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        #expect(diskManager.commitAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        let committedItems = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: targetURL))
        #expect(Set(committedItems.map(\.contentId)) == Set([sourceItem.contentId, targetItem.contentId]))

        diskManager.finalizeAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        )

        #expect(diskManager.activeScopeID == targetScopeID)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(diskManager.isPinned(contentId: sourceItem.contentId))
        #expect(diskManager.isPinned(contentId: targetItem.contentId))
    }

    @Test("Failed owner migration leaves the provisional source intact")
    func failedOwnerMigrationLeavesProvisionalSourceIntact() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let diskManager = FavoritesManager(storageDirectory: directory)
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
        let sourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "provisional-item"))
        let sourceURL = directory.appendingPathComponent("favorites-\(sourceScopeID).json")
        let targetURL = directory.appendingPathComponent("favorites-\(targetScopeID).json")

        diskManager.setActiveAccountScopeID(sourceScopeID)
        diskManager.add(sourceItem)
        diskManager.setActiveAccountScopeID(nil)
        try Data("not-json".utf8).write(to: targetURL)

        #expect(!diskManager.prepareAccountScopeMerge(
            fromOwnerID: provisionalOwnerID,
            intoOwnerID: resolvedOwnerID,
            accountIDs: [accountID]
        ))
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        let sourceItems = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: sourceURL))
        #expect(sourceItems.map(\.contentId) == [sourceItem.contentId])
    }

    @Test("Legacy account-scoped favorites migrate into opaque scope")
    func legacyAccountScopedFavoritesMigrate() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "legacy-primary-song"))
        let legacyURL = directory.appendingPathComponent("favorites-primary.json")
        try JSONEncoder().encode([legacyItem]).write(to: legacyURL)

        let diskManager = FavoritesManager(storageDirectory: directory)
        let scopeID = FavoritesManager.accountScopeID(
            ownerID: "owner",
            accountID: "primary"
        )
        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")

        #expect(diskManager.isPinned(contentId: legacyItem.contentId))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(try self.legacyClaimURLs(in: directory).isEmpty)
    }

    @Test("Migration retry preserves new target additions and source removals")
    func migrationRetryReconcilesCurrentTargetAndSource() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let diskManager = FavoritesManager(storageDirectory: directory)
        let sourceOwnerID = "source-owner"
        let targetOwnerID = "target-owner"
        let accountID = "primary"
        let sourceScopeID = FavoritesManager.accountScopeID(ownerID: sourceOwnerID, accountID: accountID)
        let targetScopeID = FavoritesManager.accountScopeID(ownerID: targetOwnerID, accountID: accountID)
        let removedSourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "removed-source"))
        let retainedSourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "retained-source"))
        let newTargetItem = FavoriteItem.from(TestFixtures.makeSong(id: "new-target"))

        diskManager.setActiveAccountScopeID(sourceScopeID)
        diskManager.reset(with: [removedSourceItem, retainedSourceItem])
        diskManager.setActiveAccountScopeID(targetScopeID)
        diskManager.reset(with: [])
        diskManager.setActiveAccountScopeID(sourceScopeID)

        #expect(diskManager.prepareAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(diskManager.commitAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))

        diskManager.setActiveAccountScopeID(sourceScopeID)
        diskManager.remove(contentId: removedSourceItem.contentId)
        diskManager.setActiveAccountScopeID(targetScopeID)
        diskManager.add(newTargetItem)
        diskManager.setActiveAccountScopeID(sourceScopeID)

        #expect(diskManager.prepareAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(diskManager.commitAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))

        #expect(diskManager.prepareAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(diskManager.commitAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        diskManager.finalizeAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        )

        #expect(!diskManager.isPinned(contentId: removedSourceItem.contentId))
        #expect(diskManager.isPinned(contentId: retainedSourceItem.contentId))
        #expect(diskManager.isPinned(contentId: newTargetItem.contentId))
    }

    @Test("Pending first-write snapshot restores when the scope file is absent")
    func pendingFirstWriteRestoresWithoutFile() throws {
        let parentDirectory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }

        let blockedStorageURL = parentDirectory.appendingPathComponent("blocked-storage")
        try Data("not-a-directory".utf8).write(to: blockedStorageURL)

        let diskManager = FavoritesManager(storageDirectory: blockedStorageURL)
        let firstScope = "first-scope"
        let secondScope = "second-scope"
        let originalItem = FavoriteItem.from(TestFixtures.makeSong(id: "pending-original"))

        diskManager.setActiveAccountScopeID(firstScope)
        diskManager.add(originalItem)
        diskManager.setActiveAccountScopeID(secondScope)

        try FileManager.default.removeItem(at: blockedStorageURL)
        try FileManager.default.createDirectory(at: blockedStorageURL, withIntermediateDirectories: true)
        diskManager.setActiveAccountScopeID(firstScope)

        #expect(diskManager.isPinned(contentId: originalItem.contentId))
    }

    @Test("Owner migration consumes pending source and target snapshots")
    func ownerMigrationConsumesPendingSnapshots() throws {
        let parentDirectory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }

        let blockedStorageURL = parentDirectory.appendingPathComponent("blocked-storage")
        try Data("not-a-directory".utf8).write(to: blockedStorageURL)

        let diskManager = FavoritesManager(storageDirectory: blockedStorageURL)
        let sourceOwnerID = "source-owner"
        let targetOwnerID = "target-owner"
        let accountID = "primary"
        let sourceScopeID = FavoritesManager.accountScopeID(ownerID: sourceOwnerID, accountID: accountID)
        let targetScopeID = FavoritesManager.accountScopeID(ownerID: targetOwnerID, accountID: accountID)
        let sourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "pending-source"))
        let targetItem = FavoriteItem.from(TestFixtures.makeSong(id: "pending-target"))

        diskManager.setActiveAccountScopeID(sourceScopeID)
        diskManager.add(sourceItem)
        diskManager.setActiveAccountScopeID(targetScopeID)
        diskManager.add(targetItem)
        diskManager.setActiveAccountScopeID(nil)

        try FileManager.default.removeItem(at: blockedStorageURL)
        try FileManager.default.createDirectory(at: blockedStorageURL, withIntermediateDirectories: true)

        #expect(diskManager.prepareAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        #expect(diskManager.commitAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        ))
        diskManager.finalizeAccountScopeMerge(
            fromOwnerID: sourceOwnerID,
            intoOwnerID: targetOwnerID,
            accountIDs: [accountID]
        )
        diskManager.setActiveAccountScopeID(targetScopeID)

        #expect(diskManager.isPinned(contentId: sourceItem.contentId))
        #expect(diskManager.isPinned(contentId: targetItem.contentId))
    }

    @Test("Pending snapshot is materialized before legacy migration retry")
    func pendingSnapshotMaterializesBeforeLegacyMigration() throws {
        let parentDirectory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }

        let blockedStorageURL = parentDirectory.appendingPathComponent("blocked-storage")
        try Data("not-a-directory".utf8).write(to: blockedStorageURL)

        let diskManager = FavoritesManager(storageDirectory: blockedStorageURL)
        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: "primary")
        let pendingItem = FavoriteItem.from(TestFixtures.makeSong(id: "pending-item"))
        let legacyItem = FavoriteItem.from(TestFixtures.makeSong(id: "legacy-item"))

        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")
        diskManager.add(pendingItem)
        diskManager.setActiveAccountScopeID(nil)

        try FileManager.default.removeItem(at: blockedStorageURL)
        try FileManager.default.createDirectory(at: blockedStorageURL, withIntermediateDirectories: true)
        try JSONEncoder().encode([legacyItem])
            .write(to: blockedStorageURL.appendingPathComponent("favorites.json"))

        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")

        #expect(diskManager.isPinned(contentId: pendingItem.contentId))
        #expect(diskManager.isPinned(contentId: legacyItem.contentId))
    }

    @Test("Same-scope activation does not overwrite an unreadable file")
    func sameScopeActivationPreservesUnreadableFile() throws {
        let directory = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scopeID = FavoritesManager.accountScopeID(ownerID: "owner", accountID: "primary")
        let scopedURL = directory.appendingPathComponent("favorites-\(scopeID).json")
        let unreadableData = Data("not-json".utf8)
        try unreadableData.write(to: scopedURL)

        let diskManager = FavoritesManager(storageDirectory: directory)
        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")
        #expect(!diskManager.canMutate)
        diskManager.add(.from(TestFixtures.makeSong(id: "must-not-overwrite")))
        diskManager.setActiveAccountScopeID(scopeID, legacyAccountID: "primary")

        #expect(diskManager.items.isEmpty)
        #expect(try Data(contentsOf: scopedURL) == unreadableData)
    }

    // MARK: - FavoriteItem Model Tests

    @Test("FavoriteItem contentId returns correct value")
    func favoriteItemContentId() {
        let song = TestFixtures.makeSong(id: "content-id-test")
        let album = TestFixtures.makeAlbum(id: "MPRE-content-album")
        let playlist = TestFixtures.makePlaylist(id: "VL-content-playlist")
        let artist = TestFixtures.makeArtist(id: "UC-content-artist")
        let podcastShow = TestFixtures.makePodcastShow(id: "MPSPP-content-podcast")

        let songItem = FavoriteItem.from(song)
        let albumItem = FavoriteItem.from(album)
        let playlistItem = FavoriteItem.from(playlist)
        let artistItem = FavoriteItem.from(artist)
        let podcastItem = FavoriteItem.from(podcastShow)

        #expect(songItem.contentId == song.videoId)
        #expect(albumItem.contentId == album.id)
        #expect(playlistItem.contentId == playlist.id)
        #expect(artistItem.contentId == artist.id)
        #expect(podcastItem.contentId == podcastShow.id)
    }

    @Test("FavoriteItem title returns correct value")
    func favoriteItemTitle() {
        let song = TestFixtures.makeSong(title: "Test Song Title")
        let album = TestFixtures.makeAlbum(title: "Test Album Title")
        let podcastShow = TestFixtures.makePodcastShow(title: "Test Podcast Title")

        let songItem = FavoriteItem.from(song)
        let albumItem = FavoriteItem.from(album)
        let podcastItem = FavoriteItem.from(podcastShow)

        #expect(songItem.title == "Test Song Title")
        #expect(albumItem.title == "Test Album Title")
        #expect(podcastItem.title == "Test Podcast Title")
    }

    @Test("FavoriteItem subtitle returns correct value")
    func favoriteItemSubtitle() {
        let song = TestFixtures.makeSong(artistName: "Test Artist")
        let album = TestFixtures.makeAlbum(artistName: "Album Artist")
        let podcastShow = TestFixtures.makePodcastShow(author: "Podcast Host")

        let songItem = FavoriteItem.from(song)
        let albumItem = FavoriteItem.from(album)
        let podcastItem = FavoriteItem.from(podcastShow)

        #expect(songItem.subtitle == "Test Artist")
        #expect(albumItem.subtitle == "Album Artist")
        #expect(podcastItem.subtitle == "Podcast Host")
    }

    @Test("FavoriteItem typeLabel returns correct value")
    func favoriteItemTypeLabel() {
        let songItem = FavoriteItem.from(TestFixtures.makeSong())
        let albumItem = FavoriteItem.from(TestFixtures.makeAlbum())
        let playlistItem = FavoriteItem.from(TestFixtures.makePlaylist())
        let artistItem = FavoriteItem.from(TestFixtures.makeArtist())
        let podcastItem = FavoriteItem.from(TestFixtures.makePodcastShow())

        #expect(songItem.typeLabel == "Song")
        #expect(albumItem.typeLabel == "Album")
        #expect(playlistItem.typeLabel == "Playlist")
        #expect(artistItem.typeLabel == "Artist")
        #expect(podcastItem.typeLabel == "Podcast")
    }

    @Test("FavoriteItem equality based on contentId")
    func favoriteItemEquality() {
        let song = TestFixtures.makeSong(id: "same-id")
        let item1 = FavoriteItem.from(song)
        let item2 = FavoriteItem.from(song)

        // Should be equal even though they have different UUIDs
        #expect(item1 == item2)
        #expect(item1.hashValue == item2.hashValue)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func legacyClaimURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".favorites-legacy-claim-") }
    }

    @Test("FavoriteItem asHomeSectionItem conversion")
    func favoriteItemAsHomeSectionItem() {
        let song = TestFixtures.makeSong(id: "convert-test", title: "Convert Song")
        let item = FavoriteItem.from(song)

        guard let homeSectionItem = item.asHomeSectionItem else {
            Issue.record("Expected non-nil HomeSectionItem")
            return
        }
        #expect(homeSectionItem.title == "Convert Song")
        if case let .song(convertedSong) = homeSectionItem {
            #expect(convertedSong.videoId == "convert-test")
        } else {
            Issue.record("Expected song type")
        }
    }

    @Test("FavoriteItem asHomeSectionItem returns nil for podcast show")
    func favoriteItemAsHomeSectionItemPodcastShow() {
        let podcastShow = TestFixtures.makePodcastShow(id: "MPSPP-home-section-nil")
        let item = FavoriteItem.from(podcastShow)

        #expect(item.asHomeSectionItem == nil)
    }
}
