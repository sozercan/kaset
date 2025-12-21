import Foundation

// MARK: - ParsingHelpers

/// Provides common utility methods for parsing YouTube Music API responses.
enum ParsingHelpers {
    /// Keywords used to identify chart sections for special rendering.
    static let chartKeywords = [
        "chart",
        "charts",
        "top 100",
        "top 50",
        "trending",
        "daily top",
        "weekly top",
    ]

    /// Checks if a section title indicates a chart section.
    static func isChartSection(_ title: String) -> Bool {
        let lowercased = title.lowercased()
        return self.chartKeywords.contains { lowercased.contains($0) }
    }

    /// Normalizes a URL string by adding https: prefix to protocol-relative URLs.
    static func normalizeURL(_ urlString: String) -> String {
        if urlString.hasPrefix("//") {
            return "https:" + urlString
        }
        return urlString
    }

    /// Extracts thumbnail URLs from various YouTube Music API data structures.
    static func extractThumbnails(from data: [String: Any]) -> [String] {
        if let thumbnail = data["thumbnail"] as? [String: Any] {
            // Try musicThumbnailRenderer (most common)
            if let musicThumbnailRenderer = thumbnail["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]]
            {
                return thumbnails.compactMap { $0["url"] as? String }.map(self.normalizeURL)
            }

            // Try croppedSquareThumbnailRenderer (used in library playlists)
            if let croppedRenderer = thumbnail["croppedSquareThumbnailRenderer"] as? [String: Any],
               let thumbnails = croppedRenderer["thumbnail"] as? [String: Any],
               let thumbList = thumbnails["thumbnails"] as? [[String: Any]]
            {
                return thumbList.compactMap { $0["url"] as? String }.map(self.normalizeURL)
            }

            // Direct thumbnails array
            if let thumbnails = thumbnail["thumbnails"] as? [[String: Any]] {
                return thumbnails.compactMap { $0["url"] as? String }.map(self.normalizeURL)
            }
        }

        // Try thumbnailRenderer at top level (some playlist formats)
        if let thumbnailRenderer = data["thumbnailRenderer"] as? [String: Any] {
            if let musicThumbnailRenderer = thumbnailRenderer["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]]
            {
                return thumbnails.compactMap { $0["url"] as? String }.map(self.normalizeURL)
            }

            if let croppedRenderer = thumbnailRenderer["croppedSquareThumbnailRenderer"] as? [String: Any],
               let thumbnails = croppedRenderer["thumbnail"] as? [String: Any],
               let thumbList = thumbnails["thumbnails"] as? [[String: Any]]
            {
                return thumbList.compactMap { $0["url"] as? String }.map(self.normalizeURL)
            }
        }

        return []
    }

    /// Extracts artists from subtitle data.
    static func extractArtists(from data: [String: Any]) -> [Artist] {
        var artists: [Artist] = []

        if let subtitleData = data["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            for run in runs {
                if let text = run["text"] as? String,
                   text != " • ", text != " & ", text != ", "
                {
                    if let endpoint = run["navigationEndpoint"] as? [String: Any],
                       let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                       let artistId = browseEndpoint["browseId"] as? String
                    {
                        artists.append(Artist(id: artistId, name: text))
                    } else if !text.isEmpty {
                        artists.append(Artist(id: UUID().uuidString, name: text))
                    }
                }
            }
        }

        return artists
    }

    /// Extracts subtitle text from data.
    static func extractSubtitle(from data: [String: Any]) -> String? {
        if let subtitleData = data["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            let texts = runs.compactMap { $0["text"] as? String }
            return texts.joined()
        }
        return nil
    }

    /// Extracts title from runs data.
    static func extractTitle(from data: [String: Any], key: String = "title") -> String? {
        if let titleData = data[key] as? [String: Any],
           let runs = titleData["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            return text
        }
        return nil
    }

    /// Extracts video ID from various data structures.
    static func extractVideoId(from data: [String: Any]) -> String? {
        // Try playlistItemData
        if let playlistItemData = data["playlistItemData"] as? [String: Any],
           let videoId = playlistItemData["videoId"] as? String
        {
            return videoId
        }

        // Try navigationEndpoint
        if let endpoint = data["navigationEndpoint"] as? [String: Any],
           let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
           let videoId = watchEndpoint["videoId"] as? String
        {
            return videoId
        }

        // Try overlay
        if let overlay = data["overlay"] as? [String: Any],
           let playButton = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = playButton["content"] as? [String: Any],
           let musicPlayButtonRenderer = content["musicPlayButtonRenderer"] as? [String: Any],
           let endpoint = musicPlayButtonRenderer["playNavigationEndpoint"] as? [String: Any],
           let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
           let videoId = watchEndpoint["videoId"] as? String
        {
            return videoId
        }

        return nil
    }

    /// Extracts browse ID from navigation endpoint.
    static func extractBrowseId(from data: [String: Any]) -> String? {
        if let endpoint = data["navigationEndpoint"] as? [String: Any],
           let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            return browseId
        }
        return nil
    }

