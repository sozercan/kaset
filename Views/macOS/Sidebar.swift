import SwiftUI

/// Sidebar navigation for the main window, styled like Apple Music.
@available(macOS 26.0, *)
struct Sidebar: View {
    @Binding var selection: NavigationItem?

    var body: some View {
        List(selection: self.$selection) {
            // Main navigation
            Section {
                NavigationLink(value: NavigationItem.search) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.searchItem)

                NavigationLink(value: NavigationItem.home) {
                    Label("Home", systemImage: "house")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.homeItem)

                NavigationLink(value: NavigationItem.explore) {
                    Label("Explore", systemImage: "globe")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.exploreItem)
            }

            // Discover section
            Section("Discover") {
                NavigationLink(value: NavigationItem.charts) {
                    Label("Charts", systemImage: "chart.line.uptrend.xyaxis")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.chartsItem)

                NavigationLink(value: NavigationItem.moodsAndGenres) {
                    Label("Moods & Genres", systemImage: "theatermask.and.paintbrush")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.moodsAndGenresItem)

                NavigationLink(value: NavigationItem.newReleases) {
                    Label("New Releases", systemImage: "sparkles")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.newReleasesItem)
            }

            // Library section
            Section("Library") {
                NavigationLink(value: NavigationItem.likedMusic) {
                    Label("Liked Music", systemImage: "heart.fill")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.likedMusicItem)

                NavigationLink(value: NavigationItem.library) {
                    Label("Playlists", systemImage: "music.note.list")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.libraryItem)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        .accessibilityIdentifier(AccessibilityID.Sidebar.container)
    }
}

@available(macOS 26.0, *)
#Preview {
    Sidebar(selection: .constant(.home))
        .frame(width: 220)
}
