// AccountSwitcherPopover.swift
// Kaset
//
// Liquid Glass styled popover for switching between user accounts.

import SwiftUI

// MARK: - AccountSwitcherPopover

/// A Liquid Glass styled popover for switching between accounts.
///
/// Displays all available accounts (primary and brand accounts) and allows
/// the user to switch between them.
struct AccountSwitcherPopover: View {
    @Environment(AccountService.self) private var accountService
    @Environment(AuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    /// Namespace for glass effect morphing.
    @Namespace private var popoverNamespace

    var body: some View {
        CompatGlassContainer(spacing: 8) {
            VStack(spacing: 8) {
                // Header
                self.headerView

                self.guestModeRow

                Divider()
                    .opacity(0.3)
                    .padding(.horizontal, 12)

                // Accounts list
                self.accountsListView
            }
            .padding(10)
            .frame(minWidth: 280)
            .compatGlass(interactive: true, in: .rect(cornerRadius: 14))
            .compatGlassID("accountSwitcherPopover", in: self.popoverNamespace)
        }
        .accessibilityIdentifier(AccessibilityID.AccountSwitcher.container)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Switch Account")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            if self.accountService.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier(AccessibilityID.AccountSwitcher.header)
    }

    private var guestModeRow: some View {
        Button {
            self.authService.enterGuestMode()
            self.dismiss()
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 19))
                            .foregroundStyle(.tertiary)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Guest Mode"))
                        .font(.body)
                        .fontWeight(self.authService.isGuestModeEnabled ? .semibold : .regular)
                        .foregroundStyle(.primary)

                    Text(String(localized: "Browse without personalization"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if self.authService.isGuestModeEnabled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                        .accessibilityLabel(String(localized: "Selected"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(self.guestRowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.AccountSwitcher.guestModeRow)
        .accessibilityLabel(String(localized: "Guest Mode, browse without personalization"))
        .accessibilityAddTraits(self.authService.isGuestModeEnabled ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var guestRowBackground: some View {
        if self.authService.isGuestModeEnabled {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
        } else {
            Color.clear
        }
    }

    // MARK: - Accounts List

    private var accountsListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(self.accountService.accounts.enumerated()), id: \.element.id) { index, account in
                    VStack(spacing: 0) {
                        AccountRowView(
                            account: account,
                            isSelected: account == self.accountService.currentAccount,
                            onSelect: {
                                Task {
                                    let wasGuestMode = self.authService.isGuestModeEnabled
                                    do {
                                        try await self.accountService.switchAccount(to: account)
                                        if wasGuestMode {
                                            self.authService.exitGuestMode(activeAccountID: account.id)
                                        }
                                        self.dismiss()
                                    } catch {
                                        // Keep the popover open so the user can retry.
                                    }
                                }
                            }
                        )
                        .accessibilityIdentifier(AccessibilityID.AccountSwitcher.accountRow(index: index))

                        // Divider between accounts (not after last one)
                        if index < self.accountService.accounts.count - 1 {
                            Divider()
                                .padding(.leading, 56)
                                .opacity(0.3)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 300)
        .accessibilityIdentifier(AccessibilityID.AccountSwitcher.accountsList)
    }
}

// MARK: - AccessibilityID.AccountSwitcher

extension AccessibilityID {
    enum AccountSwitcher {
        static let container = "accountSwitcher"
        static let header = "accountSwitcher.header"
        static let accountsList = "accountSwitcher.accountsList"
        static let guestModeRow = "accountSwitcher.guestMode"

        static func accountRow(index: Int) -> String {
            "accountSwitcher.account.\(index)"
        }
    }
}

// MARK: - Preview

#Preview("Account Switcher") {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    AccountSwitcherPopover()
        .environment(authService)
        .environment(accountService)
        .frame(width: 300, height: 400)
        .padding()
}
