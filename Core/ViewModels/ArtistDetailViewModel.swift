import Foundation
import Observation
import os

/// View model for the ArtistDetailView.
@MainActor
@Observable
final class ArtistDetailViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// The loaded artist detail.
    private(set) var artistDetail: ArtistDetail?

    /// Whether a subscription operation is in progress.
    private(set) var isSubscribing: Bool = false

    /// Error message from subscription toggle (nil if no error).
    private(set) var subscriptionError: String?

    /// Whether to show all songs instead of limited preview.
    var showAllSongs: Bool = false

    /// Number of songs to show in preview mode.
    static let previewSongCount = 5

    private let artist: Artist
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(artist: Artist, client: any YTMusicClientProtocol) {
        self.artist = artist
        self.client = client
    }

    /// Loads the artist details including songs and albums.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        let artistName = self.artist.name
        self.logger.info("Loading artist: \(artistName)")

        do {
            var detail = try await client.getArtist(id: self.artist.id)

            // Use original artist info as fallback if API returned unknown/empty values
            if detail.name == "Unknown Artist", self.artist.name != "Unknown Artist" {
                let mergedArtist = Artist(
                    id: artist.id,
                    name: self.artist.name,
                    thumbnailURL: detail.thumbnailURL ?? self.artist.thumbnailURL
                )
                detail = ArtistDetail(
                    artist: mergedArtist,
                    description: detail.description,
                    songs: detail.songs,
                    albums: detail.albums,
                    thumbnailURL: detail.thumbnailURL ?? self.artist.thumbnailURL,
                    channelId: detail.channelId,
                    isSubscribed: detail.isSubscribed,
                    subscriberCount: detail.subscriberCount,
                    hasMoreSongs: detail.hasMoreSongs,
                    songsBrowseId: detail.songsBrowseId,
                    songsParams: detail.songsParams
                )
            }

            self.artistDetail = detail
            self.loadingState = .loaded
            let songCount = detail.songs.count
            self.logger.info("Artist loaded: \(songCount) songs")
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Artist detail load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load artist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Refreshes the artist details.
    func refresh() async {
        self.artistDetail = nil
        self.showAllSongs = false
        await self.load()
    }

    /// Toggles subscription status for the artist.
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
                try await self.client.unsubscribeFromArtist(channelId: channelId)
                self.artistDetail?.isSubscribed = false
                self.logger.info("Unsubscribed from artist: \(detail.name)")
            } else {
                try await self.client.subscribeToArtist(channelId: channelId)
                self.artistDetail?.isSubscribed = true
                self.logger.info("Subscribed to artist: \(detail.name)")
            }
        } catch {
            self.subscriptionError = "Failed to update subscription. Please try again."
            self.logger.error("Failed to toggle subscription: \(error.localizedDescription)")
        }
    }

    /// The songs to display based on showAllSongs state.
    var displayedSongs: [Song] {
        guard let songs = artistDetail?.songs else { return [] }
        if self.showAllSongs {
            return songs
        }
        return Array(songs.prefix(Self.previewSongCount))
    }

    /// Whether there are more songs to show (either loaded or available via API).
    var hasMoreSongs: Bool {
        guard let detail = artistDetail else { return false }
        // Show "See all" if there are more songs loaded than preview count,
        // OR if the API indicates more songs are available
        return detail.songs.count > Self.previewSongCount || detail.hasMoreSongs
    }

    /// All songs for the artist (fetched on demand).
    private(set) var allSongs: [Song]?

    /// Fetches all songs for the artist if not already loaded.
    /// Returns all songs for queue playback.
    func getAllSongs() async -> [Song] {
        // If we already have all songs cached, return them
        if let allSongs {
            return allSongs
        }

        // If there's no browse ID, we already have all the songs from artistDetail
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

        // Fallback to existing songs
        return self.artistDetail?.songs ?? []
    }
}
