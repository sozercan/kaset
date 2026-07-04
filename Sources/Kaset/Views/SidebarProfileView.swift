// SidebarProfileView.swift
// Kaset
//
// Profile section displayed at the bottom of the sidebar for account management.

import SwiftUI

// MARK: - SidebarProfileView

/// A profile section displayed at the bottom of the sidebar.
///
/// Shows the current user's account info with an option to switch accounts
/// if brand accounts are available.
struct SidebarProfileView: View {
    @Environment(AccountService.self) private var accountService
    @Environment(AuthService.self) private var authService

    @State private var showingAccountSwitcher = false

    var body: some View {
        Group {
            if self.authService.hasPersonalAccount {
                self.loggedInContent
            } else if self.authService.state.isLoggedIn {
                self.loggedInGuestContent
            } else {
                self.loggedOutContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Logged In Content

    @ViewBuilder
    private var loggedInContent: some View {
        if let account = accountService.currentAccount {
            Button {
                self.showingAccountSwitcher = true
            } label: {
                HStack(spacing: 10) {
                    // Avatar
                    self.avatarView(for: account)

                    // Name and handle
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        if let handle = account.handle {
                            Text(handle)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Chevron indicator for account/guest switching.
                    if self.accountService.hasBrandAccounts || self.authService.state.isLoggedIn {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.SidebarProfile.profileButton)
            .accessibilityLabel(self.profileAccessibilityLabel(for: account))
            .accessibilityHint(String(localized: "Double-tap to switch accounts or guest mode"))
            .popover(isPresented: self.$showingAccountSwitcher, arrowEdge: .top) {
                AccountSwitcherPopover()
                    .environment(self.authService)
                    .environment(self.accountService)
            }
        } else if self.accountService.isLoading {
            // Loading state only while account data is actively being fetched.
            // If auth is stale but there is no current account, show the guest
            // sign-in affordance instead of a permanent skeleton.
            self.loadingStateView
        } else if self.accountService.lastError != nil {
            // Error state - show retry option
            self.errorStateView
        } else {
            self.missingAccountContent
        }
    }

    private var missingAccountContent: some View {
        Button {
            Task {
                await self.accountService.fetchAccounts()
            }
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Loading account…"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loadingState)
        .accessibilityLabel(String(localized: "Loading account"))
        .accessibilityHint(String(localized: "Double-tap to retry loading accounts"))
    }

    // MARK: - Loading State

    private var loadingStateView: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.quaternary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(width: 80, height: 12)

                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(width: 60, height: 10)
            }

            Spacer()
        }
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loadingState)
    }

    // MARK: - Error State

    private var errorStateView: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Failed to load"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text(String(localized: "Tap to retry"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                self.accountService.clearError()
                await self.accountService.fetchAccounts()
            }
        }
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.errorState)
        .accessibilityLabel(String(localized: "Failed to load accounts"))
        .accessibilityHint(String(localized: "Double-tap to retry"))
    }

    private var loggedInGuestContent: some View {
        Button {
            self.showingAccountSwitcher = true
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Switch back to your account"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.profileButton)
        .accessibilityLabel(String(localized: "Guest mode. Switch back to your account."))
        .popover(isPresented: self.$showingAccountSwitcher, arrowEdge: .top) {
            AccountSwitcherPopover()
                .environment(self.authService)
                .environment(self.accountService)
        }
    }

    // MARK: - Logged Out Content

    private var loggedOutContent: some View {
        Button {
            self.authService.startLogin()
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Sign in for your library"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loggedOutState)
        .accessibilityLabel(String(localized: "Guest mode. Sign in for your library."))
    }

    private func guestModeLabel(subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Guest Mode"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Avatar View

    @ViewBuilder
    private func avatarView(for account: UserAccount) -> some View {
        if let thumbnailURL = account.thumbnailURL {
            CachedAsyncImage(url: thumbnailURL, targetSize: CGSize(width: 64, height: 64)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                self.avatarPlaceholder
            }
            .frame(width: 32, height: 32)
            .clipShape(.circle)
        } else {
            self.avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(.quaternary)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
    }

    // MARK: - Accessibility

    private func profileAccessibilityLabel(for account: UserAccount) -> String {
        var label = "Profile: \(account.name)"
        if let handle = account.handle {
            label += ", \(handle)"
        }
        if self.accountService.hasBrandAccounts {
            label += ". Multiple accounts available."
        }
        return label
    }
}

// MARK: - AccessibilityID.SidebarProfile

extension AccessibilityID {
    enum SidebarProfile {
        static let container = "sidebarProfile"
        static let profileButton = "sidebarProfile.profileButton"
        static let loadingState = "sidebarProfile.loading"
        static let errorState = "sidebarProfile.error"
        static let loggedOutState = "sidebarProfile.loggedOut"
    }
}

// MARK: - Preview

#Preview("With Account") {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    SidebarProfileView()
        .environment(accountService)
        .environment(authService)
        .frame(width: 220)
        .padding()
}

#Preview("Logged Out") {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    SidebarProfileView()
        .environment(accountService)
        .environment(authService)
        .frame(width: 220)
        .padding()
}
