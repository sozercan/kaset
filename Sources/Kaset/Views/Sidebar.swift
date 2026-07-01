import SwiftUI

/// Sidebar navigation for the main window, styled like Apple Music.
struct Sidebar: View {
    private enum SidebarSelection: Hashable {
        case navigation(NavigationItem)
        case pinned(SidebarPinnedItem)
    }

    @Binding var selection: NavigationItem?
    @Binding var pinnedSelection: SidebarPinnedItem?
    @Environment(SidebarPinnedItemsManager.self) private var sidebarPinnedItemsManager
    @Environment(PodcastsAvailabilityService.self) private var podcastsAvailability

    var body: some View {
        List {
            // Main navigation
            Section {
                self.navigationRow(.search)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.searchItem)

                self.navigationRow(.home)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.homeItem)
            }

            // Discover section
            Section(String(localized: "Discover")) {
                self.navigationRow(.explore)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.exploreItem)

                self.navigationRow(.charts)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.chartsItem)

                self.navigationRow(.moodsAndGenres)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.moodsAndGenresItem)

                self.navigationRow(.newReleases)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.newReleasesItem)

                if self.podcastsAvailability.availability != .unavailable {
                    self.navigationRow(.podcasts)
                        .accessibilityIdentifier(AccessibilityID.Sidebar.podcastsItem)
                }
            }

            // Collection section
            Section(String(localized: "Collection")) {
                self.navigationRow(.library)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.libraryItem)

                self.navigationRow(.likedMusic)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.likedMusicItem)

                self.navigationRow(.history)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.historyItem)
            }

            if self.sidebarPinnedItemsManager.isVisible {
                Section(String(localized: "Playlists")) {
                    ForEach(self.sidebarPinnedItemsManager.items) { item in
                        self.sidebarPinnedRow(item)
                    }
                    .onMove { source, destination in
                        self.sidebarPinnedItemsManager.move(from: source, to: destination)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .compatTranslucentSidebar()
        .accessibilityIdentifier(AccessibilityID.Sidebar.container)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Source toggle + profile section at bottom (shared with YouTubeSidebar)
            SidebarFooterView()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }

    private var currentSidebarSelection: SidebarSelection? {
        if let pinnedSelection {
            return .pinned(pinnedSelection)
        }

        if let selection {
            return .navigation(selection)
        }

        return nil
    }

    private func navigationRow(_ item: NavigationItem) -> some View {
        KasetSidebarRow(
            title: item.displayName,
            systemImage: item.icon,
            isSelected: self.currentSidebarSelection == .navigation(item)
        ) {
            self.selectNavigationItem(item)
        }
    }

    private func selectNavigationItem(_ item: NavigationItem) {
        let newSelection = SidebarSelection.navigation(item)
        guard self.currentSidebarSelection != newSelection else { return }
        self.selection = item
        self.pinnedSelection = nil
        HapticService.navigation()
    }

    private func selectPinnedItem(_ item: SidebarPinnedItem) {
        let newSelection = SidebarSelection.pinned(item)
        guard self.currentSidebarSelection != newSelection else { return }
        self.selection = nil
        self.pinnedSelection = item
        HapticService.navigation()
    }

    private func sidebarPinnedRow(_ item: SidebarPinnedItem) -> some View {
        KasetSidebarRow(
            title: item.title,
            systemImage: item.systemImage,
            isSelected: self.currentSidebarSelection == .pinned(item)
        ) {
            self.selectPinnedItem(item)
        }
        .contextMenu {
            Button {
                self.sidebarPinnedItemsManager.moveUp(contentId: item.contentId)
            } label: {
                Label("Move Up", systemImage: "chevron.up")
            }

            Button {
                self.sidebarPinnedItemsManager.moveDown(contentId: item.contentId)
            } label: {
                Label("Move Down", systemImage: "chevron.down")
            }

            Button {
                self.sidebarPinnedItemsManager.moveToTop(contentId: item.contentId)
            } label: {
                Label("Move to Top", systemImage: "arrow.up.to.line")
            }

            Button {
                self.sidebarPinnedItemsManager.moveToEnd(contentId: item.contentId)
            } label: {
                Label("Move to End", systemImage: "arrow.down.to.line")
            }

            Divider()

            Button(role: .destructive) {
                if self.pinnedSelection?.contentId == item.contentId {
                    self.pinnedSelection = nil
                }
                self.sidebarPinnedItemsManager.remove(contentId: item.contentId)
            } label: {
                Label("Remove from Sidebar", systemImage: "sidebar.left")
            }
        }
    }
}

#Preview {
    Sidebar(selection: .constant(.home), pinnedSelection: .constant(nil))
        .frame(width: 220)
        .environment(SidebarPinnedItemsManager(skipLoad: true))
        .environment(PodcastsAvailabilityService())
}
