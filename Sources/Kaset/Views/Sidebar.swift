import SwiftUI

/// Sidebar navigation for the main window, styled like Apple Music.
@available(macOS 26.0, *)
struct Sidebar: View {
    private enum SidebarSelection: Hashable {
        case navigation(NavigationItem)
        case pinned(SidebarPinnedItem)
    }

    @Binding var selection: NavigationItem?
    @Binding var pinnedSelection: SidebarPinnedItem?
    @Environment(SidebarPinnedItemsManager.self) private var sidebarPinnedItemsManager

    /// Namespace for glass effect morphing.
    @Namespace private var sidebarNamespace

    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 0) {
                List(selection: self.sidebarSelection) {
                    // Main navigation
                    Section {
                        NavigationLink(value: SidebarSelection.navigation(.search)) {
                            Label(NavigationItem.search.displayName, systemImage: NavigationItem.search.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.searchItem)

                        NavigationLink(value: SidebarSelection.navigation(.home)) {
                            Label(NavigationItem.home.displayName, systemImage: NavigationItem.home.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.homeItem)
                    }

                    // Discover section
                    Section(String(localized: "Discover")) {
                        NavigationLink(value: SidebarSelection.navigation(.explore)) {
                            Label(NavigationItem.explore.displayName, systemImage: NavigationItem.explore.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.exploreItem)

                        NavigationLink(value: SidebarSelection.navigation(.charts)) {
                            Label(NavigationItem.charts.displayName, systemImage: NavigationItem.charts.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.chartsItem)

                        NavigationLink(value: SidebarSelection.navigation(.moodsAndGenres)) {
                            Label(NavigationItem.moodsAndGenres.displayName, systemImage: NavigationItem.moodsAndGenres.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.moodsAndGenresItem)

                        NavigationLink(value: SidebarSelection.navigation(.newReleases)) {
                            Label(NavigationItem.newReleases.displayName, systemImage: NavigationItem.newReleases.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.newReleasesItem)

                        NavigationLink(value: SidebarSelection.navigation(.podcasts)) {
                            Label(NavigationItem.podcasts.displayName, systemImage: NavigationItem.podcasts.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.podcastsItem)
                    }

                    // Collection section
                    Section(String(localized: "Collection")) {
                        NavigationLink(value: SidebarSelection.navigation(.library)) {
                            Label(NavigationItem.library.displayName, systemImage: NavigationItem.library.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.libraryItem)

                        NavigationLink(value: SidebarSelection.navigation(.likedMusic)) {
                            Label(NavigationItem.likedMusic.displayName, systemImage: NavigationItem.likedMusic.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.likedMusicItem)

                        NavigationLink(value: SidebarSelection.navigation(.history)) {
                            Label(NavigationItem.history.displayName, systemImage: NavigationItem.history.icon)
                        }
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
                .accessibilityIdentifier(AccessibilityID.Sidebar.container)
            }

            Divider()
                .opacity(0.3)

            // Profile section at bottom
            SidebarProfileView()
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

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding {
            self.currentSidebarSelection
        } set: { newValue in
            guard self.currentSidebarSelection != newValue else { return }

            switch newValue {
            case let .navigation(item):
                self.selection = item
                self.pinnedSelection = nil
            case let .pinned(item):
                self.selection = nil
                self.pinnedSelection = item
            case nil:
                self.selection = nil
                self.pinnedSelection = nil
            }

            HapticService.navigation()
        }
    }

    private func sidebarPinnedRow(_ item: SidebarPinnedItem) -> some View {
        NavigationLink(value: SidebarSelection.pinned(item)) {
            Label {
                Text(item.title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: item.systemImage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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

@available(macOS 26.0, *)
#Preview {
    Sidebar(selection: .constant(.home), pinnedSelection: .constant(nil))
        .frame(width: 220)
        .environment(SidebarPinnedItemsManager(skipLoad: true))
}
