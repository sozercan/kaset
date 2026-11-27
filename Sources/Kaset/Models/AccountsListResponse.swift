import Foundation

public struct AccountsListResponse: Sendable {
    public let googleEmail: String?

    public let accounts: [UserAccount]

    public var selectedAccount: UserAccount? {
        self.accounts.first { $0.isSelected }
    }

    public var hasMultipleAccounts: Bool {
        self.accounts.count > 1
    }

    public init(googleEmail: String?, accounts: [UserAccount]) {
        self.googleEmail = googleEmail
        self.accounts = accounts
    }
}
