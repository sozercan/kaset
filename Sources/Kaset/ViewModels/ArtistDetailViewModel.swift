import Foundation
import Observation
import os

@MainActor
@Observable
final class ArtistDetailViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var artistDetail: ArtistDetail?

    private(set) var isSubscribing: Bool = false

    private(set) var subscriptionError: String?

    var showAllSongs: Bool = false

    static let previewSongCount = 5

    private let artist: Artist
    let client: any YTMusicClientProtocol
    private let libraryViewModel: LibraryViewModel?
    private let logger = DiagnosticsLogger.api

    init(
        artist: Artist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel? = nil
    ) {
        self.artist = artist
        self.client = client
        self.libraryViewModel = libraryViewModel
    }

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        let artistName = self.artist.name
        self.logger.info("Loading artist: \(artistName)")

        do {
            var detail = try await client.getArtist(id: self.artist.id)
            detail = self.mergedArtistDetail(detail)

            self.artistDetail = detail
            self.loadingState = .loaded
            let songCount = detail.songs.count
            self.logger.info("Artist loaded: \(songCount) songs")
        } catch is CancellationError {
            self.logger.debug("Artist detail load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load artist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        self.artistDetail = nil
        self.showAllSongs = false
        await self.load()
    }

    func toggleSubscription() async {
        guard let detail = artistDetail,
              let channelId = detail.channelId
        else {
            self.logger.warning("Cannot toggle subscription: missing channel ID")
            return
        }

        self.isSubscribing = true
        self.subscriptionError = nil
        defer { isSubscribing = false }

        do {
            if detail.isSubscribed {
                try await SongActionsHelper.unsubscribeFromArtist(
                    detail.artist,
                    channelId: channelId,
                    client: self.client,
                    libraryViewModel: self.libraryViewModel
                )
                self.artistDetail?.isSubscribed = false
            } else {
                try await SongActionsHelper.subscribeToArtist(
                    detail.artist,
                    channelId: channelId,
                    client: self.client,
                    libraryViewModel: self.libraryViewModel
                )
                self.artistDetail?.isSubscribed = true
            }
        } catch {
            self.subscriptionError = "Failed to update subscription. Please try again."
            self.logger.error("Failed to toggle subscription: \(error.localizedDescription)")
        }
    }

    var displayedSongs: [Song] {
        guard let songs = artistDetail?.songs else { return [] }
        if self.showAllSongs {
            return songs
        }
        return Array(songs.prefix(Self.previewSongCount))
    }

    var hasMoreSongs: Bool {
        guard let detail = artistDetail else { return false }
        return detail.songs.count > Self.previewSongCount || detail.hasMoreSongs
    }

    private(set) var allSongs: [Song]?

    func getAllSongs() async -> [Song] {
        if let allSongs {
            return allSongs
        }

        guard let detail = artistDetail,
              let browseId = detail.songsBrowseId
        else {
            return self.artistDetail?.songs ?? []
        }

        self.logger.info("Fetching all artist songs for queue: \(browseId)")

        do {
            let songs = try await client.getArtistSongs(
                browseId: browseId,
                params: detail.songsParams
            )

            if !songs.isEmpty {
                self.allSongs = songs
                return songs
            }
        } catch {
            self.logger.warning("Failed to fetch all songs: \(error.localizedDescription)")
        }

        return self.artistDetail?.songs ?? []
    }

    private func mergedArtistDetail(_ detail: ArtistDetail) -> ArtistDetail {
        let resolvedName = detail.name == "Unknown Artist" && self.artist.name != "Unknown Artist"
            ? self.artist.name
            : detail.artist.name
        let resolvedThumbnailURL = detail.thumbnailURL ?? self.artist.thumbnailURL
        let resolvedProfileKind = detail.profileKind == .unknown ? self.artist.profileKind : detail.profileKind

        guard resolvedName != detail.artist.name
            || resolvedThumbnailURL != detail.thumbnailURL
            || resolvedProfileKind != detail.profileKind
        else {
            return detail
        }

        let mergedArtist = Artist(
            id: detail.artist.id,
            name: resolvedName,
            thumbnailURL: resolvedThumbnailURL,
            subtitle: detail.artist.subtitle ?? self.artist.subtitle,
            profileKind: resolvedProfileKind
        )

        return ArtistDetail(
            artist: mergedArtist,
            description: detail.description,
            songs: detail.songs,
            songsSectionTitle: detail.songsSectionTitle,
            orderedSections: detail.orderedSections,
            albums: detail.albums,
            singles: detail.singles,
            episodes: detail.episodes,
            playlistsByArtist: detail.playlistsByArtist,
            relatedArtists: detail.relatedArtists,
            podcasts: detail.podcasts,
            moreEndpoints: detail.moreEndpoints,
            thumbnailURL: resolvedThumbnailURL,
            channelId: detail.channelId,
            isSubscribed: detail.isSubscribed,
            subscriberCount: detail.subscriberCount,
            subscribedButtonText: detail.subscribedButtonText,
            unsubscribedButtonText: detail.unsubscribedButtonText,
            monthlyAudience: detail.monthlyAudience,
            hasMoreSongs: detail.hasMoreSongs,
            songsBrowseId: detail.songsBrowseId,
            songsParams: detail.songsParams,
            mixPlaylistId: detail.mixPlaylistId,
            mixVideoId: detail.mixVideoId
        )
    }
}
