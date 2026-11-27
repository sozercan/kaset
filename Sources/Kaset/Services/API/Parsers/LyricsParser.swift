import Foundation

enum LyricsParser {
    private static let logger = DiagnosticsLogger.api

    static func extractLyricsBrowseId(from data: [String: Any]) -> String? {
        guard let contents = data["contents"] as? [String: Any],
              let watchNextRenderer = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbedRenderer = watchNextRenderer["tabbedRenderer"] as? [String: Any],
              let watchNextTabbedResults = tabbedRenderer["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNextTabbedResults["tabs"] as? [[String: Any]]
        else {
            self.logger.debug("LyricsParser: Failed to extract lyrics browse ID structure")
            return nil
        }

        for tab in tabs {
            guard let tabRenderer = tab["tabRenderer"] as? [String: Any],
                  let endpoint = tabRenderer["endpoint"] as? [String: Any],
                  let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  let browseId = browseEndpoint["browseId"] as? String,
                  browseId.hasPrefix("MPLYt")
            else {
                continue
            }
            return browseId
        }

        return nil
    }

    static func extractTimedLyrics(from data: [String: Any]) -> SyncedLyrics? {
        guard let timedLyricsModel = self.findTimedLyricsModel(in: data),
              let lyricsData = timedLyricsModel["lyricsData"] as? [[String: Any]]
        else {
            return nil
        }

        var lines: [SyncedLyricLine] = []
        for lineData in lyricsData {
            if let lyricLine = lineData["lyricLine"] as? String,
               let startTimeStr = lineData["startTimeMs"] as? String,
               let startTimeMs = Int(startTimeStr)
            {
                let durationMs = (lineData["durationMs"] as? String).flatMap(Int.init) ?? 0
                lines.append(SyncedLyricLine(
                    timeInMs: startTimeMs,
                    duration: durationMs,
                    text: lyricLine,
                    words: nil
                ))
            }
        }

        if lines.isEmpty {
            return nil
        }

        return SyncedLyrics(lines: lines, source: "YTMusic")
    }

    private static func findTimedLyricsModel(in node: Any) -> [String: Any]? {
        if let dictionary = node as? [String: Any] {
            if let timedLyricsModel = dictionary["timedLyricsModel"] as? [String: Any] {
                return timedLyricsModel
            }

            for value in dictionary.values {
                if let timedLyricsModel = self.findTimedLyricsModel(in: value) {
                    return timedLyricsModel
                }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let timedLyricsModel = self.findTimedLyricsModel(in: value) {
                    return timedLyricsModel
                }
            }
        }

        return nil
    }

    static func parse(from data: [String: Any]) -> Lyrics {
        guard let contents = data["contents"] as? [String: Any],
              let sectionListRenderer = contents["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return .unavailable
        }

        for section in sectionContents {
            if let shelfRenderer = section["musicDescriptionShelfRenderer"] as? [String: Any] {
                return self.parseLyricsFromShelf(shelfRenderer)
            }
        }

        return .unavailable
    }

    private static func parseLyricsFromShelf(_ shelf: [String: Any]) -> Lyrics {
        var lyricsText = ""
        if let description = shelf["description"] as? [String: Any],
           let runs = description["runs"] as? [[String: Any]]
        {
            lyricsText = ParsingHelpers.joinedRunText(runs)
        }

        var source: String?
        if let footer = shelf["footer"] as? [String: Any],
           let runs = footer["runs"] as? [[String: Any]]
        {
            source = ParsingHelpers.joinedRunText(runs)
        }

        if lyricsText.isEmpty {
            return .unavailable
        }

        return Lyrics(text: lyricsText, source: source)
    }
}
