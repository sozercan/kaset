// AccountServiceTests.swift
// KasetTests
//
// Tests for AccountService using Swift Testing framework.

import Foundation
import Testing
@testable import Kaset

// MARK: - AccountServiceTests

@Suite(.serialized)
struct AccountServiceTests {
    // MARK: - Initial State Tests

    @Test @MainActor func initialStateIsEmpty() {
        let services = Self.createService()

        #expect(services.account.accounts.isEmpty)
        #expect(services.account.currentAccount == nil)
        #expect(services.account.hasBrandAccounts == false)
        #expect(services.account.currentBrandId == nil)
        #expect(services.account.isLoading == false)
        #expect(services.account.lastError == nil)
    }

    @Test @MainActor func hasBrandAccountsReturnsFalseForSingleAccount() async {
        let services = Self.createService()

        // Populate with single account via fetchAccounts
        await Self.populateAccounts(services, accounts: [MockUserAccountData.primaryAccount])

        #expect(services.account.hasBrandAccounts == false)
    }

    @Test @MainActor func hasBrandAccountsReturnsTrueForMultipleAccounts() async {
        let services = Self.createService()

        // Populate with multiple accounts via fetchAccounts
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

    // MARK: - Switch Account Tests

    @Test @MainActor func switchAccountUpdatesCurrentAccount() async throws {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        #expect(services.account.currentAccount == primaryAccount)

        // Switch to brand account
        try await services.account.switchAccount(to: brandAccount)

        #expect(services.account.currentAccount == brandAccount)
        #expect(services.account.currentBrandId == brandAccount.brandId)
        #expect(SongLikeStatusManager.shared.activeAccountID == brandAccount.id)
        #expect(services.client.resetSessionStateForAccountSwitchCalled == true)
    }

    @Test @MainActor func switchAccountToSameAccountIsNoOp() async throws {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        await Self.populateAccounts(services, accounts: [primaryAccount])

        // Attempt to switch to the same account
        try await services.account.switchAccount(to: primaryAccount)

        // Should still be the same account (no error thrown)
        #expect(services.account.currentAccount == primaryAccount)
    }

    // MARK: - Session-Switch Gating Tests

    @Test @MainActor func switchAccountVerifiesSessionIdentityWithBrandId() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        try await services.account.switchAccount(to: brandAccount)

        // The verified session switch must run, scoped to the brand's pageId.
        #expect(mockWebKit.switchSessionIdentityCalled == true)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [brandAccount.brandId])
        #expect(services.account.currentAccount == brandAccount)
    }

