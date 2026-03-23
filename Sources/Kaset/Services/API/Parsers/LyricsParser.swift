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

        // Extract the footer (source attribution)
        var source: String?
        if let footer = shelf["footer"] as? [String: Any],
           let runs = footer["runs"] as? [[String: Any]]
        {
            source = runs.compactMap { $0["text"] as? String }.joined()
        }

        if lyricsText.isEmpty {
            return .unavailable
        }

        return Lyrics(text: lyricsText, source: source)
    }
}
