import Foundation

struct RadioQueueResult {
    let songs: [Song]
    let continuationToken: String?
}

enum RadioQueueParser {
    private static let logger = DiagnosticsLogger.api

    static func parse(from data: [String: Any]) -> RadioQueueResult {
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
            self.logger.debug("RadioQueueParser: Failed to parse radio queue structure. Top keys: \(data.keys.sorted())")
            return RadioQueueResult(songs: [], continuationToken: nil)
        }

        var continuationToken: String?
        if let continuations = playlistPanelRenderer["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextRadioData = firstContinuation["nextRadioContinuationData"] as? [String: Any],
           let token = nextRadioData["continuation"] as? String
        {
            continuationToken = token
        }

        let songs = Self.parseSongs(from: playlistContents)
        return RadioQueueResult(songs: songs, continuationToken: continuationToken)
    }

    static func parseContinuation(from data: [String: Any]) -> RadioQueueResult {
        guard let continuationContents = data["continuationContents"] as? [String: Any],
              let playlistPanelContinuation = continuationContents["playlistPanelContinuation"] as? [String: Any],
              let contents = playlistPanelContinuation["contents"] as? [[String: Any]]
        else {
            return RadioQueueResult(songs: [], continuationToken: nil)
        }

        var continuationToken: String?
        if let continuations = playlistPanelContinuation["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextRadioData = firstContinuation["nextRadioContinuationData"] as? [String: Any],
           let token = nextRadioData["continuation"] as? String
        {
            continuationToken = token
        }

        let songs = Self.parseSongs(from: contents)
        return RadioQueueResult(songs: songs, continuationToken: continuationToken)
    }

    private static func parseSongs(from playlistContents: [[String: Any]]) -> [Song] {
        var songs: [Song] = []
        for item in playlistContents {
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

            guard let videoId = panelVideoRenderer["videoId"] as? String else {
                continue
            }

            let title = self.parseTitle(from: panelVideoRenderer)
            let artists = self.parseArtists(from: panelVideoRenderer)
            let thumbnailURL = self.parseThumbnail(from: panelVideoRenderer)
            let duration = self.parseDuration(from: panelVideoRenderer)
            let likeStatus = SongMetadataParser.parseLikeStatus(from: panelVideoRenderer)

            let song = Song(
                id: videoId,
                title: title,
                artists: artists,
                album: nil,
                duration: duration,
                thumbnailURL: thumbnailURL,
                videoId: videoId,
                likeStatus: likeStatus,
                isExplicit: ParsingHelpers.extractIsExplicit(from: panelVideoRenderer)
            )
            songs.append(song)
        }

        return songs
    }

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

    private static func parseArtists(from renderer: [String: Any]) -> [Artist] {
        var artists: [Artist] = []
        guard let bylineData = renderer["longBylineText"] as? [String: Any],
              let runs = bylineData["runs"] as? [[String: Any]]
        else { return artists }

        for run in runs {
            guard let text = run["text"] as? String else { continue }
            if text == " • " || text == " · " {
                break
            }
            guard text != " & ", text != ", " else { continue }

            let artistId: String = if let navEndpoint = run["navigationEndpoint"] as? [String: Any],
                                      let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any],
                                      let browseId = browseEndpoint["browseId"] as? String
            {
                browseId
            } else {
                ParsingHelpers.stableId(title: "artist", components: text)
            }
            artists.append(Artist(id: artistId, name: text))
        }
        return artists
    }

    private static func parseThumbnail(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]],
              let lastThumb = thumbnails.last,
              let urlString = lastThumb["url"] as? String
        else { return nil }

        let normalizedURL = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        return URL(string: normalizedURL)
    }

    private static func parseDuration(from renderer: [String: Any]) -> TimeInterval? {
        guard let lengthText = renderer["lengthText"] as? [String: Any],
              let runs = lengthText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let text = firstRun["text"] as? String
        else { return nil }

        return ParsingHelpers.parseDuration(text)
    }
}
