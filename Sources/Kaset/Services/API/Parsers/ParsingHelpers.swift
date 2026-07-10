import CryptoKit
import Foundation

// MARK: - ParsingHelpers

/// Provides common utility methods for parsing YouTube Music API responses.
enum ParsingHelpers {
    private static let artistPageTypes: Set<String> = [
        "MUSIC_PAGE_TYPE_ARTIST",
        "MUSIC_PAGE_TYPE_USER_CHANNEL",
        "MUSIC_PAGE_TYPE_LIBRARY_ARTIST",
    ]

    // MARK: - Stable ID Generation

    /// Generates a stable, deterministic ID from content components.
    /// This avoids SwiftUI identity churn caused by UUID() regeneration on refresh.
    /// - Parameters:
    ///   - title: Primary identifying text (section/item title)
    ///   - components: Additional identifying components (first item ID, index, etc.)
    /// - Returns: A stable hex string ID derived from the content hash
    static func stableId(title: String, components: String...) -> String {
        var reservedCapacity = title.utf8.count
        for component in components {
            reservedCapacity += 1 + component.utf8.count
        }

        var combined = ""
        combined.reserveCapacity(reservedCapacity)
        combined += title
        for component in components {
            combined.append("|")
            combined += component
        }

        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        // Use first 16 bytes (32 hex chars) for a compact but collision-resistant ID
        return Self.hexString(from: hash.prefix(16))
    }

    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    private static let accessibilityMinuteDurationRegex = try? NSRegularExpression(
        pattern: #"(\d+)\s*minutes?"#,
        options: .caseInsensitive
    )

    private static let accessibilitySecondDurationRegex = try? NSRegularExpression(
        pattern: #"(\d+)\s*seconds?"#,
        options: .caseInsensitive
    )

    private static func hexString(from bytes: some Sequence<UInt8>) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(32)

        for byte in bytes {
            output.append(Self.lowercaseHexDigits[Int(byte >> 4)])
            output.append(Self.lowercaseHexDigits[Int(byte & 0x0F)])
        }