    @Test @MainActor func failedSessionSwitchRevertsToPreviousAccount() async throws {
        let mockWebKit = MockWebKitManager()
        mockWebKit.switchSessionIdentityError = SessionSwitchError.identityNotApplied(expectedBrandId: "x")
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccountWithSigninURL
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])
        #expect(services.account.currentAccount == primaryAccount)

        // The switch must throw and leave the previous account active so the user
        // is never silently recording history to the wrong account.
        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: brandAccount)
        }
        #expect(services.account.currentAccount == primaryAccount)
        #expect(services.account.currentBrandId == nil)
    }

    @Test @MainActor func failedSwitchRollsSessionBackToPreviousIdentity() async throws {
        // Previous account is a brand WITH a signinURL so a rollback is possible.
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

        // Forward switch verification fails; rollback (2nd call) succeeds.
        mockWebKit.switchSessionIdentityErrorQueue = [SessionSwitchError.identityNotApplied(expectedBrandId: target.brandId), nil]

        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: target)
        }

        // Native reverts AND the session is re-pinned to the previous identity.
        #expect(services.account.currentAccount?.id == previous.id)
        #expect(mockWebKit.switchSessionIdentityCallCount == 2)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [target.brandId, previous.brandId])
        #expect(mockWebKit.switchSessionIdentityURLs.last == previous.signinURL)
    }

    @Test @MainActor func preSwitchFailureDoesNotRollBackSession() async throws {
        // A target lacking signinURL throws BEFORE any session navigation, so no
        // rollback should run (the session was never touched).
        let previous = MockUserAccountData.brandAccountWithSigninURL
        let target = MockUserAccountData.brandAccount // no signinURL
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)
        await Self.populateAccounts(services, accounts: [previous, target], selectedIndex: 0)

        await #expect(throws: SessionSwitchError.self) {
            try await services.account.switchAccount(to: target)
        }
        #expect(mockWebKit.switchSessionIdentityCallCount == 0)
        #expect(services.account.currentAccount?.id == previous.id)
    }

    @Test @MainActor func manualSwitchCancelsInFlightLaunchPinAndWinsLast() async throws {
        let mockWebKit = MockWebKitManager()
        // Hold the launch pin in flight until released, so it overlaps the switch.
        let released = AsyncReleaseGate()
        mockWebKit.switchSessionIdentityGate = { await released.wait() }
        let services = Self.createService(webKitManager: mockWebKit)

        let primary = UserAccount.from(
            name: "Primary", handle: "@p", brandId: nil, thumbnailURL: nil, isSelected: false,
            signinURL: URL(string: "https://www.youtube.com/signin?authuser=0&next=%2F")
        )
        let brand = MockUserAccountData.brandAccountWithSigninURL
        // Cold-launch restore of the brand → schedules the gated launch pin.
        UserDefaults.standard.set(brand.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }
        services.client.accountsListResponse = AccountsListResponse(googleEmail: "t@gmail.com", accounts: [primary, brand])
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()

        // Now switch to primary while the launch pin is still gated. switchAccount
        // must cancel+await the pin (which returns via CancellationError) and then
        // run its own switch — so the LAST recorded URL is the primary's.
        mockWebKit.switchSessionIdentityGate = nil // the switch's own call runs ungated
        try await services.account.switchAccount(to: primary)
        await released.release()

        #expect(services.account.currentAccount?.id == primary.id)
        #expect(mockWebKit.switchSessionIdentityURLs.last == primary.signinURL)
    }

    @Test @MainActor func switchAccountWithoutSigninURLFailsSafely() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        let primaryAccount = MockUserAccountData.primaryAccount
        // Brand account lacking a signinURL cannot establish a verified session.
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
        // Simulate a relaunch with the brand account previously selected.
        UserDefaults.standard.set(brandAccount.id, forKey: "selectedBrandId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedBrandId") }

        services.client.accountsListResponse = AccountsListResponse(
            googleEmail: "test@gmail.com",
            accounts: [primaryAccount, brandAccount]
        )
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()
        // The pin runs off the fetch path; await it deterministically.
        await services.account.awaitRestoredBrandSessionPinForTesting()

        // The restored brand account must re-pin the WebView session so playback
        // records to the brand, not the primary, after a cold launch.
        #expect(services.account.currentAccount?.id == brandAccount.id)
        #expect(mockWebKit.switchSessionIdentityCalled == true)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds == [brandAccount.brandId])
    }

    @Test @MainActor func switchBackToPrimaryVerifiesSessionWithWebKit() async throws {
        let mockWebKit = MockWebKitManager()
        let services = Self.createService(webKitManager: mockWebKit)

        // Primary carries a signinURL too (verified against live accounts_list).
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

        // Switching back to primary must run a verified switch with nil brand
        // expectation (the primary identity) and succeed.
        try await services.account.switchAccount(to: primaryAccount)
        #expect(services.account.currentAccount?.id == primaryAccount.id)
        #expect(mockWebKit.switchSessionIdentityExpectedBrandIds.last == .some(nil))
    }

    @Test @MainActor func restoringPrimaryAccountDoesNotPinSession() async {
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

        // Primary is the default session identity; no switch navigation needed.
        #expect(mockWebKit.switchSessionIdentityCalled == false)
    }

    @Test @MainActor func switchAccountUpdatesBrandId() async throws {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        // Primary account should have nil brandId
        #expect(services.account.currentBrandId == nil)

        // Switch to brand account
        try await services.account.switchAccount(to: brandAccount)

        // Brand account should have brandId
        #expect(services.account.currentBrandId == brandAccount.brandId)
        #expect(services.account.currentBrandId == "123456789012345678901")
    }

    // MARK: - Persistence Tests

    @Test @MainActor func switchAccountPersistsSelection() async throws {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        // Switch to brand account
        try await services.account.switchAccount(to: brandAccount)

        // Verify UserDefaults was updated
        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == brandAccount.id)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "selectedBrandId")
    }

    @Test @MainActor func switchToPrimaryAccountPersistsPrimaryId() async throws {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        // First select the brand account via fetchAccounts
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount], selectedIndex: 1)

        // Switch back to primary account
        try await services.account.switchAccount(to: primaryAccount)

        // Verify UserDefaults has "primary" as the ID
        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == "primary")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "selectedBrandId")
    }

    // MARK: - Clear Accounts Tests

    @Test @MainActor func clearAccountsResetsState() async {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        await Self.populateAccounts(services, accounts: [primaryAccount, brandAccount])

        // Set a persisted selection
        UserDefaults.standard.set("primary", forKey: "selectedBrandId")

        // Clear accounts
        services.account.clearAccounts()

        #expect(services.account.accounts.isEmpty)
        #expect(services.account.currentAccount == nil)
        #expect(services.account.hasBrandAccounts == false)
        #expect(services.account.currentBrandId == nil)

        // Verify persistence was cleared
        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == nil)
        #expect(SongLikeStatusManager.shared.activeAccountID == "primary")
        #expect(SongLikeStatusManager.shared.status(for: "cached-video") == nil)
    }

    // MARK: - Error Handling Tests

    @Test @MainActor func clearErrorResetsLastError() async {
        let services = Self.createService()

        // Trigger an error by making fetchAccounts fail
        services.client.shouldThrowError = YTMusicError.apiError(message: "Test error", code: nil)
        services.auth.completeLogin(sapisid: "test-sapisid")
        await services.account.fetchAccounts()

        #expect(services.account.lastError != nil)

        // Clear the error
        services.account.clearError()

        #expect(services.account.lastError == nil)
    }

    // MARK: - Computed Properties Tests

    @Test @MainActor func currentBrandIdReturnsNilForPrimaryAccount() async {
        let services = Self.createService()

        let primaryAccount = MockUserAccountData.primaryAccount
        await Self.populateAccounts(services, accounts: [primaryAccount])

        #expect(services.account.currentBrandId == nil)
    }

    @Test @MainActor func currentBrandIdReturnsBrandIdForBrandAccount() async {
        let services = Self.createService()

        let brandAccount = MockUserAccountData.brandAccount
        // Use brand account as selected
        await Self.populateAccounts(services, accounts: [brandAccount], selectedIndex: 0)

        #expect(services.account.currentBrandId == "123456789012345678901")
    }

    // MARK: - Helper Methods

    @MainActor
    private static func createService() -> TestServices {
        let authService = AuthService()
        let mockClient = MockYTMusicClient()
        let service = AccountService(ytMusicClient: mockClient, authService: authService)
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        return TestServices(account: service, client: mockClient, auth: authService)
    }

    @MainActor
    private static func createService(webKitManager: MockWebKitManager) -> TestServices {
        let authService = AuthService()
        let mockClient = MockYTMusicClient()
        let service = AccountService(
            ytMusicClient: mockClient,
            authService: authService,
            webKitManager: webKitManager
        )
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        return TestServices(account: service, client: mockClient, auth: authService)
    }

    /// Populates the AccountService with accounts by going through fetchAccounts().
    @MainActor
    private static func populateAccounts(
        _ services: TestServices,
        accounts: [UserAccount],
        selectedIndex: Int = 0
    ) async {
        // Mark the desired account as selected
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

        // Clear any saved brand ID to avoid stale state
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

// MARK: - TestServices

/// Helper struct to avoid large tuple violation.
private struct TestServices {
    let account: AccountService
    let client: MockYTMusicClient
    let auth: AuthService
}

// MARK: - AsyncReleaseGate

/// A one-shot async gate: callers `await wait()` until `release()` is called or
/// the awaiting task is cancelled. Cancellation-aware so a gated mock pin that
/// `switchAccount` cancels+awaits resumes promptly instead of hanging the test.
/// Used to hold a mocked session pin "in flight" while a concurrent switch runs.
private actor AsyncReleaseGate {
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        if self.released { return }
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