    /// Extracts duration from flex columns or fixed columns.
    static func extractDurationFromFlexColumns(_ data: [String: Any]) -> TimeInterval? {
        // Try fixedColumns first (most common for playlist/album tracks)
        if let fixedColumns = data["fixedColumns"] as? [[String: Any]] {
            for column in fixedColumns {
                if let renderer = column["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any],
                   let text = renderer["text"] as? [String: Any],
                   let runs = text["runs"] as? [[String: Any]],
                   let firstRun = runs.first,
                   let durationText = firstRun["text"] as? String
                {
                    return self.parseDuration(durationText)
                }
            }
        }

        // Try flexColumns (artist page top songs often have duration in the last column)
        if let flexColumns = data["flexColumns"] as? [[String: Any]] {
            // Check last flex column for duration (common pattern on artist pages)
            for column in flexColumns.reversed() {
                if let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                   let text = renderer["text"] as? [String: Any],
                   let runs = text["runs"] as? [[String: Any]],
                   let firstRun = runs.first,
                   let durationText = firstRun["text"] as? String
                {
                    // Check if this looks like a duration (e.g., "3:45" or "1:23:45")
                    if let duration = parseDuration(durationText) {
                        return duration
                    }
                }
            }
        }

        // Try overlay play button for duration (used on some artist pages)
        if let overlay = data["overlay"] as? [String: Any],
           let musicItemThumbnailOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = musicItemThumbnailOverlay["content"] as? [String: Any],
           let musicPlayButton = content["musicPlayButtonRenderer"] as? [String: Any],
           let accessibilityData = musicPlayButton["accessibilityPlayData"] as? [String: Any],
           let accessibilityLabel = accessibilityData["accessibilityData"] as? [String: Any],
           let label = accessibilityLabel["label"] as? String
        {
            // Extract duration from accessibility label like "Play Billie Jean by Michael Jackson, 4 minutes, 55 seconds"
            if let duration = extractDurationFromAccessibilityLabel(label) {
                return duration
            }
        }

        return nil
    }

    /// Extracts duration from accessibility label text.
    /// Handles formats like "4 minutes, 55 seconds" or "4:55"
    private static func extractDurationFromAccessibilityLabel(_ label: String) -> TimeInterval? {
        // Try "X minutes, Y seconds" format
        let minutePattern = #"(\d+)\s*minutes?"#
        let secondPattern = #"(\d+)\s*seconds?"#

        var minutes = 0
        var seconds = 0

        if let minuteRegex = try? NSRegularExpression(pattern: minutePattern, options: .caseInsensitive),
           let minuteMatch = minuteRegex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
           let minuteRange = Range(minuteMatch.range(at: 1), in: label)
        {
            minutes = Int(label[minuteRange]) ?? 0
        }

        if let secondRegex = try? NSRegularExpression(pattern: secondPattern, options: .caseInsensitive),
           let secondMatch = secondRegex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
           let secondRange = Range(secondMatch.range(at: 1), in: label)
        {
            seconds = Int(label[secondRange]) ?? 0
        }

        if minutes > 0 || seconds > 0 {
            return TimeInterval(minutes * 60 + seconds)
        }

        return nil
    }

    /// Parses a duration string (e.g., "3:45") into seconds.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let components = text.split(separator: ":").compactMap { Int($0) }
        if components.count == 2 {
            return TimeInterval(components[0] * 60 + components[1])
        } else if components.count == 3 {
            return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
        }
        return nil
    }

    /// Extracts subtitle from flex columns.
    static func extractSubtitleFromFlexColumns(_ data: [String: Any]) -> String? {
        if let flexColumns = data["flexColumns"] as? [[String: Any]],
           flexColumns.count > 1,
           let secondColumn = flexColumns[safe: 1],
           let renderer = secondColumn["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let text = renderer["text"] as? [String: Any],
           let runs = text["runs"] as? [[String: Any]]
        {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    /// Extracts title from flex columns.
    static func extractTitleFromFlexColumns(_ data: [String: Any]) -> String? {
        if let flexColumns = data["flexColumns"] as? [[String: Any]],
           let firstColumn = flexColumns.first,
           let renderer = firstColumn["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let text = renderer["text"] as? [String: Any],
           let runs = text["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let title = firstRun["text"] as? String
        {
            return title
        }
        return nil
    }

    /// Extracts artists from flex columns.
    static func extractArtistsFromFlexColumns(_ data: [String: Any]) -> [Artist] {
        var artists: [Artist] = []

        if let flexColumns = data["flexColumns"] as? [[String: Any]],
           flexColumns.count > 1,
           let secondColumn = flexColumns[safe: 1],
           let renderer = secondColumn["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let text = renderer["text"] as? [String: Any],
           let runs = text["runs"] as? [[String: Any]]
        {
            for run in runs {
                if let artistName = run["text"] as? String,
                   artistName != " • ", artistName != " & ", artistName != ", ",
                   !artistName.isEmpty
                {
                    var artistId = UUID().uuidString
                    if let endpoint = run["navigationEndpoint"] as? [String: Any],
                       let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                       let browseId = browseEndpoint["browseId"] as? String
                    {
                        artistId = browseId
                    }
                    artists.append(Artist(id: artistId, name: artistName))
                }
            }
        }

        return artists
    }
}
