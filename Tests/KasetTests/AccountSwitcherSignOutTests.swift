import Testing
@testable import Kaset

@Suite("Account switcher sign-out")
@MainActor
struct AccountSwitcherSignOutTests {
    @Test("Successful sign-out dismisses only after account preparation")
    func successfulSignOutDismissesAfterPreparation() async {
        var events: [String] = []

        let disposition = await AccountSwitcherSignOutFlow.perform(
            prepareForSignOut: {
                events.append("prepare")
            },
            signOut: {
                events.append("signOut")
                return true
            }
        )

        #expect(events == ["prepare", "signOut"])
        #expect(disposition == .dismiss)
    }

    @Test("Failed durable sign-out presents recovery without dismissing")
    func failedSignOutPresentsRecovery() async {
        var events: [String] = []

        let disposition = await AccountSwitcherSignOutFlow.perform(
            prepareForSignOut: {
                events.append("prepare")
            },
            signOut: {
                events.append("signOut")
                return false
            }
        )

        #expect(events == ["prepare", "signOut"])
        #expect(disposition == .presentFailure)
    }
}
