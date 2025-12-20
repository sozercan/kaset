import Foundation
import Observation
import os

/// View model for the ArtistDetailView.
@MainActor
@Observable
final class ArtistDetailViewModel {
    /// Loading states for the view.
    enum LoadingState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// The loaded artist detail.
    private(set) var artistDetail: ArtistDetail?

    private let artist: Artist
    private let client: YTMusicClient
    private let logger = DiagnosticsLogger.api

    init(artist: Artist, client: YTMusicClient) {
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
                    thumbnailURL: detail.thumbnailURL ?? artist.thumbnailURL
                )
            }

            artistDetail = detail
            loadingState = .loaded
            let songCount = detail.songs.count
            logger.info("Artist loaded: \(songCount) songs")
        } catch {
            let errorMessage = error.localizedDescription
            logger.error("Failed to load artist: \(errorMessage)")
            loadingState = .error(errorMessage)
        }
    }

    /// Refreshes the artist details.
    func refresh() async {
        artistDetail = nil
        await load()
    }
}
