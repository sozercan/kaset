import SwiftUI

@available(macOS 26.0, *)
struct OfflineStorageView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case playlists
        case songs

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .playlists: String(localized: "Playlists")
            case .songs: String(localized: "Songs")
            }
        }
    }

    @Environment(OfflineStorageManager.self) private var offlineStorageManager
    @Environment(PlayerService.self) private var playerService

    let client: any YTMusicClientProtocol

    @State private var selectedTab: Tab = .playlists
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.header

                Picker("View", selection: self.$selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.displayName).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityID.OfflineStorage.container)

                if self.selectedTab == .playlists {
                    self.playlistsTab
                } else {
                    self.songsTab
                }
            }
            .padding(24)
        }
        .navigationTitle(String(localized: "Offline Storage"))
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            if self.offlineStorageManager.libraryPlaylists.isEmpty {
                await self.offlineStorageManager.refreshLibraryPlaylists(using: self.client)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Offline Storage")
                    .font(.largeTitle.bold())

                Text(String(localized: "Saved playlists and songs are stored locally for offline access."))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    self.summaryMetric(
                        title: String(localized: "Playlists"),
                        value: "\(self.offlineStorageManager.totalPlaylistCount)"
                    )
                    self.summaryMetric(
                        title: String(localized: "Songs"),
                        value: "\(self.offlineStorageManager.totalSongCount)"
                    )
                }

                HStack(spacing: 12) {
                    if self.offlineStorageManager.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                        Text(self.offlineStorageManager.progressMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let lastErrorMessage = self.offlineStorageManager.lastErrorMessage {
                        Label(lastErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }

                    Button {
                        Task {
                            self.isRefreshing = true
                            defer { self.isRefreshing = false }
                            await self.offlineStorageManager.refreshLibraryPlaylists(using: self.client)
                        }
                    } label: {
                        Label(
                            self.isRefreshing ? String(localized: "Refreshing...") : String(localized: "Refresh"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(self.isRefreshing)
                    .accessibilityIdentifier(AccessibilityID.OfflineStorage.refreshButton)
                }
            }
        }
    }

    private var playlistsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.offlineStorageManager.playlists.isEmpty {
                self.emptyState(
                    title: String(localized: "No offline playlists yet"),
                    message: String(localized: "Enable offline storage or save a playlist from its detail view to populate this list.")
                )
            } else {
                ForEach(self.offlineStorageManager.playlists) { playlistRecord in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(self.offlineStorageManager.playlistSongs(for: playlistRecord.id)) { song in
                                self.songRow(song, sourcePlaylistTitles: playlistRecord.playlist.title)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        self.playlistRow(playlistRecord)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.OfflineStorage.playlistTab)
    }

    private var songsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.offlineStorageManager.songs.isEmpty {
                self.emptyState(
                    title: String(localized: "No offline songs yet"),
                    message: String(localized: "Save an individual song from its context menu or save a playlist to include its tracks.")
                )
            } else {
                ForEach(self.offlineStorageManager.songs) { song in
                    self.songRow(
                        song,
                        sourcePlaylistTitles: song.sourcePlaylistTitles.isEmpty
                            ? String(localized: "Manual save")
                            : song.sourcePlaylistTitles.joined(separator: ", ")
                    )
                    Divider()
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.OfflineStorage.songsTab)
    }

    @ViewBuilder
    private func playlistRow(_ record: OfflineStorageManager.OfflinePlaylistRecord) -> some View {
        let songs = self.offlineStorageManager.playlistSongs(for: record.id).map(\.song).filter(\.isPlayable)
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: record.playlist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 54, height: 54)
                .clipShape(.rect(cornerRadius: 6))

                Button {
                    Task { await self.playerService.playQueue(songs, startingAt: 0) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                        .background(.regularMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)
                .offset(x: 4, y: 4)
                .accessibilityLabel(Text("Play"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.playlist.title)
                    .font(.headline)
                Text("\(record.songCount) songs • \(record.savedAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let author = record.playlist.author?.name {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                self.offlineStorageManager.removePlaylist(playlistId: record.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Delete Offline"))
        }
        .padding(.horizontal, 4)
    }

    private func songRow(_ songRecord: OfflineStorageManager.OfflineSongRecord, sourcePlaylistTitles: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                SongThumbnailView(
                    song: songRecord.song,
                    localThumbnailURL: self.offlineStorageManager.localThumbnailURL(for: songRecord.videoId),
                    size: 44,
                    cornerRadius: 6
                )

                Button {
                    Task { await self.playerService.play(song: songRecord.song) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .background(.regularMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: 3)
                .accessibilityLabel(Text("Play"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(songRecord.song.title)
                    .font(.subheadline.weight(.semibold))
                Text(songRecord.song.artistsDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(sourcePlaylistTitles) • \(songRecord.fileExtension.uppercased()) • \(songRecord.savedAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                self.offlineStorageManager.removeSong(videoId: songRecord.videoId)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Delete Offline"))
        }
        .padding(.horizontal, 4)
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, alignment: .trailing)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "externaldrive")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

@available(macOS 26.0, *)
#Preview {
    OfflineStorageView(client: MockUITestYTMusicClient())
        .environment(OfflineStorageManager(skipLoad: true, skipPersistence: true))
        .environment(PlayerService())
        .frame(width: 900, height: 700)
}
