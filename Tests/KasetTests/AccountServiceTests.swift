// AccountServiceTests.swift
// KasetTests
//
// Tests for AccountService using Swift Testing framework.

import Testing

@testable import Kaset

// MARK: - AccountServiceTests

@Suite(.serialized)
struct AccountServiceTests {
    // MARK: - Initial State Tests

    @Test @MainActor func initialStateIsEmpty() {
        let service = Self.createService().account

        #expect(service.accounts.isEmpty)
        #expect(service.currentAccount == nil)
        #expect(service.hasBrandAccounts == false)
        #expect(service.currentBrandId == nil)
        #expect(service.isLoading == false)
        #expect(service.lastError == nil)
    }

    @Test @MainActor func hasBrandAccountsReturnsFalseForSingleAccount() {
        let service = Self.createService().account

        // Simulate single account scenario
        service.setAccountsForTesting([MockUserAccountData.primaryAccount])

        #expect(service.hasBrandAccounts == false)
    }

    @Test @MainActor func hasBrandAccountsReturnsTrueForMultipleAccounts() {
        let service = Self.createService().account

        // Simulate multiple accounts scenario
        service.setAccountsForTesting([
            MockUserAccountData.primaryAccount,
            MockUserAccountData.brandAccount,
        ])

        #expect(service.hasBrandAccounts == true)
    }

    // MARK: - Switch Account Tests

    @Test @MainActor func switchAccountUpdatesCurrentAccount() async throws {
        let service = Self.createService().account

        // Setup initial state with multiple accounts
        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        service.setAccountsForTesting([primaryAccount, brandAccount])
        service.setCurrentAccountForTesting(primaryAccount)

        #expect(service.currentAccount == primaryAccount)

        // Switch to brand account
        try await service.switchAccount(to: brandAccount)

        #expect(service.currentAccount == brandAccount)
        #expect(service.currentBrandId == brandAccount.brandId)
    }

    @Test @MainActor func switchAccountToSameAccountIsNoOp() async throws {
        let service = Self.createService().account

        let primaryAccount = MockUserAccountData.primaryAccount
        service.setAccountsForTesting([primaryAccount])
        service.setCurrentAccountForTesting(primaryAccount)

        // Attempt to switch to the same account
        try await service.switchAccount(to: primaryAccount)

        // Should still be the same account (no error thrown)
        #expect(service.currentAccount == primaryAccount)
    }

    @Test @MainActor func switchAccountUpdatesBrandId() async throws {
        let service = Self.createService().account

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        service.setAccountsForTesting([primaryAccount, brandAccount])
        service.setCurrentAccountForTesting(primaryAccount)

        // Primary account should have nil brandId
        #expect(service.currentBrandId == nil)

        // Switch to brand account
        try await service.switchAccount(to: brandAccount)

        // Brand account should have brandId
        #expect(service.currentBrandId == brandAccount.brandId)
        #expect(service.currentBrandId == "123456789012345678901")
    }

    // MARK: - Persistence Tests

    @Test @MainActor func switchAccountPersistsSelection() async throws {
        let service = Self.createService().account

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        service.setAccountsForTesting([primaryAccount, brandAccount])
        service.setCurrentAccountForTesting(primaryAccount)

        // Switch to brand account
        try await service.switchAccount(to: brandAccount)

        // Verify UserDefaults was updated
        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == brandAccount.id)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "selectedBrandId")
    }

    @Test @MainActor func switchToPrimaryAccountPersistsPrimaryId() async throws {
        let service = Self.createService().account

        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        service.setAccountsForTesting([primaryAccount, brandAccount])
        service.setCurrentAccountForTesting(brandAccount)

        // Switch back to primary account
        try await service.switchAccount(to: primaryAccount)

        // Verify UserDefaults has "primary" as the ID
        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == "primary")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "selectedBrandId")
    }

    // MARK: - Clear Accounts Tests

    @Test @MainActor func clearAccountsResetsState() {
        let service = Self.createService().account

        // Setup initial state
        let primaryAccount = MockUserAccountData.primaryAccount
        let brandAccount = MockUserAccountData.brandAccount
        service.setAccountsForTesting([primaryAccount, brandAccount])
        service.setCurrentAccountForTesting(primaryAccount)

        // Set a persisted selection
        UserDefaults.standard.set("primary", forKey: "selectedBrandId")

        // Clear accounts
        service.clearAccounts()

        #expect(service.accounts.isEmpty)
        #expect(service.currentAccount == nil)
        #expect(service.hasBrandAccounts == false)
        #expect(service.currentBrandId == nil)

        // Verify persistence was cleared
        let savedBrandId = UserDefaults.standard.string(forKey: "selectedBrandId")
        #expect(savedBrandId == nil)
    }

    // MARK: - Error Handling Tests

    @Test @MainActor func clearErrorResetsLastError() {
        let service = Self.createService().account

        // Simulate an error state
        service.setLastErrorForTesting(YTMusicError.apiError("Test error"))

        #expect(service.lastError != nil)

        // Clear the error
        service.clearError()

        #expect(service.lastError == nil)
    }

    // MARK: - Computed Properties Tests

    @Test @MainActor func currentBrandIdReturnsNilForPrimaryAccount() {
        let service = Self.createService().account

        let primaryAccount = MockUserAccountData.primaryAccount
        service.setCurrentAccountForTesting(primaryAccount)

        #expect(service.currentBrandId == nil)
    }

    @Test @MainActor func currentBrandIdReturnsBrandIdForBrandAccount() {
        let service = Self.createService().account

        let brandAccount = MockUserAccountData.brandAccount
        service.setCurrentAccountForTesting(brandAccount)

        #expect(service.currentBrandId == "123456789012345678901")
    }

    // MARK: - Helper Methods

    private static func createService() -> TestServices {
        let authService = AuthService()
        let mockClient = MockYTMusicClient()
        let service = AccountService(ytMusicClient: mockClient, authService: authService)
        return TestServices(account: service, client: mockClient, auth: authService)
    }
}

// MARK: - TestServices

/// Helper struct to avoid large tuple violation.
private struct TestServices {
    let account: AccountService
    let client: MockYTMusicClient
    let auth: AuthService
}

// MARK: - AccountService Test Helpers

extension AccountService {
    /// Sets accounts directly for testing purposes.
    /// - Parameter accounts: The accounts to set.
    func setAccountsForTesting(_ accounts: [UserAccount]) {
        self.accounts = accounts
    }

    /// Sets the current account directly for testing purposes.
    /// - Parameter account: The account to set as current.
    func setCurrentAccountForTesting(_ account: UserAccount?) {
        self.currentAccount = account
    }

    /// Sets the last error directly for testing purposes.
    /// - Parameter error: The error to set.
    func setLastErrorForTesting(_ error: Error?) {
        self.lastError = error
    }
}
