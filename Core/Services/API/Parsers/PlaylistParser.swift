import Foundation
import os

/// Parser for playlist-related responses from YouTube Music API.
enum PlaylistParser {
    private static let logger = DiagnosticsLogger.api

    /// Parsed header data for a playlist.
    private struct HeaderData {
        var title: String = "Unknown Playlist"
        var description: String?
        var thumbnailURL: URL?
        var author: String?
        var duration: String?
    }

    /// Parses library playlists from browse response.
    static func parseLibraryPlaylists(_ data: [String: Any]) -> [Playlist] {
        var playlists: [Playlist] = []

        // Navigate to contents
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

        for sectionData in sectionContents {
            // Try gridRenderer
            if let gridRenderer = sectionData["gridRenderer"] as? [String: Any],
               let items = gridRenderer["items"] as? [[String: Any]]
            {
                for itemData in items {
                    if let twoRowRenderer = itemData["musicTwoRowItemRenderer"] as? [String: Any],
                       let playlist = parsePlaylistFromTwoRowRenderer(twoRowRenderer)
                    {
                        playlists.append(playlist)
                    }
                }
            }

            // Try itemSectionRenderer > musicShelfRenderer
            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemContent in itemContents {
                    if let shelfRenderer = itemContent["musicShelfRenderer"] as? [String: Any],
                       let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                    {
                        for shelfItem in shelfContents {
                            if let responsiveRenderer = shelfItem["musicResponsiveListItemRenderer"] as? [String: Any],
                               let playlist = parsePlaylistFromResponsiveRenderer(responsiveRenderer)
                            {
                                playlists.append(playlist)
                            }
                        }
                    }
                }
            }
        }

