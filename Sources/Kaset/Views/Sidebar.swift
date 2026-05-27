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
    @Environment(PlayerService.self) private var playerService
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @Environment(SidebarPinnedItemsManager.self) private var sidebarPinnedItemsManager
    @Environment(PodcastsAvailabilityService.self) private var podcastsAvailability

    /// Namespace for glass effect morphing.
    @Namespace private var sidebarNamespace

    @State private var playingTopPlaylistId: String?
    @State private var topPlaylistPlaybackTask: Task<Void, Never>?

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

                        if self.podcastsAvailability.availability != .unavailable {
                            NavigationLink(value: SidebarSelection.navigation(.podcasts)) {
                                Label(NavigationItem.podcasts.displayName, systemImage: NavigationItem.podcasts.icon)
                            }
                            .accessibilityIdentifier(AccessibilityID.Sidebar.podcastsItem)
                        }
                    }

                    if !self.topPlaylists.isEmpty {
                        Section(String(localized: "Top Playlists")) {
                            ForEach(self.topPlaylists) { playlist in
                                self.topPlaylistRow(playlist)
                            }
                        }
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
        .task {
            guard let libraryViewModel = self.libraryViewModel,
                  libraryViewModel.loadingState == .idle
            else { return }

            await libraryViewModel.load()
        }
        .onDisappear {
            self.topPlaylistPlaybackTask?.cancel()
            self.topPlaylistPlaybackTask = nil
            self.playingTopPlaylistId = nil
        }
    }

    private var topPlaylists: [Playlist] {
        Array((self.libraryViewModel?.playlists ?? []).prefix(10))
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

    private func topPlaylistRow(_ playlist: Playlist) -> some View {
        let item = SidebarPinnedItem.from(playlist)

        return HStack(spacing: 6) {
            Button {
                self.selectPlaylist(item)
            } label: {
                Label {
                    Text(playlist.title)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "music.note.list")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                self.playPlaylist(playlist)
            } label: {
                if self.playingTopPlaylistId == playlist.id {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(self.playingTopPlaylistId != nil)
            .help(String(localized: "Play"))
            .accessibilityLabel(
                Text(
                    "Play \(playlist.title)",
                    comment: "Accessibility label for playing a playlist from the sidebar"
                )
            )
        }
    }

    private func selectPlaylist(_ item: SidebarPinnedItem) {
        guard self.currentSidebarSelection != .pinned(item) else { return }

        self.selection = nil
        self.pinnedSelection = item
        HapticService.navigation()
    }

    private func playPlaylist(_ playlist: Playlist) {
        guard let libraryViewModel = self.libraryViewModel else { return }

        self.topPlaylistPlaybackTask?.cancel()
        self.playingTopPlaylistId = playlist.id

        self.topPlaylistPlaybackTask = Task {
            defer {
                Task { @MainActor in
                    if self.playingTopPlaylistId == playlist.id {
                        self.playingTopPlaylistId = nil
                    }
                    self.topPlaylistPlaybackTask = nil
                }
            }

            do {
                let response = try await libraryViewModel.client.getPlaylist(id: playlist.id)
                guard !Task.isCancelled else { return }

                let tracks = response.detail.tracks.filter(\.isPlayable)
                guard !tracks.isEmpty else { return }

                await self.playerService.playQueue(tracks, startingAt: 0)
            } catch {
                DiagnosticsLogger.ui.error("Failed to play sidebar playlist: \(error.localizedDescription)")
            }
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    Sidebar(selection: .constant(.home), pinnedSelection: .constant(nil))
        .frame(width: 220)
        .environment(SidebarPinnedItemsManager(skipLoad: true))
        .environment(PodcastsAvailabilityService())
}
