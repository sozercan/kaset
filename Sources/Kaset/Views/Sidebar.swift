import SwiftUI

/// Sidebar navigation for the main window, styled like Apple Music.
struct Sidebar: View {
    private enum SidebarSelection: Hashable {
        case navigation(NavigationItem)
        case pinned(SidebarPinnedItem)
    }

    @Binding var selection: NavigationItem?
    @Binding var pinnedSelection: SidebarPinnedItem?
    let client: any YTMusicClientProtocol
    @Environment(AuthService.self) private var authService
    @Environment(SidebarPinnedItemsManager.self) private var sidebarPinnedItemsManager
    @Environment(PodcastsAvailabilityService.self) private var podcastsAvailability
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    /// Drop key for the Collection "Liked Music" row, distinct from the pinned LM
    /// playlist row so only the hovered row highlights.
    private static let likedMusicNavDropKey = "collection-liked-music"

    @State private var dropTargetPlaylistId: String?
    @State private var dropFeedbackPlaylistId: String?

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

            if self.hasPersonalAccount {
                // Collection section
                Section(String(localized: "Collection")) {
                    self.navigationRow(.library)
                        .accessibilityIdentifier(AccessibilityID.Sidebar.libraryItem)

                    self.likedMusicNavigationRow
                        .accessibilityIdentifier(AccessibilityID.Sidebar.likedMusicItem)

                    self.navigationRow(.history)
                        .accessibilityIdentifier(AccessibilityID.Sidebar.historyItem)
                }
            }

            if self.hasPersonalAccount, self.sidebarPinnedItemsManager.isVisible {
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

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
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

    private func navigationRow(_ item: NavigationItem, isDropTargeted: Bool = false) -> some View {
        KasetSidebarRow(
            title: item.displayName,
            systemImage: item.icon,
            isSelected: self.currentSidebarSelection == .navigation(item),
            isDropTargeted: isDropTargeted
        ) {
            self.selectNavigationItem(item)
        }
    }

    /// The Collection "Liked Music" row also accepts song drops: Liked Music is the LM
    /// auto-playlist, where membership means "liked", so drops rate the song instead of
    /// editing a playlist.
    private var likedMusicNavigationRow: some View {
        self.navigationRow(.likedMusic, isDropTargeted: self.dropTargetPlaylistId == Self.likedMusicNavDropKey)
            .overlay(alignment: .trailing) {
                self.dropSuccessBadge(show: self.dropFeedbackPlaylistId == Self.likedMusicNavDropKey)
            }
            .animation(AppAnimation.bouncy, value: self.dropFeedbackPlaylistId == Self.likedMusicNavDropKey)
            .dropDestination(for: Song.self) { droppedSongs, _ in
                self.handleDroppedSongs(
                    droppedSongs,
                    target: .likedMusic,
                    feedbackKey: Self.likedMusicNavDropKey
                )
                return true
            } isTargeted: { targeted in
                self.updateDropTarget(key: Self.likedMusicNavDropKey, targeted: targeted)
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

    /// Adds each dropped song to the target through Library Mutation Orchestration, then maps the
    /// outcome to haptics and the confirmation badge. Liked Music routing lives in the orchestrator.
    private func handleDroppedSongs(
        _ songs: [Song],
        target: PlaylistDropTarget,
        feedbackKey: String
    ) {
        for song in songs {
            Task {
                let outcome = await LibraryMutationActions.addSong(
                    song,
                    to: target,
                    client: self.client,
                    likeStatusManager: self.likeStatusManager
                )
                switch outcome {
                case .added, .liked:
                    HapticService.success()
                    self.flashDropFeedback(for: feedbackKey)
                case .failed:
                    HapticService.error()
                }
            }
        }
    }

    private func updateDropTarget(key: String, targeted: Bool) {
        self.dropTargetPlaylistId = targeted ? key : (self.dropTargetPlaylistId == key ? nil : self.dropTargetPlaylistId)
    }

    @ViewBuilder
    private func dropSuccessBadge(show: Bool) -> some View {
        if show {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .compatGlass(tint: .green, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .padding(.trailing, 6)
                .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
                .accessibilityHidden(true)
        }
    }

    /// Briefly shows a green checkmark badge on the playlist row to confirm
    /// a successful drag-and-drop.
    private func flashDropFeedback(for playlistId: String) {
        self.dropFeedbackPlaylistId = playlistId
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if self.dropFeedbackPlaylistId == playlistId {
                self.dropFeedbackPlaylistId = nil
            }
        }
    }

    private func sidebarPinnedRow(_ item: SidebarPinnedItem) -> some View {
        let isDropEligible = item.acceptsSongDrops
        let isDropTargeted = self.dropTargetPlaylistId == item.contentId
        let showDropFeedback = self.dropFeedbackPlaylistId == item.contentId

        return KasetSidebarRow(
            title: item.title,
            systemImage: item.systemImage,
            isSelected: self.currentSidebarSelection == .pinned(item),
            isDropTargeted: isDropEligible && isDropTargeted
        ) {
            self.selectPinnedItem(item)
        }
        .overlay(alignment: .trailing) {
            self.dropSuccessBadge(show: isDropEligible && showDropFeedback)
        }
        .animation(AppAnimation.bouncy, value: showDropFeedback)
        .dropDestination(for: Song.self) { droppedSongs, _ in
            guard isDropEligible else { return false }
            self.handleDroppedSongs(
                droppedSongs,
                target: PlaylistDropTarget(playlistId: item.contentId),
                feedbackKey: item.contentId
            )
            return true
        } isTargeted: { targeted in
            guard isDropEligible else { return }
            self.updateDropTarget(key: item.contentId, targeted: targeted)
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
    let authService = AuthService()
    let client: any YTMusicClientProtocol = if UITestConfig.isUITestMode {
        MockUITestYTMusicClient()
    } else {
        YTMusicClient(authService: authService, webKitManager: .shared)
    }
    Sidebar(selection: .constant(.home), pinnedSelection: .constant(nil), client: client)
        .frame(width: 220)
        .environment(authService)
        .environment(SidebarPinnedItemsManager(skipLoad: true))
        .environment(PodcastsAvailabilityService())
}
