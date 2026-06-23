// UserAccount.swift
// Kaset
//
// Created for account switcher feature.

import Foundation

/// Represents a YouTube Music user account (primary or brand account).
///
/// YouTube Music allows users to have multiple accounts:
/// - **Primary account**: The main Google account (no brandId)
/// - **Brand accounts**: Managed channel accounts associated with the primary account
///
/// ## API Response Mapping
/// - `name`: From `accountName.runs[0].text`
/// - `handle`: From `channelHandle.runs[0].text` (optional)
/// - `brandId`: From `serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens[].pageIdToken.pageId`
/// - `thumbnailURL`: From `accountPhoto.thumbnails[0].url`
/// - `isSelected`: From `isSelected`
public struct UserAccount: Identifiable, Equatable, Sendable, Hashable {
    // MARK: - Properties

    /// Unique identifier for the account.
    /// Uses `brandId` for brand accounts, "primary" for the main account.
    public let id: String

    /// Display name of the account.
    public let name: String

    /// Channel handle (e.g., "@username"), if available.
    public let handle: String?

    /// Brand account identifier, nil for primary accounts.
    public let brandId: String?

    /// Server-issued account-switch endpoint for this identity.
    ///
    /// From `serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens[]
    /// .accountSigninToken.signinUrl`. Navigating a shared-cookie WebView to this
    /// URL re-points the active delegated identity for the session (and therefore
    /// which account playback history records to). Brand accounts carry a
    /// `pageid` in this URL; the primary's URL omits it.
    ///
    /// Credential-bearing: never log the raw value.
    public let signinURL: URL?

    /// URL for the account's profile photo thumbnail.
    public let thumbnailURL: URL?

    /// Whether this account is currently selected/active.
    public let isSelected: Bool

    // MARK: - Computed Properties

    /// Returns `true` if this is the primary Google account (not a brand account).
    public var isPrimary: Bool {
        self.brandId == nil
    }

    /// Human-readable label for the account type.
    /// Returns "Personal" for primary accounts, "Brand" for brand accounts.
    public var typeLabel: String {
        self.isPrimary ? "Personal" : "Brand"
    }

    /// Account-scoped cache identity used only as input to cache-key hashing.
    ///
    /// Primary accounts all use `id == "primary"`, so include the handle/name
    /// to keep personalized caches separate when a different signed-in Google
    /// account is restored with the same primary brand state.
    var cacheIdentity: String {
        [self.id, self.handle ?? "", self.name].joined(separator: "\u{1F}")
    }

    // MARK: - Initialization

    /// Creates a new UserAccount instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the account.
    ///   - name: Display name of the account.
    ///   - handle: Optional channel handle.
    ///   - brandId: Brand account identifier (nil for primary).
    ///   - thumbnailURL: URL for the profile photo.
    ///   - isSelected: Whether the account is currently active.
    ///   - signinURL: Server-issued account-switch endpoint (nil if unavailable).
    public init(
        id: String,
        name: String,
        handle: String?,
        brandId: String?,
        thumbnailURL: URL?,
        isSelected: Bool,
        signinURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.brandId = brandId
        self.thumbnailURL = thumbnailURL
        self.isSelected = isSelected
        self.signinURL = signinURL
    }

    // MARK: - Factory Methods

    /// Creates a UserAccount from API response fields.
    ///
    /// This factory method automatically determines the account ID based on whether
    /// a brandId is provided.
    ///
    /// - Parameters:
    ///   - name: Display name from `accountName.runs[0].text`.
    ///   - handle: Optional handle from `channelHandle.runs[0].text`.
    ///   - brandId: Brand ID from `pageIdToken.pageId`, nil for primary account.
    ///   - thumbnailURL: Thumbnail URL from `accountPhoto.thumbnails[0].url`.
    ///   - isSelected: Selection state from `isSelected`.
    ///   - signinURL: Switch URL from `accountSigninToken.signinUrl`.
    /// - Returns: A configured UserAccount instance.
    public static func from(
        name: String,
        handle: String?,
        brandId: String?,
        thumbnailURL: URL?,
        isSelected: Bool,
        signinURL: URL? = nil
    ) -> UserAccount {
        let accountId = brandId ?? "primary"
        return UserAccount(
            id: accountId,
            name: name,
            handle: handle,
            brandId: brandId,
            thumbnailURL: thumbnailURL,
            isSelected: isSelected,
            signinURL: signinURL
        )
    }

    public static func == (lhs: UserAccount, rhs: UserAccount) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.handle == rhs.handle && lhs.brandId == rhs.brandId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(self.name)
        hasher.combine(self.handle)
        hasher.combine(self.brandId)
    }
}