        return String(bytes: output, encoding: .utf8) ?? ""
    }

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
                return self.normalizedThumbnailURLs(from: thumbnails)
            }

            // Try croppedSquareThumbnailRenderer (used in library playlists)
            if let croppedRenderer = thumbnail["croppedSquareThumbnailRenderer"] as? [String: Any],
               let thumbnails = croppedRenderer["thumbnail"] as? [String: Any],
               let thumbList = thumbnails["thumbnails"] as? [[String: Any]]
            {
                return Self.normalizedThumbnailURLs(from: thumbList)
            }

            // Direct thumbnails array
            if let thumbnails = thumbnail["thumbnails"] as? [[String: Any]] {
                return Self.normalizedThumbnailURLs(from: thumbnails)
            }
        }

        // Try thumbnailRenderer at top level (some playlist formats)
        if let thumbnailRenderer = data["thumbnailRenderer"] as? [String: Any] {
            if let musicThumbnailRenderer = thumbnailRenderer["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]]
            {
                return Self.normalizedThumbnailURLs(from: thumbnails)
            }

            if let croppedRenderer = thumbnailRenderer["croppedSquareThumbnailRenderer"] as? [String: Any],
               let thumbnails = croppedRenderer["thumbnail"] as? [String: Any],
               let thumbList = thumbnails["thumbnails"] as? [[String: Any]]
            {
                return Self.normalizedThumbnailURLs(from: thumbList)
            }
        }

        // Try foregroundThumbnail (used by some album/artist headers)
        if let foregroundThumbnail = data["foregroundThumbnail"] as? [String: Any] {
            if let musicThumbnailRenderer = foregroundThumbnail["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]]
            {
                return Self.normalizedThumbnailURLs(from: thumbnails)
            }
        }

        // Try direct thumbnails array at top level
        if let thumbnails = data["thumbnails"] as? [[String: Any]] {
            return Self.normalizedThumbnailURLs(from: thumbnails)
        }

        return []
    }

    private static func normalizedThumbnailURLs(from thumbnails: [[String: Any]]) -> [String] {
        var urls: [String] = []
        urls.reserveCapacity(thumbnails.count)

        for thumbnail in thumbnails {
            if let url = thumbnail["url"] as? String {
                urls.append(Self.normalizeURL(url))
            }
        }

        return urls
    }

    /// Extracts the largest/last thumbnail URL from YouTube Music thumbnail structures.
    static func extractThumbnailURL(from data: [String: Any]) -> URL? {
        guard let urlString = extractLastThumbnailURLString(from: data) else {
            return nil
        }
        return URL(string: urlString)
    }

    private static func extractLastThumbnailURLString(from data: [String: Any]) -> String? {
        if let thumbnail = data["thumbnail"] as? [String: Any] {
            if let musicThumbnailRenderer = thumbnail["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]],
               let url = lastNormalizedThumbnailURL(from: thumbnails)
            {
                return url
            }

            if let croppedRenderer = thumbnail["croppedSquareThumbnailRenderer"] as? [String: Any],
               let thumbnails = croppedRenderer["thumbnail"] as? [String: Any],
               let thumbList = thumbnails["thumbnails"] as? [[String: Any]],
               let url = Self.lastNormalizedThumbnailURL(from: thumbList)
            {
                return url
            }

            if let thumbnails = thumbnail["thumbnails"] as? [[String: Any]],
               let url = Self.lastNormalizedThumbnailURL(from: thumbnails)
            {
                return url
            }
        }

        if let thumbnailRenderer = data["thumbnailRenderer"] as? [String: Any] {
            if let musicThumbnailRenderer = thumbnailRenderer["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]],
               let url = Self.lastNormalizedThumbnailURL(from: thumbnails)
            {
                return url
            }

            if let croppedRenderer = thumbnailRenderer["croppedSquareThumbnailRenderer"] as? [String: Any],
               let thumbnails = croppedRenderer["thumbnail"] as? [String: Any],
               let thumbList = thumbnails["thumbnails"] as? [[String: Any]],
               let url = Self.lastNormalizedThumbnailURL(from: thumbList)
            {
                return url
            }
        }

        if let foregroundThumbnail = data["foregroundThumbnail"] as? [String: Any],
           let musicThumbnailRenderer = foregroundThumbnail["musicThumbnailRenderer"] as? [String: Any],
           let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
           let thumbnails = thumbData["thumbnails"] as? [[String: Any]],
           let url = Self.lastNormalizedThumbnailURL(from: thumbnails)
        {
            return url
        }

        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let url = Self.lastNormalizedThumbnailURL(from: thumbnails)
        {
            return url
        }

        return nil
    }

    private static func lastNormalizedThumbnailURL(from thumbnails: [[String: Any]]) -> String? {
        for thumbnail in thumbnails.reversed() {
            if let url = thumbnail["url"] as? String {
                return self.normalizeURL(url)
            }
        }
        return nil
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
                        artists.append(Artist(
                            id: artistId,
                            name: text,
                            profileKind: Artist.profileKind(forPageType: Self.extractPageType(from: browseEndpoint))
                        ))
                    } else if !text.isEmpty {
                        // Generate stable ID from artist name when no browse ID available
                        let stableArtistId = Self.stableId(title: "artist", components: text)
                        artists.append(Artist(id: stableArtistId, name: text))
                    }
                }
            }
        }

        return artists
    }

    /// Extracts subtitle text from data.
    /// Returns the full subtitle text including song counts (e.g., "Playlist • YouTube Music • 145 songs").
    static func extractSubtitle(from data: [String: Any]) -> String? {
        if let subtitleData = data["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            let subtitle = Self.joinedRunText(runs)
            return subtitle.isEmpty ? nil : subtitle
        }
        return nil
    }

    /// Extracts song count from subtitle data (e.g., "Playlist • 145 songs" → 145).
    static func extractSongCountFromSubtitle(from data: [String: Any]) -> Int? {
        guard let subtitle = extractSubtitle(from: data) else { return nil }
        return Self.extractSongCount(from: subtitle)
    }

    /// Whether the renderer's badges array marks the item as explicit content.
    ///
    /// Looks for `MUSIC_EXPLICIT_BADGE` in either the `badges` array (used by
    /// `musicResponsiveListItemRenderer`) or `subtitleBadges` (used by
    /// `musicTwoRowItemRenderer` and header renderers).
    static func extractIsExplicit(from data: [String: Any]) -> Bool {
        for key in ["badges", "subtitleBadges"] {
            guard let badges = data[key] as? [[String: Any]] else { continue }
            for badge in badges {
                guard let inline = badge["musicInlineBadgeRenderer"] as? [String: Any],
                      let icon = inline["icon"] as? [String: Any],
                      let iconType = icon["iconType"] as? String
                else { continue }
                if iconType == "MUSIC_EXPLICIT_BADGE" {
                    return true
                }
            }
        }
        return false
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

    /// Extracts the playlist-item-specific `setVideoId`, required to remove the correct
    /// occurrence of a track from a playlist (the same song can appear more than once).
    /// Only present on playlist track rows, not search results or other song contexts.
    static func extractPlaylistSetVideoId(from data: [String: Any]) -> String? {
        guard let playlistItemData = data["playlistItemData"] as? [String: Any] else {
            return nil
        }
        return playlistItemData["playlistSetVideoId"] as? String
    }

    /// Extracts the YouTube Music video type from watch endpoint metadata.
    static func extractMusicVideoType(from data: [String: Any]) -> MusicVideoType? {
        if let endpoint = data["navigationEndpoint"] as? [String: Any],
           let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
           let type = self.extractMusicVideoType(fromWatchEndpoint: watchEndpoint)
        {
            return type
        }

        if let overlay = data["overlay"] as? [String: Any],
           let playButton = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = playButton["content"] as? [String: Any],
           let musicPlayButtonRenderer = content["musicPlayButtonRenderer"] as? [String: Any],
           let endpoint = musicPlayButtonRenderer["playNavigationEndpoint"] as? [String: Any],
           let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
           let type = self.extractMusicVideoType(fromWatchEndpoint: watchEndpoint)
        {
            return type
        }

        return nil
    }

    private static func extractMusicVideoType(fromWatchEndpoint watchEndpoint: [String: Any]) -> MusicVideoType? {
        guard let configs = watchEndpoint["watchEndpointMusicSupportedConfigs"] as? [String: Any],
              let musicConfig = configs["watchEndpointMusicConfig"] as? [String: Any],
              let typeString = musicConfig["musicVideoType"] as? String
        else {
            return nil
        }

        return MusicVideoType(rawValue: typeString)
    }

    /// Returns whether a music item renderer is playable.
    static func isPlayableMusicItem(from data: [String: Any]) -> Bool {
        let displayPolicy = data["musicItemRendererDisplayPolicy"] as? String
        return displayPolicy != "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
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

    /// Extracts page type from a browse endpoint.
    static func extractPageType(from browseEndpoint: [String: Any]) -> String? {
        if let contextConfigs = browseEndpoint["browseEndpointContextSupportedConfigs"] as? [String: Any],
           let musicConfig = contextConfigs["browseEndpointContextMusicConfig"] as? [String: Any],
           let type = musicConfig["pageType"] as? String
        {
            return type
        }
        return nil
    }

    /// Returns whether the page type represents an artist destination.
    static func isArtistPageType(_ pageType: String?) -> Bool {
        guard let pageType else { return false }
        return Self.artistPageTypes.contains(pageType)
    }

    /// Creates an artist from a browse endpoint when it points to an artist or user channel page.
    static func extractArtist(from browseEndpoint: [String: Any]?, name: String, thumbnailURL: URL? = nil) -> Artist? {
        guard let browseEndpoint,
              let browseId = browseEndpoint["browseId"] as? String,
              isArtistPageType(extractPageType(from: browseEndpoint)) || Artist.isNavigableId(browseId)
        else {
            return nil
        }

        let pageType = self.extractPageType(from: browseEndpoint)
        return Artist(
            id: browseId,
            name: name,
            thumbnailURL: thumbnailURL,
            profileKind: Artist.profileKind(forPageType: pageType)
        )
    }

    /// Extracts the first linked artist-like run from a runs array.
    static func extractFirstNavigableArtist(from runs: [[String: Any]]) -> Artist? {
        for run in runs {
            guard let name = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  name != "•",
                  let endpoint = run["navigationEndpoint"] as? [String: Any],
                  let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  let artist = extractArtist(from: browseEndpoint, name: name)
            else {
                continue
            }

            return artist
        }

        return nil
    }

    /// Extracts a linked artist from a responsive header facepile, if present.
    static func extractFacepileArtist(from renderer: [String: Any]) -> Artist? {
        guard let facepile = renderer["facepile"] as? [String: Any],
              let avatarStackViewModel = facepile["avatarStackViewModel"] as? [String: Any],
              let text = avatarStackViewModel["text"] as? [String: Any],
              let content = text["content"] as? String
        else {
            return nil
        }

        let name = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let browseEndpoint = ((avatarStackViewModel["rendererContext"] as? [String: Any])?["commandContext"] as? [String: Any])
            .flatMap { $0["onTap"] as? [String: Any] }
            .flatMap { $0["innertubeCommand"] as? [String: Any] }
            .flatMap { $0["browseEndpoint"] as? [String: Any] }

        return Self.extractArtist(from: browseEndpoint, name: name)
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

        // Try flexColumns (artist page top songs often have duration in a combined column)
        if let flexColumns = data["flexColumns"] as? [[String: Any]] {
            for column in flexColumns.reversed() {
                if let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                   let text = renderer["text"] as? [String: Any],
                   let runs = text["runs"] as? [[String: Any]]
                {
                    // Check all runs (duration is often the last run in "Artist • Album • 3:45")
                    // Skip runs with navigationEndpoint to avoid matching album titles like "4:44"
                    for run in runs.reversed() {
                        if let durationText = run["text"] as? String,
                           run["navigationEndpoint"] == nil,
                           let duration = self.parseDuration(durationText)
                        {
                            return duration
                        }
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
        var minutes = 0
        var seconds = 0
        let fullRange = NSRange(label.startIndex..., in: label)

        if let minuteRegex = Self.accessibilityMinuteDurationRegex,
           let minuteMatch = minuteRegex.firstMatch(in: label, range: fullRange),
           let minuteRange = Range(minuteMatch.range(at: 1), in: label)
        {
            minutes = Int(label[minuteRange]) ?? 0
        }

        if let secondRegex = Self.accessibilitySecondDurationRegex,
           let secondMatch = secondRegex.firstMatch(in: label, range: fullRange),
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
        let components = text.split(separator: ":")
        guard components.count == 2 || components.count == 3 else {
            return nil
        }

        var totalSeconds = 0
        for component in components {
            guard let value = Int(component) else { return nil }
            totalSeconds = totalSeconds * 60 + value
        }

        return TimeInterval(totalSeconds)
    }

    /// Extracts subtitle from flex columns.
    /// Returns the full subtitle text including song counts (e.g., "Playlist • YouTube Music • 145 songs").
    static func extractSubtitleFromFlexColumns(_ data: [String: Any]) -> String? {
        if let flexColumns = data["flexColumns"] as? [[String: Any]],
           flexColumns.count > 1,
           let renderer = flexColumns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let text = renderer["text"] as? [String: Any],
           let runs = text["runs"] as? [[String: Any]]
        {
            let subtitle = Self.joinedRunText(runs)
            return subtitle.isEmpty ? nil : subtitle
        }
        return nil
    }

    static func joinedRunText(_ runs: [[String: Any]]) -> String {
        var capacity = 0
        for run in runs {
            if let runText = run["text"] as? String {
                capacity += runText.count
            }
        }

        var text = ""
        text.reserveCapacity(capacity)
        for run in runs {
            if let runText = run["text"] as? String {
                text += runText
            }
        }
        return text
    }

    /// Extracts song count from flex columns subtitle (e.g., "Playlist • 145 songs" → 145).
    static func extractSongCountFromFlexColumns(_ data: [String: Any]) -> Int? {
        guard let subtitle = extractSubtitleFromFlexColumns(data) else { return nil }
        return Self.extractSongCount(from: subtitle)
    }

    /// Strips song count patterns from a string (e.g., " • 145 songs" or " • 2,429 tracks").
    /// The song count is typically displayed separately in the UI from the actual parsed count.
    static func stripSongCountPattern(from text: String) -> String {
        var result = text.replacingOccurrences(
            of: #" • [\d,]+ (?:songs?|tracks?)"#,
            with: "",
            options: .regularExpression
        )

        // Also strip leading " • " if the result starts with it
        if result.hasPrefix(" • ") {
            result = String(result.dropFirst(3))
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Extracts song count from subtitle text (e.g., "Playlist • YouTube Music • 145 songs" → 145).
    static func extractSongCount(from text: String) -> Int? {
        let components = text.split(whereSeparator: \.isWhitespace)
        guard components.count >= 2 else { return nil }

        for index in components.indices.dropFirst() {
            let unit = components[index]
                .trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
            guard unit == "song" || unit == "songs" || unit == "track" || unit == "tracks" else {
                continue
            }

            let countText = components[components.index(before: index)]
            var normalizedCount = ""
            normalizedCount.reserveCapacity(countText.count)

            var hasInvalidCharacter = false
            for character in countText {
                if character.isNumber {
                    normalizedCount.append(character)
                } else if character != "," {
                    hasInvalidCharacter = true
                    break
                }
            }

            if !hasInvalidCharacter,
               !normalizedCount.isEmpty,
               let count = Int(normalizedCount)
            {
                return count
            }
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

    /// Known content type keywords that should not be treated as artist names.
    private static let contentTypeKeywords: Set<String> = [
        "Song", "Video", "Album", "Playlist", "Artist", "Episode", "Podcast",
    ]

    private static func isArtistSeparator(_ text: String) -> Bool {
        text == " • " || text == " & " || text == ", " || text == "•" || text == "&" || text == ","
    }

    private static func isMetadataText(_ text: String) -> Bool {
        if self.contentTypeKeywords.contains(text) {
            return true
        }

        let lowercased = text.lowercased()

        if lowercased.contains(" views")
            || lowercased.contains(" plays")
            || lowercased.contains(" subscribers")
            || lowercased.contains("episodes")
        {
            return true
        }

        if text.contains(":"), self.parseDuration(text) != nil {
            return true
        }

        if self.containsDurationUnit(in: lowercased), self.isNaturalLanguageDuration(text) {
            return true
        }

        if lowercased.contains("song") || lowercased.contains("track") {
            if self.extractSongCount(from: text) != nil {
                return true
            }
        }

        return self.isStandaloneYear(text)
    }

    private static func isStandaloneYear(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4,
              trimmed.allSatisfy(\.isNumber),
              let year = Int(trimmed)
        else {
            return false
        }

        return (1900 ... 2100).contains(year)
    }

    private static func isNaturalLanguageDuration(_ text: String) -> Bool {
        let lowercased = text.lowercased()

        guard Self.containsDurationUnit(in: lowercased) else {
            return false
        }

        return lowercased.allSatisfy { character in
            character.isNumber
                || character.isWhitespace
                || character == ","
                || Self.durationUnitCharacters.contains(character)
        }
    }

    private static let durationUnits = ["second", "seconds", "minute", "minutes", "hour", "hours"]
    private static let durationUnitCharacters = Set("secondsecondsminuteminuteshourhours")

    private static func containsDurationUnit(in lowercasedText: String) -> Bool {
        self.durationUnits.contains { lowercasedText.contains($0) }
    }

    /// Extracts artists from flex columns.
    static func extractArtistsFromFlexColumns(_ data: [String: Any]) -> [Artist] {
        var artists: [Artist] = []

        guard let flexColumns = data["flexColumns"] as? [[String: Any]],
              flexColumns.count > 1,
              let renderer = flexColumns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = renderer["text"] as? [String: Any],
              let runs = text["runs"] as? [[String: Any]]
        else {
            return []
        }

        artists.reserveCapacity(runs.count)
        var fallbackArtistName: String?

        for run in runs {
            guard let artistName = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !artistName.isEmpty,
                  !Self.isArtistSeparator(artistName)
            else { continue }

            // Only include linked artist endpoints on the first pass. This filters
            // out metadata while preserving normal channel and library artist rows,
            // including numeric artist names such as "311".
            if let endpoint = run["navigationEndpoint"] as? [String: Any],
               let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
               let browseId = browseEndpoint["browseId"] as? String,
               Artist.isNavigableId(browseId)
            {
                artists.append(Artist(
                    id: browseId,
                    name: artistName,
                    profileKind: Artist.profileKind(forPageType: Self.extractPageType(from: browseEndpoint))
                ))
            } else if fallbackArtistName == nil,
                      run["navigationEndpoint"] == nil,
                      !Self.isMetadataText(artistName)
            {
                fallbackArtistName = artistName
            }
        }

        if !artists.isEmpty {
            return artists
        }

        // Uploaded songs often expose artist metadata as plain text, without a
        // browse endpoint. Preserve that text so playlist rows do not show an
        // empty artist line.
        guard let artistName = fallbackArtistName else {
            return []
        }

        return [Artist(
            id: Self.stableId(title: "upload-artist", components: artistName),
            name: artistName
        )]
    }

    /// Extracts album from flex columns.
    /// Album info is typically in the second or third flex column with a browseId starting with MPRE or OLAK.
    static func extractAlbumFromFlexColumns(_ data: [String: Any]) -> Album? {
        guard let flexColumns = data["flexColumns"] as? [[String: Any]] else {
            return nil
        }

        // Album is typically in the second or third column
        // Look through columns 1, 2, and 3 (indices 1, 2, 3) for album data
        for columnIndex in 1 ..< min(4, flexColumns.count) {
            guard let renderer = flexColumns[columnIndex]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                  let text = renderer["text"] as? [String: Any],
                  let runs = text["runs"] as? [[String: Any]]
            else {
                continue
            }

            // Look for a run with a navigation endpoint pointing to an album
            for run in runs {
                guard let albumName = run["text"] as? String,
                      !albumName.isEmpty,
                      albumName != " • ", albumName != " & ", albumName != ", ",
                      let endpoint = run["navigationEndpoint"] as? [String: Any],
                      let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                      let browseId = browseEndpoint["browseId"] as? String,
                      browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK")
                else {
                    continue
                }

                return Album(
                    id: browseId,
                    title: albumName,
                    artists: nil,
                    thumbnailURL: nil,
                    year: nil,
                    trackCount: nil
                )
            }
        }

        return nil
    }
}
