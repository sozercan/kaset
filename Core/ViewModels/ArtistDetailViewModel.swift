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
        guard loadingState != .loading else { return }

        loadingState = .loading
        let artistName = artist.name
        logger.info("Loading artist: \(artistName)")

        do {
            var detail = try await client.getArtist(id: artist.id)

            // Use original artist info as fallback if API returned unknown/empty values
            if detail.name == "Unknown Artist", artist.name != "Unknown Artist" {
                let mergedArtist = Artist(
                    id: artist.id,
                    name: artist.name,
                    thumbnailURL: detail.thumbnailURL ?? artist.thumbnailURL
                )
                detail = ArtistDetail(
                    artist: mergedArtist,
                    description: detail.description,
                    songs: detail.songs,
                    albums: detail.albums,
                    thumbnailURL: detail.thumbnailURL ?? artist.thumbnailURL,
                    channelId: detail.channelId,
                    isSubscribed: detail.isSubscribed,
                    subscriberCount: detail.subscriberCount,
                    hasMoreSongs: detail.hasMoreSongs,
                    songsBrowseId: detail.songsBrowseId,
                    songsParams: detail.songsParams
                )
            }

            artistDetail = detail
            loadingState = .loaded
            let songCount = detail.songs.count
            logger.info("Artist loaded: \(songCount) songs")
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            logger.debug("Artist detail load cancelled")
            loadingState = .idle
        } catch {
            let errorMessage = error.localizedDescription
            logger.error("Failed to load artist: \(errorMessage)")
            loadingState = .error(errorMessage)
        }
    }

    /// Refreshes the artist details.
    func refresh() async {
        artistDetail = nil
        showAllSongs = false
        await load()
    }

    /// Toggles subscription status for the artist.
    func toggleSubscription() async {
        guard let detail = artistDetail,
              let channelId = detail.channelId
        else {
            logger.warning("Cannot toggle subscription: missing channel ID")
            return
        }

        isSubscribing = true
        defer { isSubscribing = false }

        do {
            if detail.isSubscribed {
                try await client.unsubscribeFromArtist(channelId: channelId)
                artistDetail?.isSubscribed = false
                logger.info("Unsubscribed from artist: \(detail.name)")
            } else {
                try await client.subscribeToArtist(channelId: channelId)
                artistDetail?.isSubscribed = true
                logger.info("Subscribed to artist: \(detail.name)")
            }
        } catch {
            logger.error("Failed to toggle subscription: \(error.localizedDescription)")
        }
    }

    /// The songs to display based on showAllSongs state.
    var displayedSongs: [Song] {
        guard let songs = artistDetail?.songs else { return [] }
        if showAllSongs {
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
}
