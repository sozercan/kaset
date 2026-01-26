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
@available(macOS 26.0, *)
struct AccountSwitcherPopover: View {
    @Environment(AccountService.self) private var accountService
    @Environment(\.dismiss) private var dismiss

    /// Namespace for glass effect morphing.
    @Namespace private var popoverNamespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                // Header
                self.headerView

                // Accounts list
                self.accountsListView
            }
            .padding(10)
            .frame(minWidth: 280)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
            .glassEffectID("accountSwitcherPopover", in: self.popoverNamespace)
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
                                    do {
                                        try await self.accountService.switchAccount(to: account)
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

        static func accountRow(index: Int) -> String {
            "accountSwitcher.account.\(index)"
        }
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview("Account Switcher") {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    AccountSwitcherPopover()
        .environment(accountService)
        .frame(width: 300, height: 400)
        .padding()
}
