import SwiftUI

// MARK: - YouTubeSidebar

/// Sidebar navigation for the YouTube (video) experience.
///
/// Mirrors the music `Sidebar` structure so toggling sources feels native:
/// main items on top, a Discover section, and a Collection section, with the
/// shared footer (source toggle + profile) at the bottom.
struct YouTubeSidebar: View {
    @Binding var selection: YouTubeNavigationItem?
    @Environment(AuthService.self) private var authService

    var body: some View {
        List {
            // Main navigation
            Section {
                self.row(for: .search)
                self.row(for: .home)
                if self.hasPersonalAccount {
                    self.row(for: .subscriptions)
                }
            }

            // Discover section
            Section(String(localized: "Discover")) {
                self.row(for: .explore)
                self.row(for: .shorts)
            }

            if self.hasPersonalAccount {
                // Collection section
                Section(String(localized: "Collection")) {
                    self.row(for: .likedVideos)
                    self.row(for: .watchLater)
                    self.row(for: .playlists)
                    self.row(for: .history)
                }
            }
        }
        .listStyle(.sidebar)
        .compatTranslucentSidebar()
        .accessibilityIdentifier(AccessibilityID.YouTubeSidebar.container)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooterView()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private func row(for item: YouTubeNavigationItem) -> some View {
        KasetSidebarRow(
            title: item.displayName,
            systemImage: item.icon,
            isSelected: self.selection == item
        ) {
            self.select(item)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeSidebar.item(for: item))
    }

    private func select(_ item: YouTubeNavigationItem) {
        guard self.selection != item else { return }
        self.selection = item
        HapticService.navigation()
    }
}

// MARK: - AccessibilityID.YouTubeSidebar

extension AccessibilityID {
    enum YouTubeSidebar {
        static let container = "youtubeSidebar"

        static func item(for item: YouTubeNavigationItem) -> String {
            "youtubeSidebar.\(item.rawValue)"
        }
    }
}

#Preview {
    YouTubeSidebar(selection: .constant(.home))
        .frame(width: 220)
        .environment(AuthService())
}
