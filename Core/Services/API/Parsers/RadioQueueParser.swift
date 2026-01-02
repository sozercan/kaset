import Foundation

/// Parses radio queue responses from YouTube Music API.
enum RadioQueueParser {
    /// Parses the radio queue from the "next" endpoint response.
    /// - Parameter data: The response from the "next" endpoint with a radio playlist ID
    /// - Returns: Array of songs in the radio queue
    static func parse(from data: [String: Any]) -> [Song] {
        guard let contents = data["contents"] as? [String: Any],
              let watchNextRenderer = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbedRenderer = watchNextRenderer["tabbedRenderer"] as? [String: Any],
              let watchNextTabbedResults = tabbedRenderer["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNextTabbedResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let musicQueueRenderer = tabContent["musicQueueRenderer"] as? [String: Any],
              let queueContent = musicQueueRenderer["content"] as? [String: Any],
              let playlistPanelRenderer = queueContent["playlistPanelRenderer"] as? [String: Any],
              let playlistContents = playlistPanelRenderer["contents"] as? [[String: Any]]
        else {
            return []
        }

        var songs: [Song] = []
        for item in playlistContents {
            // Handle both direct and wrapped renderer structures
            // Direct: item.playlistPanelVideoRenderer
            // Wrapped: item.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer
            let panelVideoRenderer: [String: Any]? = if let direct = item["playlistPanelVideoRenderer"] as? [String: Any] {
                direct
            } else if let wrapper = item["playlistPanelVideoWrapperRenderer"] as? [String: Any],
                      let primary = wrapper["primaryRenderer"] as? [String: Any],
                      let wrapped = primary["playlistPanelVideoRenderer"] as? [String: Any]
            {
                wrapped
            } else {
                nil
            }

            guard let panelVideoRenderer else {
                continue
            }

            // Extract videoId - required field
            guard let videoId = panelVideoRenderer["videoId"] as? String else {
                continue
            }

            let title = self.parseTitle(from: panelVideoRenderer)
            let artists = self.parseArtists(from: panelVideoRenderer)
            let thumbnailURL = self.parseThumbnail(from: panelVideoRenderer)
            let duration = self.parseDuration(from: panelVideoRenderer)

            let song = Song(
                id: videoId,
                title: title,
                artists: artists,
                album: nil,
                duration: duration,
                thumbnailURL: thumbnailURL,
                videoId: videoId
            )
            songs.append(song)
        }

        return songs
    }

    // MARK: - Parsing Helpers

    /// Parses the song title from the panel video renderer.
    private static func parseTitle(from renderer: [String: Any]) -> String {
        if let titleData = renderer["title"] as? [String: Any],
           let runs = titleData["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            return text
        }
        return "Unknown"
    }

    /// Parses artists from the panel video renderer's longBylineText.
    private static func parseArtists(from renderer: [String: Any]) -> [Artist] {
        var artists: [Artist] = []
        guard let bylineData = renderer["longBylineText"] as? [String: Any],
              let runs = bylineData["runs"] as? [[String: Any]]
        else { return artists }

        for run in runs {
            guard let text = run["text"] as? String,
                  text != " • ", text != " & ", text != ", ", text != " · "
            else { continue }

            let artistId: String = if let navEndpoint = run["navigationEndpoint"] as? [String: Any],
                                      let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any],
                                      let browseId = browseEndpoint["browseId"] as? String
            {
                browseId
            } else {
                UUID().uuidString
            }
            artists.append(Artist(id: artistId, name: text))
        }
        return artists
    }

    /// Parses the thumbnail URL from the panel video renderer.
    private static func parseThumbnail(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]],
              let lastThumb = thumbnails.last,
              let urlString = lastThumb["url"] as? String
        else { return nil }

        let normalizedURL = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        return URL(string: normalizedURL)
    }

    /// Parses the duration from the panel video renderer.
    private static func parseDuration(from renderer: [String: Any]) -> TimeInterval? {
        guard let lengthText = renderer["lengthText"] as? [String: Any],
              let runs = lengthText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let text = firstRun["text"] as? String
        else { return nil }

        return ParsingHelpers.parseDuration(text)
    }
}
