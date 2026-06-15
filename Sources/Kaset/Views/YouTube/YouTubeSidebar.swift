import SwiftUI

// MARK: - YouTubeSidebar

/// Sidebar navigation for the YouTube (video) experience.
///
/// Mirrors the music `Sidebar` structure so toggling sources feels native:
/// main items on top, a Discover section, and a Collection section, with the
/// shared footer (source toggle + profile) at the bottom.
struct YouTubeSidebar: View {
    @Binding var selection: YouTubeNavigationItem?

    var body: some View {
        List(selection: self.listSelection) {
            // Main navigation
            Section {
                self.row(for: .search)
                self.row(for: .home)
                self.row(for: .subscriptions)
            }

            // Discover section
            Section(String(localized: "Discover")) {
                self.row(for: .explore)
                self.row(for: .shorts)
            }

            // Collection section
            Section(String(localized: "Collection")) {
                self.row(for: .likedVideos)
                self.row(for: .watchLater)
                self.row(for: .playlists)
                self.row(for: .history)
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

    /// Selection binding that adds haptic feedback on change.
    private var listSelection: Binding<YouTubeNavigationItem?> {
        Binding {
            self.selection
        } set: { newValue in
            guard self.selection != newValue else { return }
            self.selection = newValue
            HapticService.navigation()
        }
    }

    private func row(for item: YouTubeNavigationItem) -> some View {
        NavigationLink(value: item) {
            Label(item.displayName, systemImage: item.icon)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeSidebar.item(for: item))
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
}
