import SwiftUI

/// Sidebar navigation for the main window, styled like Apple Music.
@available(macOS 26.0, *)
struct Sidebar: View {
    @Binding var selection: NavigationItem?

    /// Namespace for glass effect morphing.
    @Namespace private var sidebarNamespace

    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 0) {
                List(selection: self.$selection) {
                    // Main navigation
                    Section {
                        NavigationLink(value: NavigationItem.search) {
                            Label(NavigationItem.search.displayName, systemImage: NavigationItem.search.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.searchItem)

                        NavigationLink(value: NavigationItem.home) {
                            Label(NavigationItem.home.displayName, systemImage: NavigationItem.home.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.homeItem)
                    }

                    // Discover section
                    Section(String(localized: "Discover")) {
                        NavigationLink(value: NavigationItem.explore) {
                            Label(NavigationItem.explore.displayName, systemImage: NavigationItem.explore.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.exploreItem)

                        NavigationLink(value: NavigationItem.charts) {
                            Label(NavigationItem.charts.displayName, systemImage: NavigationItem.charts.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.chartsItem)

                        NavigationLink(value: NavigationItem.moodsAndGenres) {
                            Label(NavigationItem.moodsAndGenres.displayName, systemImage: NavigationItem.moodsAndGenres.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.moodsAndGenresItem)

                        NavigationLink(value: NavigationItem.newReleases) {
                            Label(NavigationItem.newReleases.displayName, systemImage: NavigationItem.newReleases.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.newReleasesItem)

                        NavigationLink(value: NavigationItem.podcasts) {
                            Label(NavigationItem.podcasts.displayName, systemImage: NavigationItem.podcasts.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.podcastsItem)
                    }

                    // Collection section
                    Section(String(localized: "Collection")) {
                        NavigationLink(value: NavigationItem.library) {
                            Label(NavigationItem.library.displayName, systemImage: NavigationItem.library.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.libraryItem)

                        NavigationLink(value: NavigationItem.likedMusic) {
                            Label(NavigationItem.likedMusic.displayName, systemImage: NavigationItem.likedMusic.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.likedMusicItem)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier(AccessibilityID.Sidebar.container)
                .onChange(of: self.selection) { _, newValue in
                    if newValue != nil {
                        HapticService.navigation()
                    }
                }
            }

            Divider()
                .opacity(0.3)

            // Profile section at bottom
            SidebarProfileView()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }
}

@available(macOS 26.0, *)
#Preview {
    Sidebar(selection: .constant(.home))
        .frame(width: 220)
}
