import Foundation

/// Parser for search responses from YouTube Music API.
enum SearchResponseParser {
    /// Parses a search response.
    static func parse(_ data: [String: Any]) -> SearchResponse {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []

        // Navigate to contents
        guard let contents = data["contents"] as? [String: Any],
              let tabbedSearchResults = contents["tabbedSearchResultsRenderer"] as? [String: Any],
              let tabs = tabbedSearchResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return SearchResponse.empty
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData) {
                        switch item {
                        case let .song(song):
                            songs.append(song)
                        case let .album(album):
                            albums.append(album)
                        case let .artist(artist):
                            artists.append(artist)
                        case let .playlist(playlist):
                            playlists.append(playlist)
                        }
                    }
                }
            }
        }

        return SearchResponse(songs: songs, albums: albums, artists: artists, playlists: playlists)
    }

    // MARK: - Item Parsing

    private static func parseSearchResultItem(_ data: [String: Any]) -> SearchResultItem? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        // Try to get videoId for songs
        if let playlistItemData = responsiveRenderer["playlistItemData"] as? [String: Any],
           let videoId = playlistItemData["videoId"] as? String
        {
            return self.parseSongFromResponsiveRenderer(responsiveRenderer, videoId: videoId)
        }

        // Check navigation endpoint for other types
        if let navigationEndpoint = responsiveRenderer["navigationEndpoint"] as? [String: Any],
           let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
            let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
            let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown"
            let subtitle = ParsingHelpers.extractSubtitleFromFlexColumns(responsiveRenderer)

            if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                let album = Album(
                    id: browseId,
                    title: title,
                    artists: nil,
                    thumbnailURL: thumbnailURL,
                    year: nil,
                    trackCount: nil
                )
                return .album(album)
            } else if browseId.hasPrefix("UC") {
                let artist = Artist(id: browseId, name: title, thumbnailURL: thumbnailURL)
                return .artist(artist)
            } else if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
                let playlist = Playlist(
                    id: browseId,
                    title: title,
                    description: nil,
                    thumbnailURL: thumbnailURL,
                    trackCount: nil,
                    author: subtitle
                )
                return .playlist(playlist)
            }
        }

        return nil
    }

    private static func parseSongFromResponsiveRenderer(
        _ data: [String: Any],
        videoId: String
    ) -> SearchResultItem? {
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let artists = ParsingHelpers.extractArtistsFromFlexColumns(data)

        let song = Song(
            id: videoId,
            title: title,
            artists: artists,
            album: nil,
            duration: nil,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
        return .song(song)
    }
}
