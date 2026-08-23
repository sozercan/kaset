import Testing
@testable import Kaset

// MARK: - AccountServiceSessionExpirationTests

@Suite(.serialized)
@MainActor
struct AccountServiceSessionExpirationTests {
    @Test func fetchAccountsWithEmptyAccountsExpiresSession() async {
        let services = Self.createService()

        services.client.accountsListResponse = AccountsListResponse(googleEmail: "test@gmail.com", accounts: [])
        services.auth.completeLogin(sapisid: "test-sapisid")

        await services.account.fetchAccounts()

        #expect(services.auth.state == .loggedOut)
        #expect(services.auth.needsReauth == true)
        #expect(services.account.accounts.isEmpty)
        #expect(services.account.currentAccount == nil)
        #expect(services.account.lastError == nil)
        #expect(services.account.isLoading == false)
    }

    private static func createService() -> SessionExpirationTestServices {
        let authService = AuthService()
        let mockClient = MockYTMusicClient()
        let accountService = AccountService(ytMusicClient: mockClient, authService: authService)
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        return SessionExpirationTestServices(account: accountService, client: mockClient, auth: authService)
    }
}

// MARK: - SessionExpirationTestServices

private struct SessionExpirationTestServices {
    let account: AccountService
    let client: MockYTMusicClient
    let auth: AuthService
}
