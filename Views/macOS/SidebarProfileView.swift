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
@available(macOS 26.0, *)
struct SidebarProfileView: View {
    @Environment(AccountService.self) private var accountService
    @Environment(AuthService.self) private var authService

    @State private var showingAccountSwitcher = false

    var body: some View {
        Group {
            if self.authService.state.isLoggedIn {
                self.loggedInContent
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
                if self.accountService.hasBrandAccounts {
                    self.showingAccountSwitcher = true
                }
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

                    // Chevron indicator (only if multiple accounts)
                    if self.accountService.hasBrandAccounts {
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
            .accessibilityHint(
                self.accountService.hasBrandAccounts
                    ? "Double-tap to switch accounts"
                    : ""
            )
            .popover(isPresented: self.$showingAccountSwitcher, arrowEdge: .top) {
                AccountSwitcherPopover()
                    .environment(self.accountService)
            }
        } else if self.accountService.lastError != nil, !self.accountService.isLoading {
            // Error state - show retry option
            self.errorStateView
        } else {
            // Loading state when account not yet fetched
            self.loadingStateView
        }
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
                Text("Failed to load")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text("Tap to retry")
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
        .accessibilityLabel("Failed to load accounts")
        .accessibilityHint("Double-tap to retry")
    }

    // MARK: - Logged Out Content

    private var loggedOutContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            Text("Not signed in")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loggedOutState)
        .accessibilityLabel("Not signed in")
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

@available(macOS 26.0, *)
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

@available(macOS 26.0, *)
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
