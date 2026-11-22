// swiftlint:disable file_length

import Foundation
import Testing
@testable import Kaset

@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct AccountServiceTests {
    @Test @MainActor func initialStateIsEmpty() {
        let services = Self.createService()

        #expect(services.account.accounts.isEmpty)
        #expect(services.account.currentAccount == nil)
        #expect(services.account.hasBrandAccounts == false)
        #expect(services.account.currentBrandId == nil)
        #expect(services.account.isLoading == false)
        #expect(services.account.didCompleteAccountResolution == false)
        #expect(services.account.lastError == nil)
    }

    @Test @MainActor func accountResolutionTracksCurrentAuthenticationIdentity() async {
        let services = Self.createService()

        await Self.populateAccounts(services, accounts: [MockUserAccountData.primaryAccount])
        #expect(services.account.didCompleteAccountResolution == true)

        services.auth.sessionExpired()
        services.account.authenticationIdentityDidChange()

        #expect(services.account.didCompleteAccountResolution == false)
    }

    @Test @MainActor func hasBrandAccountsReturnsFalseForSingleAccount() async {
        let services = Self.createService()

        await Self.populateAccounts(services, accounts: [MockUserAccountData.primaryAccount])

        #expect(services.account.hasBrandAccounts == false)
    }

    @Test @MainActor func hasBrandAccountsReturnsTrueForMultipleAccounts() async {
        let services = Self.createService()

        await Self.populateAccounts(services, accounts: [
            MockUserAccountData.primaryAccount,
            MockUserAccountData.brandAccount,
        ])

        #expect(services.account.hasBrandAccounts == true)
    }

    @Test @MainActor func fetchAccountsUpdatesLikeStatusCacheScope() async {
        let services = Self.createService()

        await Self.populateAccounts(
            services,
            accounts: [MockUserAccountData.primaryAccount, MockUserAccountData.brandAccount],
            selectedIndex: 1
        )

        #expect(SongLikeStatusManager.shared.activeAccountID == MockUserAccountData.brandAccount.id)
    }

    @Test @MainActor func favoritesOwnerScopeStaysStableAcrossPartialAccountResponses() async throws {
        let services = Self.createService()
        services.auth.completeLogin(sapisid: "test-sapisid")

        let originalPrimary = UserAccount.from(
            name: "Original Name",
            handle: "@stable-handle",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [originalPrimary]
        )
        await services.account.fetchAccounts()
        #expect(services.account.currentFavoritesScopeID == nil)
        let provisionalContentScope = try #require(services.account.currentAccountScopeID)
        #expect(!FavoritesManager.shared.canMutate)

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [originalPrimary]
        )
        await services.account.fetchAccounts()
        let resolvedScope = try #require(services.account.currentFavoritesScopeID)
        #expect(services.account.currentAccountScopeID == provisionalContentScope)

        let renamedPrimary = UserAccount.from(
            name: "Renamed Profile",
            handle: "@renamed-handle",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [renamedPrimary]
        )
        await services.account.fetchAccounts()
        #expect(services.account.currentFavoritesScopeID == resolvedScope)
        #expect(services.account.currentAccountScopeID == provisionalContentScope)

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "different@example.test",
            accounts: [renamedPrimary]
        )
        await services.account.fetchAccounts()
        #expect(services.account.currentFavoritesScopeID == nil)
        let conflictedContentScope = try #require(services.account.currentAccountScopeID)
        #expect(conflictedContentScope != provisionalContentScope)

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [renamedPrimary]
        )
        await services.account.fetchAccounts()
        #expect(services.account.currentFavoritesScopeID == resolvedScope)
        let recoveredContentScope = try #require(services.account.currentAccountScopeID)
        #expect(recoveredContentScope != conflictedContentScope)

        services.auth.sessionExpired()
        services.account.authenticationIdentityDidChange()
        services.auth.completeLogin(sapisid: "different-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [renamedPrimary]
        )
        await services.account.fetchAccounts()
        #expect(services.account.currentFavoritesScopeID == nil)
        let newAuthenticationContentScope = try #require(services.account.currentAccountScopeID)
        #expect(newAuthenticationContentScope != recoveredContentScope)

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [renamedPrimary]
        )
        await services.account.fetchAccounts()
        #expect(services.account.currentFavoritesScopeID == resolvedScope)
        #expect(services.account.currentAccountScopeID == newAuthenticationContentScope)
    }

    @Test @MainActor func unverifiedEmailChangeDoesNotBecomeOwnerAlias() async throws {
        let services = Self.createService()
        let primary = UserAccount.from(
            name: "Primary",
            handle: "@primary",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )
        services.auth.completeLogin(sapisid: "first-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "first@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()
        let initialScope = try #require(services.account.currentFavoritesScopeID)
        let begins = LockedCounter()
        let ends = LockedCounter()
        services.account.setAccountBoundaryHandlers(
            willBegin: { begins.increment() },
            didEnd: { ends.increment() },
            drain: {}
        )

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "different@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()
        #expect(services.account.currentFavoritesScopeID == nil)
        #expect(begins.count == 1)
        #expect(ends.count == 1)

        services.auth.sessionExpired()
        services.account.authenticationIdentityDidChange()
        services.auth.completeLogin(sapisid: "second-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "different@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()

        let differentOwnerScope = try #require(services.account.currentFavoritesScopeID)
        #expect(differentOwnerScope != initialScope)
    }

    @Test @MainActor func conflictingDurableOwnerSignalsLeaveScopeUnresolved() async throws {
        let services = Self.createService()
        let primary = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil,
            thumbnailURL: nil, isSelected: true
        )

        services.auth.completeLogin(sapisid: "first-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "first@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()
        let firstScope = try #require(services.account.currentFavoritesScopeID)
        FavoritesManager.shared.add(.from(TestFixtures.makeSong(id: "first-owner-favorite")))

        services.auth.sessionExpired()
        services.account.authenticationIdentityDidChange()
        services.auth.completeLogin(sapisid: "second-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "second@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()
        let secondScope = try #require(services.account.currentFavoritesScopeID)
        #expect(secondScope != firstScope)

        services.auth.sessionExpired()
        services.account.authenticationIdentityDidChange()
        services.auth.completeLogin(sapisid: "first-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [primary]
        )
        await services.account.fetchAccounts()
        let unresolvedContentScope = try #require(services.account.currentAccountScopeID)
        #expect(services.account.currentFavoritesScopeID == nil)

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "second@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()

        #expect(services.account.currentFavoritesScopeID == nil)
        let conflictedContentScope = try #require(services.account.currentAccountScopeID)
        #expect(conflictedContentScope != unresolvedContentScope)
        #expect(!FavoritesManager.shared.canMutate)
        #expect(!FavoritesManager.shared.isPinned(contentId: "first-owner-favorite"))

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "first@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()

        #expect(services.account.currentFavoritesScopeID == firstScope)
        #expect(services.account.currentAccountScopeID != conflictedContentScope)
    }

    @Test @MainActor func reauthenticationDoesNotReuseOwnerForEmailLessResponse() async throws {
        let services = Self.createService()
        services.auth.completeLogin(sapisid: "first-session")

        let primary = UserAccount.from(
            name: "Primary",
            handle: "@primary",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "first@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()
        let firstScope = try #require(services.account.currentFavoritesScopeID)

        services.auth.sessionExpired()
        services.auth.completeLogin(sapisid: "second-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [primary]
        )
        await services.account.fetchAccounts()

        #expect(services.account.currentFavoritesScopeID == nil)
        #expect(!FavoritesManager.shared.canMutate)
        FavoritesManager.shared.add(.from(TestFixtures.makeSong(id: "unresolved-favorite")))

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "first@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()

        #expect(services.account.currentFavoritesScopeID == firstScope)
        #expect(!FavoritesManager.shared.isPinned(contentId: "unresolved-favorite"))
    }

    @Test @MainActor func emailLessOwnerRemainsInactiveAcrossCredentialRotations() async {
        let services = Self.createService()
        let primary = UserAccount.from(
            name: "Stable Primary",
            handle: "@stable-primary",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )

        services.auth.completeLogin(sapisid: "first-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [primary]
        )
        await services.account.fetchAccounts()
        #expect(services.account.currentFavoritesScopeID == nil)
        #expect(!FavoritesManager.shared.canMutate)
        FavoritesManager.shared.add(.from(TestFixtures.makeSong(id: "pre-resolution-favorite")))

        for credential in ["second-session", "third-session"] {
            services.auth.sessionExpired()
            services.account.authenticationIdentityDidChange()
            services.auth.completeLogin(sapisid: credential)
            services.account.authenticationIdentityDidChange()
            services.client.accountsListResponse = AccountsListResponse(
                googleEmail: nil,
                accounts: [primary]
            )
            await services.account.fetchAccounts()

            #expect(services.account.currentFavoritesScopeID == nil)
            #expect(!FavoritesManager.shared.canMutate)
        }

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "stable@example.test",
            accounts: [primary]
        )
        await services.account.fetchAccounts()

        #expect(services.account.currentFavoritesScopeID != nil)
        #expect(FavoritesManager.shared.canMutate)
        #expect(!FavoritesManager.shared.isPinned(contentId: "pre-resolution-favorite"))
        FavoritesManager.shared.add(.from(TestFixtures.makeSong(id: "resolved-favorite")))
        #expect(FavoritesManager.shared.isPinned(contentId: "resolved-favorite"))
    }

    @Test @MainActor func provisionalAuthAliasPersistsWithoutRawIdentity() async throws {
        let suiteName = "AccountServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primary = UserAccount.from(
            name: "Persistent Primary",
            handle: "@persistent-primary",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )

        let firstServices = Self.createService(favoritesOwnerDefaults: defaults)
        firstServices.auth.completeLogin(sapisid: "persistent-session")
        firstServices.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [primary]
        )
        await firstServices.account.fetchAccounts()
        #expect(firstServices.account.currentFavoritesScopeID == nil)

        let persistedData = try #require(defaults.data(forKey: "favorites.ownerState"))
        let persistedText = try #require(String(data: persistedData, encoding: .utf8))
        #expect(!persistedText.contains("@persistent-primary"))
        #expect(!persistedText.contains("persistent-session"))
        let persistedJSON = try #require(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        let ownerIDsByAliasID = try #require(
            persistedJSON["ownerIDsByAliasID"] as? [String: String]
        )
        let provisionalOwnerID = try #require(ownerIDsByAliasID.values.first)

        let restoredServices = Self.createService(favoritesOwnerDefaults: defaults)
        restoredServices.auth.completeLogin(sapisid: "persistent-session")
        restoredServices.client.accountsListResponse = AccountsListResponse(
            googleEmail: "persistent@example.test",
            accounts: [primary]
        )
        await restoredServices.account.fetchAccounts()

        let expectedScope = FavoritesManager.accountScopeID(
            ownerID: provisionalOwnerID,
            accountID: primary.id
        )
        #expect(restoredServices.account.currentFavoritesScopeID == expectedScope)
        #expect(FavoritesManager.shared.canMutate)
    }

    @Test @MainActor func persistedVerifiedOwnerRequiresCurrentGenerationEmailCorroboration() async throws {
        let suiteName = "AccountServiceTests.verified-relaunch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let primary = UserAccount.from(
            name: "Persistent Primary",
            handle: "@persistent-primary",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )
        let favorite = FavoriteItem.from(TestFixtures.makeSong(id: "persisted-verified-owner"))

        let firstServices = Self.createService(favoritesOwnerDefaults: defaults)
        firstServices.auth.completeLogin(sapisid: "reused-multilogin-cookie")
        firstServices.client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [primary]
        )
        await firstServices.account.fetchAccounts()
        let resolvedScope = try #require(firstServices.account.currentFavoritesScopeID)
        FavoritesManager.shared.add(favorite)

        let restoredServices = Self.createService(favoritesOwnerDefaults: defaults)
        restoredServices.auth.completeLogin(sapisid: "reused-multilogin-cookie")
        restoredServices.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [primary]
        )
        await restoredServices.account.fetchAccounts()

        #expect(restoredServices.account.currentFavoritesScopeID == nil)
        #expect(!FavoritesManager.shared.canMutate)
        #expect(!FavoritesManager.shared.isPinned(contentId: favorite.contentId))

        restoredServices.client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [primary]
        )
        await restoredServices.account.fetchAccounts()
        #expect(restoredServices.account.currentFavoritesScopeID == resolvedScope)
        #expect(FavoritesManager.shared.isPinned(contentId: favorite.contentId))

        restoredServices.client.accountsListResponse = AccountsListResponse(
            googleEmail: nil,
            accounts: [primary]
        )
        await restoredServices.account.fetchAccounts()
        #expect(restoredServices.account.currentFavoritesScopeID == resolvedScope)
    }

    @Test @MainActor func pendingOwnerFinalizationResumesFromPersistedState() throws {
        let suiteName = "AccountServiceTests.finalization.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sourceOwnerID = "source-owner-\(UUID().uuidString)"
        let targetOwnerID = "target-owner-\(UUID().uuidString)"
        let accountID = "primary"
        let sourceScopeID = FavoritesManager.accountScopeID(
            ownerID: sourceOwnerID,
            accountID: accountID
        )
        let targetScopeID = FavoritesManager.accountScopeID(
            ownerID: targetOwnerID,
            accountID: accountID
        )
        let sourceItem = FavoriteItem.from(TestFixtures.makeSong(id: "pending-finalization-source"))
        let targetItem = FavoriteItem.from(TestFixtures.makeSong(id: "pending-finalization-target"))

        FavoritesManager.shared.setActiveAccountScopeID(sourceScopeID)
        FavoritesManager.shared.reset(with: [sourceItem])
        FavoritesManager.shared.setActiveAccountScopeID(targetScopeID)
        FavoritesManager.shared.reset(with: [targetItem, sourceItem])
        FavoritesManager.shared.setActiveAccountScopeID(nil)

        let state: [String: Any] = [
            "ownerIDsByAliasID": ["opaque-alias": targetOwnerID],
            "accountIDsByOwnerID": [targetOwnerID: [accountID]],
            "emailAliasIDs": [],
            "pendingFinalizations": [[
                "sourceOwnerID": sourceOwnerID,
                "targetOwnerID": targetOwnerID,
                "accountIDs": [accountID],
            ]],
        ]
        try defaults.set(JSONSerialization.data(withJSONObject: state), forKey: "favorites.ownerState")

        _ = Self.createService(favoritesOwnerDefaults: defaults)

        FavoritesManager.shared.setActiveAccountScopeID(sourceScopeID)
        #expect(FavoritesManager.shared.items.isEmpty)
        FavoritesManager.shared.setActiveAccountScopeID(targetScopeID)
        #expect(FavoritesManager.shared.isPinned(contentId: sourceItem.contentId))
        #expect(FavoritesManager.shared.isPinned(contentId: targetItem.contentId))

        let persistedData = try #require(defaults.data(forKey: "favorites.ownerState"))
        let persistedJSON = try #require(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        let pendingFinalizations = try #require(
            persistedJSON["pendingFinalizations"] as? [[String: Any]]
        )
        #expect(pendingFinalizations.isEmpty)
    }

    @Test @MainActor func staleAccountFetchCannotCommitAfterReauthentication() async {
        let services = Self.createService()
        services.auth.completeLogin(sapisid: "first-session")

        let firstPrimary = UserAccount.from(
            name: "First User",
            handle: "@first",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        services.client.accountsListStartedGate = requestStarted
        services.client.accountsListReleaseGate = releaseRequest
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "first@example.test",
            accounts: [firstPrimary]
        )

        let staleFetch = Task { @MainActor in
            await services.account.fetchAccounts()
        }
        await requestStarted.wait()

        services.auth.sessionExpired()
        services.auth.completeLogin(sapisid: "second-session")
        await releaseRequest.open()
        await staleFetch.value

        #expect(services.account.accounts.isEmpty)
        #expect(services.account.currentAccount == nil)
        #expect(services.account.currentFavoritesScopeID == nil)
    }

    @Test @MainActor func staleAccountFetchCannotPublishWhileBoundaryDrainIsPending() async {
        let services = Self.createService()
        services.auth.completeLogin(sapisid: "first-session")
        let drainStarted = AsyncGate()
        let releaseDrain = AsyncGate()
        let primary = UserAccount.from(
            name: "First User",
            handle: "@first",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: true
        )
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "first@example.test",
            accounts: [primary]
        )
        services.account.setAccountBoundaryHandlers(
            willBegin: {},
            didEnd: {},
            drain: {
                await drainStarted.open()
                await releaseDrain.wait()
            }
        )

        let staleFetch = Task { @MainActor in
            await services.account.fetchAccounts()
        }
        await drainStarted.wait()
        #expect(services.account.accounts.isEmpty)
        #expect(services.account.currentAccount == nil)

        services.auth.sessionExpired()
        services.auth.completeLogin(sapisid: "second-session")
        await releaseDrain.open()
        await staleFetch.value

        #expect(services.account.accounts.isEmpty)
        #expect(services.account.currentAccount == nil)
        #expect(services.account.currentFavoritesScopeID == nil)
    }

    @Test @MainActor func sameAccountRefreshDoesNotOpenMutationBoundary() async {
        let services = Self.createService()
        let begins = LockedCounter()
        let ends = LockedCounter()
        let primary = MockUserAccountData.primaryAccount
        await Self.populateAccounts(services, accounts: [primary])
        services.account.setAccountBoundaryHandlers(
            willBegin: { begins.increment() },
            didEnd: { ends.increment() },
            drain: {}
        )

        await services.account.fetchAccounts()

        #expect(services.account.currentAccount?.id == primary.id)
        #expect(begins.isEmpty)
        #expect(ends.isEmpty)
    }

    @Test @MainActor func switchAccountUpdatesCurrentAccount() async throws {
        let services = Self.createService()

        let primaryAccount = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        #expect(services.account.currentAccount == primaryAccount)

        try await services.account.switchAccount(to: brandAccount)

        #expect(services.account.currentAccount == brandAccount)
        #expect(services.account.currentBrandId == brandAccount.brandId)
        #expect(SongLikeStatusManager.shared.activeAccountID == brandAccount.id)
        #expect(services.client.resetSessionStateForAccountSwitchCalled == true)
    }

    @Test @MainActor func switchAccountToSameAccountIsNoOp() async throws {
        let services = Self.createService()

        let primaryAccount = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        await Self.populateAccounts(services, accounts: [primaryAccount])

        try await services.account.switchAccount(to: primaryAccount)

        #expect(services.account.currentAccount == primaryAccount)
    }

    @Test @MainActor func sameAccountWithSigninURLRemainsSelected() async throws {
        let services = Self.createService(webKitManager: MockWebKitManager())

        let primaryAccount = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        await Self.populateAccounts(services, accounts: [primaryAccount])

        try await services.account.switchAccount(to: primaryAccount)

        #expect(services.account.currentAccount == primaryAccount)
    }

    @Test @MainActor func sameAccountSwitchRetriesUnverifiedSessionIdentity() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        mockWebKit.switchSessionIdentityErrorQueue = [
            SessionSwitchError.identityNotApplied(expectedBrandId: nil),
            nil,
        ]
        await Self.populateAccounts(services, accounts: [primaryAccount])
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.account.currentAccount?.id == primaryAccount.id)
        #expect(services.account.verifiedAccountId == nil)

        try await services.account.switchAccount(to: primaryAccount)

        #expect(mockWebKit.switchSessionIdentityCallCount == 2)
        #expect(mockWebKit.switchSessionIdentityCompletedBrandIds == [nil])
        #expect(services.account.verifiedAccountId == primaryAccount.id)
    }

    @Test @MainActor func switchAccountVerifiesSessionIdentityWithBrandId() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brandAccount = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        try await services.account.switchAccount(to: brandAccount)

        #expect(mockWebKit.switchSessionIdentityCalled == true)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [brandAccount.brandId])
        #expect(services.account.currentAccount == brandAccount)
    }

    @Test @MainActor func accountTransitionPreparationRunsBeforeSessionNavigation() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let begins = LockedCounter()
        let ends = LockedCounter()
        let drainStarted = AsyncGate()
        let releaseDrain = AsyncGate()
        let primary = MockUserAccountData.primaryAccount
        let brand = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primary, brand])

        services.account.setAccountBoundaryHandlers(
            willBegin: { begins.increment() },
            didEnd: { ends.increment() },
            drain: {
                await drainStarted.open()
                await releaseDrain.wait()
            }
        )
        mockWebKit.switchSessionIdentityGate = {
            #expect(begins.count > ends.count)
        }

        let switchTask = Task {
            try await services.account.switchAccount(to: brand)
        }
        await drainStarted.wait()
        #expect(!mockWebKit.switchSessionIdentityCalled)
        await releaseDrain.open()
        try await switchTask.value

        #expect(begins.count >= 1)
        #expect(ends.count == begins.count)
        #expect(mockWebKit.switchSessionIdentityCompletedBrandIds == [brand.brandId])
    }

    @Test @MainActor func failedSessionSwitchRevertsToPreviousAccount() async throws {
        let mockWebKit = MockWebKitManager()
        mockWebKit.switchSessionIdentityError = SessionSwitchError.identityNotApplied(expectedBrandId: "x")
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brandAccount = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])
        #expect(services.account.currentAccount == primaryAccount)

        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: brandAccount)
        }
        #expect(services.account.currentAccount == primaryAccount)
        #expect(services.account.currentBrandId == nil)
    }

    @Test @MainActor func failedSwitchRollsSessionBackToPreviousIdentity() async throws {
        let previous = MockUserAccountData.brandAccountWithSigninURL
        let target = UserAccount.from(
            name: "Other Brand", handle: "@other", brandId: "222222222222222222222",
            thumbnailURL: nil, isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?pageid=222222222222222222222&authuser=0&next=%2F")
        )
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        await Self.populateAccounts(services, accounts: [previous, target], selectedIndex: 0)
        #expect(services.account.currentAccount?.id == previous.id)

        mockWebKit.switchSessionIdentityErrorQueue = [SessionSwitchError.identityNotApplied(expectedBrandId: target.brandId), nil]

        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: target)
        }

        #expect(services.account.currentAccount?.id == previous.id)
        #expect(mockWebKit.switchSessionIdentityCallCount >= 2)
        #expect(Array(mockWebKit.switchSessionIdentityExpectedBrandIds.prefix(2)) == [target.brandId, previous.brandId])
        #expect(mockWebKit.switchSessionIdentityURLs.dropFirst().first == previous.signinURL)
    }

    @Test @MainActor func failedRollbackClearsVerifiedIdentity() async throws {
        let previous = MockUserAccountData.brandAccountWithSigninURL
        let target = UserAccount.from(
            name: "Other Brand", handle: "@other", brandId: "222222222222222222222",
            thumbnailURL: nil, isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?pageid=222222222222222222222&authuser=0&next=%2F")
        )
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        await Self.populateAccounts(services, accounts: [previous, target], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        #expect(services.account.verifiedAccountId == previous.id)

        mockWebKit.reset()
        mockWebKit.switchSessionIdentityErrorQueue = [
            SessionSwitchError.identityNotApplied(expectedBrandId: target.brandId),
            SessionSwitchError.identityNotApplied(expectedBrandId: previous.brandId),
        ]
        services.client.shouldThrowError = YTMusicError.apiError(message: "refresh disabled", code: nil)

        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: target)
        }

        #expect(services.account.currentAccount?.id == previous.id)
        #expect(services.account.verifiedAccountId == nil)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [target.brandId, previous.brandId])
    }

    @Test @MainActor func failedSwitchRollbackUsesFreshPreviousSigninURL() async throws {
        let stalePrevious = UserAccount.from(
            name: "Previous", handle: "@previous", brandId: "111111111111111111111",
            thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?pageid=111111111111111111111&stale=1")
        )
        let freshPrevious = UserAccount.from(
            name: "Previous", handle: "@previous", brandId: "111111111111111111111",
            thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?pageid=111111111111111111111&fresh=1")
        )
        let target = UserAccount.from(
            name: "Target", handle: "@target", brandId: "222222222222222222222",
            thumbnailURL: nil, isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?pageid=222222222222222222222&authuser=0&next=%2F")
        )
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        await Self.populateAccounts(services, accounts: [stalePrevious, target], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        mockWebKit.reset()
        services.client.accountsListResponse = AccountsListResponse(googleEmail: "t@gmail.com", accounts: [freshPrevious, target])
        mockWebKit.switchSessionIdentityErrorQueue = [
            SessionSwitchError.identityNotApplied(expectedBrandId: target.brandId),
            nil,
        ]

        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: target)
        }

        #expect(mockWebKit.switchSessionIdentityURLs == [target.signinURL, freshPrevious.signinURL])
        #expect(services.account.currentAccount?.signinURL == freshPrevious.signinURL)
        #expect(services.account.verifiedAccountId == freshPrevious.id)
    }

    @Test @MainActor func prepareForSignOutCancelsInFlightSessionMutation() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primary, brand], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        mockWebKit.reset()

        let gate = AsyncReleaseGate()
        mockWebKit.switchSessionIdentityGate = { await gate.wait() }
        async let switching: Void = services.account.switchAccount(to: brand)
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount < 1 {
            await Task.yield()
        }
        guard mockWebKit.switchSessionIdentityCallCount >= 1 else {
            Issue.record("Expected switch navigation to start")
            await gate.release()
            try? await switching
            return
        }

        await services.account.prepareForSignOut()
        try? await switching

        #expect(mockWebKit.switchSessionIdentityCompletedBrandIds.isEmpty)
    }

    @Test @MainActor func prepareForSignOutAwaitsPriorIdentityDrain() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let primary = MockUserAccountData.primaryAccount
        let brand = MockUserAccountData.brandAccountWithSigninURL
        UserDefaults.standard.set(brand.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        let oldPinGate = AsyncGate()
        mockWebKit.switchSessionIdentityGate = { await oldPinGate.wait() }
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "old@example.test",
            accounts: [primary, brand]
        )
        services.auth.completeLogin(sapisid: "old-session")
        await services.account.fetchAccounts()
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount == 0 {
            await Task.yield()
        }

        let signOutFlow = Task { @MainActor in
            _ = await services.auth.signOut()
        }
        await Task.yield()
        #expect(mockWebKit.clearAllDataCalled == false)

        await oldPinGate.open()
        _ = await signOutFlow.value

        #expect(mockWebKit.clearAllDataCalled == true)
        #expect(services.auth.state == .loggedOut)
    }

    @Test @MainActor func prepareForSignOutBlocksNewSessionMutationWhileDraining() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let primary = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil,
            thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL
        UserDefaults.standard.set(brand.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        let oldPinGate = AsyncGate()
        mockWebKit.switchSessionIdentityGate = { await oldPinGate.wait() }
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [primary, brand]
        )
        services.auth.completeLogin(sapisid: "active-session")
        await services.account.fetchAccounts()
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount == 0 {
            await Task.yield()
        }
        guard mockWebKit.switchSessionIdentityCallCount == 1 else {
            Issue.record("Expected restored session pin to start")
            await oldPinGate.open()
            return
        }

        let preparation = Task { @MainActor in
            await services.account.prepareForSignOut()
        }
        await Task.yield()
        let lateSwitch = Task { @MainActor in
            try? await services.account.switchAccount(to: primary)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        #expect(mockWebKit.switchSessionIdentityCallCount == 1)

        await oldPinGate.open()
        await preparation.value
        await lateSwitch.value

        #expect(mockWebKit.switchSessionIdentityCallCount == 1)
        #expect(services.account.currentAccount?.id == brand.id)
    }

    @Test @MainActor func prepareForReauthenticationAwaitsPriorIdentityDrain() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let primary = MockUserAccountData.primaryAccount
        let brand = MockUserAccountData.brandAccountWithSigninURL
        UserDefaults.standard.set(brand.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        let oldPinGate = AsyncGate()
        mockWebKit.switchSessionIdentityGate = { await oldPinGate.wait() }
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [primary, brand]
        )
        services.auth.completeLogin(sapisid: "expired-session")
        await services.account.fetchAccounts()
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount == 0 {
            await Task.yield()
        }

        services.auth.sessionExpired()
        let reauthenticationPreparation = Task { @MainActor in
            await services.account.prepareForReauthentication()
            _ = await mockWebKit.beginLoginCookieBackup()
        }
        await Task.yield()
        #expect(mockWebKit.beginLoginCookieBackupCallCount == 0)

        await oldPinGate.open()
        await reauthenticationPreparation.value

        #expect(mockWebKit.beginLoginCookieBackupCallCount == 1)
    }

    @Test @MainActor func newerSwitchCancelsFailedSwitchRollbackNavigation() async throws {
        let previous = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil,
            thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let target = MockUserAccountData.brandAccountWithSigninURL
        let newer = UserAccount.from(
            name: "Newer Brand", handle: "@newer", brandId: "222222222222222222222",
            thumbnailURL: nil, isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?pageid=222222222222222222222&authuser=0&next=%2F")
        )
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        await Self.populateAccounts(services, accounts: [previous, target, newer], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        mockWebKit.reset()

        let rollbackGate = AsyncReleaseGate()
        mockWebKit.switchSessionIdentityGateQueue = [nil, { await rollbackGate.wait() }, nil]
        mockWebKit.switchSessionIdentityErrorQueue = [
            SessionSwitchError.identityNotApplied(expectedBrandId: target.brandId),
            nil,
            nil,
        ]

        let failedSwitch = Task { @MainActor in
            try await services.account.switchAccount(to: target)
        }
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount < 2 {
            await Task.yield()
        }
        guard mockWebKit.switchSessionIdentityCallCount >= 2 else {
            Issue.record("Expected rollback navigation to start")
            await rollbackGate.release()
            try? await failedSwitch.value
            return
        }

        try await services.account.switchAccount(to: newer)

        #expect(services.account.currentAccount?.id == newer.id)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [target.brandId, previous.brandId, newer.brandId])
        #expect(mockWebKit.switchSessionIdentityCompletedBrandIds == [newer.brandId])

        await rollbackGate.release()
        await #expect(throws: CancellationError.self) {
            try await failedSwitch.value
        }
        #expect(mockWebKit.switchSessionIdentityCompletedBrandIds == [newer.brandId])
    }

    @Test @MainActor func preSwitchFailureDoesNotRollBackSession() async throws {
        let previous = MockUserAccountData.brandAccountWithSigninURL
        let target = UserAccount.from(
            name: "Other Brand", handle: "@other", brandId: "222222222222222222222",
            thumbnailURL: nil, isSelected: false
        )
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        await Self.populateAccounts(services, accounts: [previous, target], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        mockWebKit.reset()

        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: target)
        }
        #expect(mockWebKit.switchSessionIdentityCallCount == 0)
        #expect(services.account.currentAccount?.id == previous.id)
    }

    @Test @MainActor func manualSwitchCancelsInFlightLaunchPinAndWinsLast() async throws {
        let mockWebKit = MockWebKitManager()
        let released = AsyncReleaseGate()
        mockWebKit.switchSessionIdentityGate = { await released.wait() }
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL
        UserDefaults.standard.set(brand.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }
        services.client.accountsListResponse = AccountsListResponse(googleEmail: "t@gmail.com", accounts: [primary, brand])
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()

        mockWebKit.switchSessionIdentityGate = nil
        try await services.account.switchAccount(to: primary)
        await released.release()

        #expect(services.account.currentAccount?.id == primary.id)
        #expect(mockWebKit.switchSessionIdentityURLs.last == primary.signinURL)
    }

    @Test @MainActor func supersededSwitchAbandonsItsCommit() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brandA = MockUserAccountData.brandAccountWithSigninURL
        let brandB = UserAccount.from(
            name: "Brand B", handle: "@b", brandId: "222222222222222222222",
            thumbnailURL: nil, isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?pageid=222222222222222222222&authuser=0&next=%2F")
        )
        await Self.populateAccounts(services, accounts: [primary, brandA, brandB], selectedIndex: 0)
        await Self.waitForSwitchSessionIdentityCompletions(mockWebKit, count: 1)
        mockWebKit.reset()

        let releaseA = AsyncReleaseGate()
        mockWebKit.switchSessionIdentityGateQueue = [{ await releaseA.wait() }, nil]
        async let firstSwitch: Void = services.account.switchAccount(to: brandA)
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount < 1 {
            await Task.yield()
        }
        guard mockWebKit.switchSessionIdentityCallCount >= 1 else {
            Issue.record("Expected first switch navigation to start")
            await releaseA.release()
            try? await firstSwitch
            return
        }

        try await services.account.switchAccount(to: brandB)
        #expect(services.account.currentAccount?.id == brandB.id)

        await releaseA.release()
        try? await firstSwitch

        #expect(services.account.currentAccount?.id == brandB.id)
    }

    @Test @MainActor func logoutAbandonsInFlightSwitch() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primary, brand], selectedIndex: 0)

        let release = AsyncReleaseGate()
        let callsBeforeSwitch = mockWebKit.switchSessionIdentityCallCount
        mockWebKit.switchSessionIdentityGate = { await release.wait() }
        async let switching: Void = services.account.switchAccount(to: brand)
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount <= callsBeforeSwitch {
            await Task.yield()
        }
        guard mockWebKit.switchSessionIdentityCallCount > callsBeforeSwitch else {
            Issue.record("Expected switch navigation to start")
            await release.release()
            try? await switching
            return
        }

        services.account.clearAccounts()
        await release.release()
        try? await switching

        #expect(services.account.currentAccount == nil)
        #expect(services.account.accounts.isEmpty)
    }

    @Test @MainActor func passiveFetchDoesNotAbandonInFlightSwitch() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primary, brand], selectedIndex: 0)

        let release = AsyncReleaseGate()
        mockWebKit.switchSessionIdentityGate = { await release.wait() }
        async let switching: Void = services.account.switchAccount(to: brand)
        await Task.yield()

        services.client.accountsListResponse = AccountsListResponse(googleEmail: "t@gmail.com", accounts: [primary, brand])
        await services.account.fetchAccounts()
        mockWebKit.switchSessionIdentityGate = nil
        await release.release()
        try await switching

        #expect(services.account.currentAccount?.id == brand.id)
    }

    @Test @MainActor func passiveFetchDoesNotStartRestorePinDuringManualSwitch() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let brandA = MockUserAccountData.brandAccountWithSigninURL
        let brandB = UserAccount.from(
            name: "Brand B", handle: "@b", brandId: "222222222222222222222",
            thumbnailURL: nil, isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?pageid=222222222222222222222&authuser=0&next=%2F")
        )
        await Self.populateAccounts(services, accounts: [brandA, brandB], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        mockWebKit.reset()
        UserDefaults.standard.set(brandA.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        let switchGate = AsyncReleaseGate()
        let stalePinGate = AsyncReleaseGate()
        mockWebKit.switchSessionIdentityGateQueue = [{ await switchGate.wait() }, { await stalePinGate.wait() }]
        async let switching: Void = services.account.switchAccount(to: brandB)
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount < 1 {
            await Task.yield()
        }
        guard mockWebKit.switchSessionIdentityCallCount >= 1 else {
            Issue.record("Expected manual switch navigation to start")
            await switchGate.release()
            try? await switching
            return
        }

        services.client.accountsListResponse = AccountsListResponse(googleEmail: "t@gmail.com", accounts: [brandA, brandB])
        await services.account.fetchAccounts()

        #expect(mockWebKit.switchSessionIdentityCallCount == 1)

        await switchGate.release()
        try await switching
        await stalePinGate.release()
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.account.currentAccount?.id == brandB.id)
        #expect(services.account.verifiedAccountId == brandB.id)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [brandB.brandId])
        #expect(mockWebKit.switchSessionIdentityCompletedBrandIds == [brandB.brandId])
    }

    @Test @MainActor func authBoundaryFetchRunsAfterOldManualSwitchUnwinds() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let oldPrimary = UserAccount.from(
            name: "Old Primary", handle: "@old", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let oldBrand = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [oldPrimary, oldBrand], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        services.client.reset()
        mockWebKit.reset()

        let switchGate = AsyncReleaseGate()
        mockWebKit.switchSessionIdentityGate = { await switchGate.wait() }
        let oldSwitch = Task { @MainActor in
            try? await services.account.switchAccount(to: oldBrand)
        }
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount == 0 {
            await Task.yield()
        }

        services.auth.sessionExpired()
        services.account.authenticationIdentityDidChange()
        services.account.clearAccounts()
        services.auth.completeLogin(sapisid: "new-session")
        let newPrimary = UserAccount.from(
            name: "New Primary", handle: "@new", brandId: nil, thumbnailURL: nil, isSelected: true
        )
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "new@example.test",
            accounts: [newPrimary]
        )

        await services.account.fetchAccounts()
        #expect(services.client.fetchAccountsListCallCount == 0)

        await switchGate.release()
        await oldSwitch.value
        for _ in 0 ..< 100 where services.client.fetchAccountsListCallCount == 0 {
            await Task.yield()
        }
        for _ in 0 ..< 100 where services.account.currentAccount?.name != newPrimary.name {
            await Task.yield()
        }

        #expect(services.client.fetchAccountsListCallCount == 1)
        #expect(services.account.currentAccount?.name == newPrimary.name)
    }

    @Test @MainActor func authBoundaryFetchWaitsForOldPassivePinToDrain() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let oldPrimary = MockUserAccountData.primaryAccount
        let oldBrand = MockUserAccountData.brandAccountWithSigninURL
        UserDefaults.standard.set(oldBrand.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        let oldPinGate = AsyncGate()
        mockWebKit.switchSessionIdentityGate = { await oldPinGate.wait() }
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "old@example.test",
            accounts: [oldPrimary, oldBrand]
        )
        services.auth.completeLogin(sapisid: "old-session")
        await services.account.fetchAccounts()
        for _ in 0 ..< 100 where mockWebKit.switchSessionIdentityCallCount == 0 {
            await Task.yield()
        }
        let oldFetchCount = services.client.fetchAccountsListCallCount

        services.auth.sessionExpired()
        services.account.authenticationIdentityDidChange()
        services.auth.completeLogin(sapisid: "new-session")
        let newPrimary = UserAccount.from(
            name: "New Primary", handle: "@new", brandId: nil, thumbnailURL: nil, isSelected: true
        )
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "new@example.test",
            accounts: [newPrimary]
        )

        let newFetch = Task { @MainActor in
            await services.account.fetchAccounts()
        }
        await Task.yield()
        #expect(services.client.fetchAccountsListCallCount == oldFetchCount)

        await oldPinGate.open()
        await newFetch.value

        #expect(services.client.fetchAccountsListCallCount == oldFetchCount + 1)
        #expect(services.account.currentAccount?.name == newPrimary.name)
    }

    @Test @MainActor func staleAccountValueUsesCurrentSnapshotMetadata() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let stalePrimary = UserAccount.from(
            name: "Old Primary", handle: "@old", brandId: nil,
            thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2Fold")
        )
        services.auth.completeLogin(sapisid: "old-session")
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "old@example.test",
            accounts: [stalePrimary]
        )
        await services.account.fetchAccounts()
        await services.account.awaitRestoredSessionPinForTesting()

        services.auth.sessionExpired()
        services.account.authenticationIdentityDidChange()
        services.auth.completeLogin(sapisid: "new-session")
        let currentPrimary = UserAccount.from(
            name: "New Primary", handle: "@new", brandId: nil,
            thumbnailURL: nil, isSelected: true, signinURL: nil
        )
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "new@example.test",
            accounts: [currentPrimary]
        )
        await services.account.fetchAccounts()
        mockWebKit.reset()

        try await services.account.switchAccount(to: stalePrimary)

        #expect(services.account.currentAccount?.name == currentPrimary.name)
        #expect(mockWebKit.switchSessionIdentityCallCount == 0)
    }

    @Test @MainActor func guardedAccountSwitchesThrowCancellation() async throws {
        let primary = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil,
            thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL

        let boundaryServices = Self.createService(webKitManager: MockWebKitManager())
        await Self.populateAccounts(boundaryServices, accounts: [primary, brand], selectedIndex: 0)
        await boundaryServices.account.awaitRestoredSessionPinForTesting()
        await boundaryServices.account.prepareForSignOut()
        await #expect(throws: CancellationError.self) {
            try await boundaryServices.account.switchAccount(to: brand)
        }

        let staleServices = Self.createService(webKitManager: MockWebKitManager())
        await Self.populateAccounts(staleServices, accounts: [primary, brand], selectedIndex: 0)
        await staleServices.account.awaitRestoredSessionPinForTesting()
        staleServices.auth.sessionExpired()
        staleServices.auth.completeLogin(sapisid: "replacement-session")
        await #expect(throws: CancellationError.self) {
            try await staleServices.account.switchAccount(to: brand)
        }
    }

    @Test @MainActor func guestModeCanSwitchAccountAtomically() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let primary = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil,
            thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primary, brand], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        mockWebKit.reset()

        await services.auth.enterGuestMode()
        #expect(services.auth.isGuestModeEnabled)

        try await services.account.switchAccount(to: brand)
        #expect(services.account.currentAccount?.id == brand.id)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [brand.brandId])
        #expect(!services.auth.isGuestModeEnabled)
        #expect(SongLikeStatusManager.shared.activeAccountID == brand.id)
        #expect(FavoritesManager.shared.activeScopeID == services.account.currentFavoritesScopeID)
    }

    @Test @MainActor func guestModeFailedSwitchKeepsGuestScopes() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let primary = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil,
            thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primary, brand], selectedIndex: 0)
        await services.account.awaitRestoredSessionPinForTesting()
        mockWebKit.reset()
        mockWebKit.switchSessionIdentityErrorQueue = [
            SessionSwitchError.identityNotApplied(expectedBrandId: brand.brandId),
            nil,
        ]

        await services.auth.enterGuestMode()
        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: brand)
        }

        #expect(services.auth.isGuestModeEnabled)
        #expect(services.account.currentAccount?.id == primary.id)
        #expect(SongLikeStatusManager.shared.activeAccountID == SongLikeStatusManager.guestAccountID)
        #expect(FavoritesManager.shared.activeScopeID != services.account.currentFavoritesScopeID)
    }

    @Test @MainActor func switchAccountWithoutSigninURLFailsSafely() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: brandAccount)
        }
        #expect(services.account.currentAccount == primaryAccount)
    }

    @Test @MainActor func restoringBrandAccountOnLaunchPinsSession() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccountWithSigninURL
        UserDefaults.standard.set(brandAccount.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "test@gmail.com",
            accounts: [primaryAccount, brandAccount]
        )
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.account.currentAccount?.id == brandAccount.id)
        #expect(mockWebKit.switchSessionIdentityCalled == true)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [brandAccount.brandId])
    }

    @Test @MainActor func failedRestoredBrandSessionPinFallsBackToPrimary() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brandAccount = MockUserAccountData.brandAccountWithSigninURL
        UserDefaults.standard.set(brandAccount.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        mockWebKit.switchSessionIdentityErrorQueue = [
            SessionSwitchError.identityNotApplied(expectedBrandId: brandAccount.brandId),
            nil,
        ]
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "test@gmail.com",
            accounts: [primaryAccount, brandAccount]
        )
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.account.currentAccount?.id == primaryAccount.id)
        #expect(services.account.verifiedAccountId == primaryAccount.id)
        #expect(services.account.lastError != nil)
        #expect(SongLikeStatusManager.shared.activeAccountID == primaryAccount.id)
    }

    @Test @MainActor func staleRestoredBrandFallbackCannotRecreateSignedOutSession() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        let fallbackDrainStarted = AsyncGate()
        let releaseFallbackDrain = AsyncGate()
        let drainCount = LockedCounter()
        let primaryAccount = UserAccount.from(
            name: "Primary", handle: "@primary", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://example.com/mock-signin")
        )
        let brandAccount = MockUserAccountData.brandAccountWithSigninURL
        UserDefaults.standard.set(brandAccount.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        services.account.setAccountBoundaryHandlers(
            willBegin: {},
            didEnd: {},
            drain: {
                drainCount.increment()
                if drainCount.count == 3 {
                    await fallbackDrainStarted.open()
                    await releaseFallbackDrain.wait()
                }
            }
        )
        mockWebKit.switchSessionIdentityErrorQueue = [
            SessionSwitchError.identityNotApplied(expectedBrandId: brandAccount.brandId),
            nil,
        ]
        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "test@gmail.com",
            accounts: [primaryAccount, brandAccount]
        )
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()
        await fallbackDrainStarted.wait()

        services.auth.sessionExpired()
        await releaseFallbackDrain.open()
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.auth.state == .loggedOut)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [brandAccount.brandId])
        #expect(services.account.currentAccount?.id == brandAccount.id)
        #expect(services.account.verifiedAccountId == nil)
    }

    @Test @MainActor func restoredBrandWithoutSigninURLFallsBackToPrimary() async {
        let services = Self.createService(webKitManager: MockWebKitManager())

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        UserDefaults.standard.set(brandAccount.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "test@gmail.com",
            accounts: [primaryAccount, brandAccount]
        )
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.account.currentAccount?.id == primaryAccount.id)
        #expect(services.account.verifiedAccountId == nil)
        #expect(services.account.lastError != nil)
        #expect(SongLikeStatusManager.shared.activeAccountID == primaryAccount.id)
    }

    @Test @MainActor func switchBackToPrimaryVerifiesSessionWithWebKit() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = UserAccount.from(
            name: "Primary",
            handle: "@primary",
            brandId: nil,
            thumbnailURL: nil,
            isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brandAccount = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount], selectedIndex: 1)
        #expect(services.account.currentAccount?.id == brandAccount.id)

        try await services.account.switchAccount(to: primaryAccount)
        #expect(services.account.currentAccount?.id == primaryAccount.id)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds.last == .some(nil))
    }

    @Test @MainActor func restoringPrimaryAccountWithoutSigninURLDoesNotPinSession() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = MockUserAccountData.primaryAccount
        UserDefaults.standard.removeObject(forKey: "selectedBrandId")

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "test@gmail.com",
            accounts: [primaryAccount]
        )
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()

        #expect(mockWebKit.switchSessionIdentityCalled == false)
    }

    @Test @MainActor func restoringPrimaryAccountWithSigninURLPinsSession() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        UserDefaults.standard.set("primary", forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        services.client.accountsListResponse = AccountsListResponse(googleEmail: "t@gmail.com", accounts: [primary])
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.account.currentAccount?.id == "primary")
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [nil])
        #expect(services.account.verifiedAccountId == "primary")
    }

    @Test @MainActor func failedRestoredPrimarySessionPinSurfacesError() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        mockWebKit.switchSessionIdentityError = SessionSwitchError.identityNotApplied(expectedBrandId: nil)

        services.client.accountsListResponse = AccountsListResponse(googleEmail: "t@gmail.com", accounts: [primary])
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.account.currentAccount?.id == "primary")
        #expect(services.account.verifiedAccountId == nil)
        #expect(services.account.lastError != nil)
    }

    @Test @MainActor func restoredBrandVanishedRePinsPrimary() async {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: true,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        UserDefaults.standard.set("999999999999999999999", forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        services.client.accountsListResponse = AccountsListResponse(googleEmail: "t@gmail.com", accounts: [primary])
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()
        await services.account.awaitRestoredSessionPinForTesting()

        #expect(services.account.currentAccount?.id == "primary")
        #expect(mockWebKit.switchSessionIdentityCalled == true)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [nil])
    }

    @Test @MainActor func switchAccountUpdatesBrandId() async throws {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        #expect(services.account.currentBrandId == nil)

        try await services.account.switchAccount(to: brandAccount)

        #expect(services.account.currentBrandId == brandAccount.brandId)
        #expect(services.account.currentBrandId == "123456789012345678901")
    }

    @Test @MainActor func switchAccountPersistsSelection() async throws {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        try await services.account.switchAccount(to: brandAccount)

        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == brandAccount.id)

        UserDefaults.standard.removeObject(forKey: "selectedBrandId")
    }

    @Test @MainActor func switchToPrimaryAccountPersistsPrimaryId() async throws {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount], selectedIndex: 1)

        try await services.account.switchAccount(to: primaryAccount)

        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == "primary")

        UserDefaults.standard.removeObject(forKey: "selectedBrandId")
    }

    @Test @MainActor func clearAccountsResetsState() async {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        UserDefaults.standard.set("primary", forKey: "selectedBrandId")

        services.account.clearAccounts()

        #expect(services.account.accounts.isEmpty)
        #expect(services.account.currentAccount == nil)
        #expect(services.account.hasBrandAccounts == false)
        #expect(services.account.currentBrandId == nil)

        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == nil)
        #expect(SongLikeStatusManager.shared.activeAccountID == "primary")
        #expect(SongLikeStatusManager.shared.status(for: "cached-video") == nil)
    }

    @Test @MainActor func cancelledAccountFetchDoesNotResolveOrPublishError() async {
        let services = Self.createService()

        services.client.shouldThrowError = CancellationError()
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()

        #expect(services.account.didCompleteAccountResolution == false)
        #expect(services.account.lastError == nil)
        #expect(services.account.isLoading == false)
    }

    @Test @MainActor func clearErrorResetsLastError() async {
        let services = Self.createService()

        services.client.shouldThrowError = YTMusicError.apiError(message: "Test error", code: nil)
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()

        #expect(services.account.lastError != nil)
        #expect(services.account.didCompleteAccountResolution == true)

        services.account.clearError()

        #expect(services.account.lastError == nil)
    }

    @Test @MainActor func currentBrandIdReturnsNilForPrimaryAccount() async {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        await Self.populateAccounts(services, accounts: [primaryAccount])

        #expect(services.account.currentBrandId == nil)
    }

    @Test @MainActor func currentBrandIdReturnsBrandIdForBrandAccount() async {
        let services = Self.createService()

        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [brandAccount], selectedIndex: 0)

        #expect(services.account.currentBrandId == "123456789012345678901")
    }

    @MainActor
    private static func createService(favoritesOwnerDefaults: UserDefaults? = nil) -> TestServices {
        let authService = AuthService()
        let mockClient = MockYTMusicClient()
        let service = AccountService(
            ytMusicClient: mockClient,
            authService: authService,
            favoritesOwnerDefaults: favoritesOwnerDefaults
        )
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        FavoritesManager.shared.setActiveAccountScopeID(nil)
        return TestServices(account: service, client: mockClient, auth: authService)
    }

    @MainActor
    private static func createService(webKitManager: MockWebKitManager) -> TestServices {
        let authService = AuthService(webKitManager: webKitManager)
        let mockClient = MockYTMusicClient()
        let service = AccountService(
            ytMusicClient: mockClient,
            authService: authService,
            webKitManager: webKitManager
        )
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        FavoritesManager.shared.setActiveAccountScopeID(nil)
        return TestServices(account: service, client: mockClient, auth: authService)
    }

    @MainActor
    private static func waitForSwitchSessionIdentityCompletions(
        _ mockWebKit: MockWebKitManager,
        count: Int
    ) async {
        for _ in 0 ..< 1000 {
            if mockWebKit.switchSessionIdentityCompletedBrandIds.count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for switch session identity completions")
    }

    @MainActor
    private static func populateAccounts(
        _ services: TestServices,
        accounts: [UserAccount],
        selectedIndex: Int = 0
    ) async {
        let accountsWithSelection = accounts.enumerated().map { index, account in
            UserAccount(
                id: account.id,
                name: account.name,
                handle: account.handle,
                brandId: account.brandId,
                thumbnailURL: account.thumbnailURL,
                isSelected: index == selectedIndex,
                signinURL: account.signinURL
            )
        }

        UserDefaults.standard.removeObject(forKey: "selectedBrandId")

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "test@gmail.com",
            accounts: accountsWithSelection
        )
        services.auth.completeLogin(sapisid: "test-sapisid")
        services.client.shouldThrowError = nil
        await services.account.fetchAccounts()
    }
}

private struct TestServices {
    let account: AccountService
    let client: MockYTMusicClient
    let auth: AuthService
}

private actor AsyncReleaseGate {
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        if self.released {
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.resumeWaiter(id) }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        if let continuation = self.waiters.removeValue(forKey: id) {
            continuation.resume()
        }
    }

    func release() {
        self.released = true
        let pending = self.waiters
        self.waiters = [:]
        for continuation in pending.values {
            continuation.resume()
        }
    }
}
