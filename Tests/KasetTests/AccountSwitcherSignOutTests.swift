import Testing
@testable import Kaset

@Suite("Account switcher sign-out")
@MainActor
struct AccountSwitcherSignOutTests {
    @Test("Successful sign-out dismisses after the auth service completes")
    func successfulSignOutDismissesAfterServiceCompletes() async {
        var events: [String] = []

        let disposition = await AccountSwitcherSignOutFlow.perform {
            events.append("signOut")
            return true
        }

        #expect(events == ["signOut"])
        #expect(disposition == .dismiss)
    }

    @Test("Failed sign-out preflight leaves account operations available and retry succeeds")
    func failedSignOutPreflightLeavesAccountOperationsAvailableAndRetrySucceeds() async {
        let webKitManager = MockWebKitManager()
        webKitManager.invalidateAuthCookieRestorationResult = false
        let authService = AuthService(webKitManager: webKitManager)
        let client = MockYTMusicClient()
        let accountService = AccountService(
            ytMusicClient: client,
            authService: authService,
            webKitManager: webKitManager
        )
        let primaryAccount = MockUserAccountData.primaryAccount
        client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [primaryAccount]
        )
        authService.completeLogin(sapisid: "test-sapisid")

        let disposition = await AccountSwitcherSignOutFlow.perform {
            await authService.signOut()
        }
        await accountService.fetchAccounts()

        #expect(disposition == .presentFailure)
        #expect(authService.state == .loggedIn(sapisid: "test-sapisid"))
        #expect(accountService.currentAccount?.id == primaryAccount.id)
        #expect(!webKitManager.clearAllDataCalled)

        webKitManager.invalidateAuthCookieRestorationResult = true
        let retryDisposition = await AccountSwitcherSignOutFlow.perform {
            await authService.signOut()
        }

        #expect(retryDisposition == .dismiss)
        #expect(authService.state == .loggedOut)
        #expect(webKitManager.clearAllDataCalled)
    }

    @Test("Failed durable sign-out presents recovery without dismissing")
    func failedSignOutPresentsRecovery() async {
        var events: [String] = []

        let disposition = await AccountSwitcherSignOutFlow.perform {
            events.append("signOut")
            return false
        }

        #expect(events == ["signOut"])
        #expect(disposition == .presentFailure)
    }
}
