import Foundation
import os

/// Parser for the signed-in user's Library browse responses.
enum LibraryContentParser {
    private static let logger = DiagnosticsLogger.api

    /// Source used for followed-artist content in a combined Library response.
    enum LibraryArtistsSource {
        case dedicated
        case landingFallback
    }

    /// Parsed Library content from YouTube Music browse responses.
    struct LibraryContent {
        let playlists: [Playlist]
        let artists: [Artist]
        let podcastShows: [PodcastShow]
        let uploadedSongsPlaylist: Playlist?
        let artistsSource: LibraryArtistsSource

        init(
            playlists: [Playlist],
            artists: [Artist],
            podcastShows: [PodcastShow],
            uploadedSongsPlaylist: Playlist? = nil,
            artistsSource: LibraryArtistsSource = .dedicated
        ) {
            self.playlists = playlists
            self.artists = artists
            self.podcastShows = podcastShows
            self.uploadedSongsPlaylist = uploadedSongsPlaylist
            self.artistsSource = artistsSource
        }
    }

    private struct LibraryItemCandidate {
        let sourceName: String
        let browseId: String
        let browseEndpoint: [String: Any]
        let title: String
        let subtitle: String?
        let thumbnailURL: URL?
        let allowsRadioPlaylist: Bool
        let renderer: [String: Any]
    }

    static func parseLibraryPlaylists(_ data: [String: Any]) -> [Playlist] {
        self.parseLibraryContent(data).playlists
    }

    /// Parses library content from browse response, returning playlists, artists, and podcast shows.
    static func parseLibraryContent(_ data: [String: Any]) -> LibraryContent {
        var playlists: [Playlist] = []
        var artists: [Artist] = []
        var podcastShows: [PodcastShow] = []

        for sectionData in Self.extractLibrarySections(from: data) {
            Self.appendLibraryItems(
                from: sectionData,
                playlists: &playlists,
                artists: &artists,
                podcastShows: &podcastShows
            )
        }

        return LibraryContent(playlists: playlists, artists: artists, podcastShows: podcastShows)
    }

    /// Merges library playlists using the dedicated endpoint as authoritative while retaining landing-only items.
    static func mergedLibraryPlaylists(dedicated dedicatedPlaylists: [Playlist], fallback fallbackPlaylists: [Playlist]) -> [Playlist] {
        var mergedPlaylists = dedicatedPlaylists
        var seenPlaylistKeys = Set(dedicatedPlaylists.map { LibraryContentIdentity.playlistKey(for: $0) })

        for playlist in fallbackPlaylists {
            let playlistKey = LibraryContentIdentity.playlistKey(for: playlist)
            guard seenPlaylistKeys.insert(playlistKey).inserted else { continue }
            mergedPlaylists.append(playlist)
        }

        return mergedPlaylists
    }

    /// Parses artists from the dedicated library artists browse response.
    static func parseLibraryArtists(_ data: [String: Any]) -> [Artist] {
        var artists: [Artist] = []
        var ignoredPlaylists: [Playlist] = []
        var ignoredPodcastShows: [PodcastShow] = []

        for sectionData in Self.extractLibrarySections(from: data) {
            Self.appendLibraryItems(
                from: sectionData,
                playlists: &ignoredPlaylists,
                artists: &artists,
                podcastShows: &ignoredPodcastShows
            )
        }

        return LibraryContentIdentity.deduplicatedArtists(artists)
    }

    /// Parses the uploaded songs browse endpoint into a virtual playlist tile for Library.
    static func parseUploadedSongsPlaylist(_ data: [String: Any]) -> Playlist? {
        let detail = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: Playlist.uploadedSongsBrowseID).detail
        guard !detail.tracks.isEmpty || (detail.trackCount ?? 0) > 0 else {
            return nil
        }

