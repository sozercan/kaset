// AccountsListResponse.swift
// Kaset
//
// Created for account switcher feature.

import Foundation

/// Response containing the list of available user accounts.
///
/// This struct represents the parsed response from the YouTube Music accounts list API,
/// containing all accounts (primary and brand) associated with the authenticated user.
///
/// ## Usage
/// ```swift
/// let response = AccountsListResponse(
///     googleEmail: "user@gmail.com",
///     accounts: [primaryAccount, brandAccount1, brandAccount2]
/// )
///
/// if let selected = response.selectedAccount {
///     DiagnosticsLogger.log("Current account: \(selected.name)")
/// }
///
/// if response.hasMultipleAccounts {
///     // Show account switcher UI
/// }
/// ```
public struct AccountsListResponse: Sendable {
    // MARK: - Properties

    /// The Google email address associated with the primary account.
    /// Extracted from the response header.
    public let googleEmail: String?

    /// All available accounts (primary and brand accounts).
    public let accounts: [UserAccount]

    // MARK: - Computed Properties

    /// The currently selected/active account.
    /// Returns the first account where `isSelected` is true, or nil if none selected.
    public var selectedAccount: UserAccount? {
        self.accounts.first { $0.isSelected }
    }

    /// Whether multiple accounts are available for switching.
    /// Returns `true` if more than one account exists.
    public var hasMultipleAccounts: Bool {
        self.accounts.count > 1
    }

    // MARK: - Initialization

    /// Creates a new AccountsListResponse.
    ///
    /// - Parameters:
    ///   - googleEmail: The Google email from the response header.
    ///   - accounts: Array of parsed UserAccount objects.
    public init(googleEmail: String?, accounts: [UserAccount]) {
        self.googleEmail = googleEmail
        self.accounts = accounts
    }
}
