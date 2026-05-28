import Foundation

/// Parses lyrics responses from YouTube Music API.
enum LyricsParser {
    private static let logger = DiagnosticsLogger.api

    /// Extracts the lyrics browse ID from the "next" endpoint response.
    /// - Parameter data: The response from the "next" endpoint
    /// - Returns: The browse ID for fetching lyrics, or nil if unavailable
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

        // Find the lyrics tab (usually index 1, but search by content type to be safe)
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

    /// Extracts timed lyrics from the browse endpoint or next endpoint response.
    /// - Parameter data: The data containing timed lyrics.
    /// - Returns: Parsed SyncedLyrics, or nil if unavailable.
    static func extractTimedLyrics(from data: [String: Any]) -> SyncedLyrics? {
        guard let lines = self.findTimedLyricsLines(in: data), !lines.isEmpty else {
            return nil
        }

        return SyncedLyrics(lines: lines, source: "YTMusic")
    }

    /// Recursively searches nested dictionaries/arrays for timed lyrics payloads.
    private static func findTimedLyricsLines(in node: Any) -> [SyncedLyricLine]? {
        if let dictionary = node as? [String: Any] {
            if let lines = self.parseTimedLyricsLines(from: dictionary) {
                return lines
            }

            for value in dictionary.values {
                if let lines = self.findTimedLyricsLines(in: value) {
                    return lines
                }
            }
        } else if let array = node as? [Any] {
            if let lines = self.parseTimedLyricsLines(from: array) {
                return lines
            }

            for value in array {
                if let lines = self.findTimedLyricsLines(in: value) {
                    return lines
                }
            }
        }

        return nil
    }

    /// Parses a collection that looks like timed lyric entries.
    private static func parseTimedLyricsLines(from node: Any) -> [SyncedLyricLine]? {
        let entries: [[String: Any]]
        if let dictionary = node as? [String: Any] {
            if let nested = dictionary["timedLyricsModel"] as? [String: Any] {
                return self.parseTimedLyricsLines(from: nested)
            }

            if let nested = dictionary["timedLyricsData"] {
                return self.parseTimedLyricsLines(from: nested)
            }

            if let nested = dictionary["lyricsData"] {
                return self.parseTimedLyricsLines(from: nested)
            }

            return nil
        } else if let array = node as? [Any] {
            entries = array.compactMap { $0 as? [String: Any] }
        } else {
            return nil
        }

        var lines: [SyncedLyricLine] = []
        for entry in entries {
            guard let line = self.parseTimedLyricLine(from: entry) else {
                continue
            }
            lines.append(line)
        }

        return lines.isEmpty ? nil : lines
    }

    private static func parseTimedLyricLine(from entry: [String: Any]) -> SyncedLyricLine? {
        guard let lyricLine = self.timedLyricsText(from: entry),
              let startTimeMs = self.startTimeMilliseconds(from: entry)
        else {
            return nil
        }

        let durationMs = self.durationMilliseconds(from: entry) ?? 0
        return SyncedLyricLine(
            timeInMs: startTimeMs,
            duration: durationMs,
            text: lyricLine,
            words: nil
        )
    }

    private static func timedLyricsText(from entry: [String: Any]) -> String? {
        for key in ["lyricLine", "text", "line", "lyrics"] {
            if let value = entry[key] as? String, !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private static func startTimeMilliseconds(from entry: [String: Any]) -> Int? {
        if let direct = self.intValue(for: entry["startTimeMs"]) {
            return direct
        }

        if let cueRange = entry["cueRange"] as? [String: Any] {
            return self.intValue(for: cueRange["startTimeMilliseconds"])
        }

        return nil
    }

    private static func durationMilliseconds(from entry: [String: Any]) -> Int? {
        if let direct = self.intValue(for: entry["durationMs"]) {
            return direct
        }

        if let cueRange = entry["cueRange"] as? [String: Any],
           let start = self.intValue(for: cueRange["startTimeMilliseconds"]),
           let end = self.intValue(for: cueRange["endTimeMilliseconds"])
        {
            return max(0, end - start)
        }

        return nil
    }

    private static func intValue(for value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as String:
            Int(value)
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }

    /// Parses lyrics from the browse endpoint response.
    /// - Parameter data: The response from the browse endpoint
    /// - Returns: Parsed lyrics, or `.unavailable` if not found
    static func parse(from data: [String: Any]) -> Lyrics {
        guard let contents = data["contents"] as? [String: Any],
              let sectionListRenderer = contents["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return .unavailable
        }

        for section in sectionContents {
            // Try musicDescriptionShelfRenderer (plain lyrics)
            if let shelfRenderer = section["musicDescriptionShelfRenderer"] as? [String: Any] {
                return self.parseLyricsFromShelf(shelfRenderer)
            }
        }

        return .unavailable
    }

    /// Parses lyrics from a musicDescriptionShelfRenderer.
    private static func parseLyricsFromShelf(_ shelf: [String: Any]) -> Lyrics {
        // Extract the description (lyrics text)
        var lyricsText = ""
        if let description = shelf["description"] as? [String: Any],
           let runs = description["runs"] as? [[String: Any]]
        {
            lyricsText = runs.compactMap { $0["text"] as? String }.joined()
        }

        if lyricsText.isEmpty {
            return .unavailable
        }

        return Lyrics(text: lyricsText, source: "YTMusic")
    }
}