        return playlists
    }

    /// Parses playlist detail from browse response.
    static func parsePlaylistDetail(_ data: [String: Any], playlistId: String) -> PlaylistDetail {
        let header = self.parsePlaylistHeader(data)

        // Parse tracks
        let tracks = self.parsePlaylistTracks(data, fallbackThumbnailURL: header.thumbnailURL)

        let playlist = Playlist(
            id: playlistId,
            title: header.title,
            description: header.description,
            thumbnailURL: header.thumbnailURL,
            trackCount: tracks.count,
            author: header.author
        )

        return PlaylistDetail(playlist: playlist, tracks: tracks, duration: header.duration)
    }

    // MARK: - Header Parsing

    private static func parsePlaylistHeader(_ data: [String: Any]) -> HeaderData {
        var header = HeaderData()
        // Try musicDetailHeaderRenderer
        if let headerDict = data["header"] as? [String: Any],
           let headerRenderer = headerDict["musicDetailHeaderRenderer"] as? [String: Any]
        {
            if let text = ParsingHelpers.extractTitle(from: headerRenderer) {
                header.title = text
            }

            if let descData = headerRenderer["description"] as? [String: Any],
               let runs = descData["runs"] as? [[String: Any]]
            {
                header.description = runs.compactMap { $0["text"] as? String }.joined()
            }

            let thumbnails = ParsingHelpers.extractThumbnails(from: headerRenderer)
            header.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            if let subtitleData = headerRenderer["subtitle"] as? [String: Any],
               let runs = subtitleData["runs"] as? [[String: Any]]
            {
                let texts = runs.compactMap { $0["text"] as? String }
                header.author = texts.first
            }

            if let secondSubtitleData = headerRenderer["secondSubtitle"] as? [String: Any],
               let runs = secondSubtitleData["runs"] as? [[String: Any]]
            {
                let texts = runs.compactMap { $0["text"] as? String }
                header.duration = texts.joined()
            }
        }

        // Try musicImmersiveHeaderRenderer
        if header.title == "Unknown Playlist",
           let headerDict = data["header"] as? [String: Any],
           let immersiveHeader = headerDict["musicImmersiveHeaderRenderer"] as? [String: Any]
        {
            if let text = ParsingHelpers.extractTitle(from: immersiveHeader) {
                header.title = text
            }

            let thumbnails = ParsingHelpers.extractThumbnails(from: immersiveHeader)
            header.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            if let descData = immersiveHeader["description"] as? [String: Any],
               let runs = descData["runs"] as? [[String: Any]]
            {
                header.description = runs.compactMap { $0["text"] as? String }.joined()
            }
        }

        // Try musicEditablePlaylistDetailHeaderRenderer
        if header.title == "Unknown Playlist",
           let headerDict = data["header"] as? [String: Any],
           let editableHeader = headerDict["musicEditablePlaylistDetailHeaderRenderer"] as? [String: Any],
           let nestedHeaderData = editableHeader["header"] as? [String: Any],
           let detailHeader = nestedHeaderData["musicDetailHeaderRenderer"] as? [String: Any]
        {
            if let text = ParsingHelpers.extractTitle(from: detailHeader) {
                header.title = text
            }

            let thumbnails = ParsingHelpers.extractThumbnails(from: detailHeader)
            header.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            if let subtitleData = detailHeader["subtitle"] as? [String: Any],
               let runs = subtitleData["runs"] as? [[String: Any]]
            {
                let texts = runs.compactMap { $0["text"] as? String }
                header.author = texts.first
            }
        }

        return header
    }

    // MARK: - Track Parsing

    private static func parsePlaylistTracks(_ data: [String: Any], fallbackThumbnailURL: URL?) -> [Song] {
        var tracks: [Song] = []

        if let contents = data["contents"] as? [String: Any] {
            // Try singleColumnBrowseResultsRenderer path
            if let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
               let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
               let firstTab = tabs.first,
               let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
               let tabContent = tabRenderer["content"] as? [String: Any],
               let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
               let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
            {
                tracks.append(contentsOf: self.parseTracksFromSections(sectionContents, fallbackThumbnailURL: fallbackThumbnailURL))
            }

            // Try twoColumnBrowseResultsRenderer path
            if tracks.isEmpty,
               let twoColumnRenderer = contents["twoColumnBrowseResultsRenderer"] as? [String: Any]
            {
                if let secondaryContents = twoColumnRenderer["secondaryContents"] as? [String: Any],
                   let sectionListRenderer = secondaryContents["sectionListRenderer"] as? [String: Any],
                   let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
                {
                    tracks.append(contentsOf: self.parseTracksFromSections(sectionContents, fallbackThumbnailURL: fallbackThumbnailURL))
                }

                if tracks.isEmpty,
                   let tabs = twoColumnRenderer["tabs"] as? [[String: Any]],
                   let firstTab = tabs.first,
                   let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
                   let tabContent = tabRenderer["content"] as? [String: Any],
                   let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
                   let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
                {
                    tracks.append(contentsOf: self.parseTracksFromSections(sectionContents, fallbackThumbnailURL: fallbackThumbnailURL))
                }
            }
        }

        // Try recursive search if no tracks found
        if tracks.isEmpty {
            if let contents = data["contents"] as? [String: Any] {
                for (_, value) in contents {
                    if let renderer = value as? [String: Any] {
                        tracks.append(contentsOf: self.findTracksRecursively(in: renderer, depth: 0, fallbackThumbnailURL: fallbackThumbnailURL))
                        if !tracks.isEmpty {
                            break
                        }
                    }
                }
            }
        }

        return tracks
    }

    private static func parseTracksFromSections(_ sections: [[String: Any]], fallbackThumbnailURL: URL?) -> [Song] {
        var tracks: [Song] = []

        for sectionData in sections {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let track = parseTrackItem(itemData, fallbackThumbnailURL: fallbackThumbnailURL) {
                        tracks.append(track)
                    }
                }
            }

            if let playlistShelfRenderer = sectionData["musicPlaylistShelfRenderer"] as? [String: Any],
               let playlistContents = playlistShelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in playlistContents {
                    if let track = parseTrackItem(itemData, fallbackThumbnailURL: fallbackThumbnailURL) {
                        tracks.append(track)
                    }
                }
            }
        }

        return tracks
    }

    private static func parseTrackItem(_ data: [String: Any], fallbackThumbnailURL: URL?) -> Song? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        guard let videoId = ParsingHelpers.extractVideoId(from: responsiveRenderer) else {
            return nil
        }

        let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown"
        let artists = ParsingHelpers.extractArtistsFromFlexColumns(responsiveRenderer)
        let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) } ?? fallbackThumbnailURL
        let duration = ParsingHelpers.extractDurationFromFlexColumns(responsiveRenderer)

        return Song(
            id: videoId,
            title: title,
            artists: artists,
            album: nil,
            duration: duration,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
    }

    private static func findTracksRecursively(in data: [String: Any], depth: Int, fallbackThumbnailURL: URL?) -> [Song] {
        guard depth < 10 else { return [] }

        var tracks: [Song] = []

        if let contents = data["contents"] as? [[String: Any]] {
            for item in contents {
                if let track = parseTrackItem(item, fallbackThumbnailURL: fallbackThumbnailURL) {
                    tracks.append(track)
                }
            }
        }

        if tracks.isEmpty {
            for (_, value) in data {
                if let dict = value as? [String: Any] {
                    tracks.append(contentsOf: self.findTracksRecursively(in: dict, depth: depth + 1, fallbackThumbnailURL: fallbackThumbnailURL))
                } else if let array = value as? [[String: Any]] {
                    for item in array {
                        tracks.append(contentsOf: self.findTracksRecursively(in: item, depth: depth + 1, fallbackThumbnailURL: fallbackThumbnailURL))
                    }
                }
                if !tracks.isEmpty { break }
            }
        }

        return tracks
    }

    // MARK: - Helper Parsers

    private static func parsePlaylistFromTwoRowRenderer(_ data: [String: Any]) -> Playlist? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitle(from: data) ?? "Unknown Playlist"

        return Playlist(
            id: browseId,
            title: title,
            description: nil,
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: ParsingHelpers.extractSubtitle(from: data)
        )
    }

    private static func parsePlaylistFromResponsiveRenderer(_ data: [String: Any]) -> Playlist? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String,
              browseId.hasPrefix("VL") || browseId.hasPrefix("PL")
        else {
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown Playlist"

        return Playlist(
            id: browseId,
            title: title,
            description: nil,
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: ParsingHelpers.extractSubtitleFromFlexColumns(data)
        )
    }
}