        let title = detail.title == "Unknown Playlist" ? "Uploaded Songs" : detail.title
        return Playlist(
            id: Playlist.uploadedSongsBrowseID,
            title: title,
            description: nil,
            thumbnailURL: detail.thumbnailURL ?? detail.tracks.first?.thumbnailURL,
            trackCount: max(detail.trackCount ?? 0, detail.tracks.count),
            author: Artist.inline(name: "Uploads", namespace: "library-upload"),
            canDelete: false
        )
    }

    private static func extractLibrarySections(from data: [String: Any]) -> [[String: Any]] {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return []
        }

        return sectionContents
    }

    private static func appendLibraryItems(
        from sectionData: [String: Any],
        playlists: inout [Playlist],
        artists: inout [Artist],
        podcastShows: inout [PodcastShow]
    ) {
        // Try gridRenderer
        if let gridRenderer = sectionData["gridRenderer"] as? [String: Any],
           let items = gridRenderer["items"] as? [[String: Any]]
        {
            for itemData in items {
                guard let twoRowRenderer = itemData["musicTwoRowItemRenderer"] as? [String: Any] else { continue }
                Self.appendLibraryItem(
                    Self.twoRowCandidate(from: twoRowRenderer),
                    playlists: &playlists,
                    artists: &artists,
                    podcastShows: &podcastShows
                )
            }
        }

        // Try itemSectionRenderer > musicShelfRenderer
        if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
           let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
        {
            for itemContent in itemContents {
                guard let shelfRenderer = itemContent["musicShelfRenderer"] as? [String: Any],
                      let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                else { continue }

                Self.appendResponsiveLibraryItems(
                    shelfContents,
                    playlists: &playlists,
                    artists: &artists,
                    podcastShows: &podcastShows
                )
            }
        }

        // Try musicShelfRenderer directly
        if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
           let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
        {
            Self.appendResponsiveLibraryItems(
                shelfContents,
                playlists: &playlists,
                artists: &artists,
                podcastShows: &podcastShows
            )
        }
    }

    private static func appendResponsiveLibraryItems(
        _ shelfContents: [[String: Any]],
        playlists: inout [Playlist],
        artists: inout [Artist],
        podcastShows: inout [PodcastShow]
    ) {
        for shelfItem in shelfContents {
            guard let responsiveRenderer = shelfItem["musicResponsiveListItemRenderer"] as? [String: Any] else { continue }
            Self.appendLibraryItem(
                Self.responsiveCandidate(from: responsiveRenderer),
                playlists: &playlists,
                artists: &artists,
                podcastShows: &podcastShows
            )
        }
    }

    private static func twoRowCandidate(from data: [String: Any]) -> LibraryItemCandidate? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            self.logger.debug("parseLibraryItem: No browseId found")
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        return LibraryItemCandidate(
            sourceName: "parseLibraryItem",
            browseId: browseId,
            browseEndpoint: browseEndpoint,
            title: ParsingHelpers.extractTitle(from: data) ?? "Unknown",
            subtitle: ParsingHelpers.extractSubtitle(from: data),
            thumbnailURL: thumbnails.last.flatMap { URL(string: $0) },
            allowsRadioPlaylist: true,
            renderer: data
        )
    }

    private static func responsiveCandidate(from data: [String: Any]) -> LibraryItemCandidate? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            self.logger.debug("parseLibraryItemFromResponsive: No browseId found, keys: \(Array(data.keys))")
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        return LibraryItemCandidate(
            sourceName: "parseLibraryItemFromResponsive",
            browseId: browseId,
            browseEndpoint: browseEndpoint,
            title: ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown",
            subtitle: ParsingHelpers.extractSubtitleFromFlexColumns(data),
            thumbnailURL: thumbnails.last.flatMap { URL(string: $0) },
            allowsRadioPlaylist: false,
            renderer: data
        )
    }

    private static func appendLibraryItem(
        _ candidate: LibraryItemCandidate?,
        playlists: inout [Playlist],
        artists: inout [Artist],
        podcastShows: inout [PodcastShow]
    ) {
        guard let candidate else { return }

        Self.logger.info("\(candidate.sourceName): browseId=\(candidate.browseId, privacy: .public), title=\(candidate.title, privacy: .public)")

        if candidate.browseId.hasPrefix("MPSPP") {
            podcastShows.append(Self.podcastShow(from: candidate))
            Self.logger.info("\(candidate.sourceName): Added podcast show: \(candidate.title)")
        } else if Self.isPlaylistBrowseID(candidate.browseId, allowsRadioPlaylist: candidate.allowsRadioPlaylist) {
            playlists.append(Self.playlist(from: candidate))
            Self.logger.info("\(candidate.sourceName): Added playlist: \(candidate.title)")
        } else if Artist.isNavigableId(candidate.browseId) {
            artists.append(Self.artist(from: candidate))
            Self.logger.info("\(candidate.sourceName): Added artist: \(candidate.title)")
        } else if candidate.sourceName == "parseLibraryItemFromResponsive" {
            Self.logger.info("\(candidate.sourceName): Skipping unknown prefix: \(candidate.browseId)")
        }
    }

    private static func podcastShow(from candidate: LibraryItemCandidate) -> PodcastShow {
        PodcastShow(
            id: candidate.browseId,
            title: candidate.title,
            author: candidate.subtitle,
            description: nil,
            thumbnailURL: candidate.thumbnailURL,
            episodeCount: nil
        )
    }

    private static func playlist(from candidate: LibraryItemCandidate) -> Playlist {
        Playlist(
            id: candidate.browseId,
            title: candidate.title,
            description: nil,
            thumbnailURL: candidate.thumbnailURL,
            trackCount: nil,
            author: candidate.subtitle.map { Artist.inline(name: $0, namespace: "playlist-author") },
            canDelete: PlaylistEditability.canDeletePlaylist(from: candidate.renderer)
        )
    }

    private static func artist(from candidate: LibraryItemCandidate) -> Artist {
        let pageType = ParsingHelpers.extractPageType(from: candidate.browseEndpoint)
        return Artist(
            id: candidate.browseId,
            name: candidate.title,
            thumbnailURL: candidate.thumbnailURL,
            profileKind: Artist.profileKind(forPageType: pageType)
        )
    }

    private static func isPlaylistBrowseID(_ browseID: String, allowsRadioPlaylist: Bool) -> Bool {
        browseID.hasPrefix("VL") || browseID.hasPrefix("PL") || (allowsRadioPlaylist && browseID.hasPrefix("RDCLAK"))
    }
}
