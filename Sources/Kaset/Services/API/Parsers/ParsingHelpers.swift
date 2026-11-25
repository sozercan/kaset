import CryptoKit
import Foundation

enum ParsingHelpers {
    private static let artistPageTypes: Set<String> = [
        "MUSIC_PAGE_TYPE_ARTIST",
        "MUSIC_PAGE_TYPE_USER_CHANNEL",
        "MUSIC_PAGE_TYPE_LIBRARY_ARTIST",
    ]

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

    static let chartKeywords = [
        "chart",
        "charts",
        "top 100",
        "top 50",
        "trending",
        "daily top",
        "weekly top",
    ]

    static func isChartSection(_ title: String) -> Bool {
        let lowercased = title.lowercased()
        return self.chartKeywords.contains { lowercased.contains($0) }
    }

    static func normalizeURL(_ urlString: String) -> String {
        if urlString.hasPrefix("//") {
            return "https:" + urlString
        }
        return urlString
    }

    static func extractThumbnails(from data: [String: Any]) -> [String] {
        if let thumbnail = data["thumbnail"] as? [String: Any] {
            if let musicThumbnailRenderer = thumbnail["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]]
            {
                return self.normalizedThumbnailURLs(from: thumbnails)
            }

            if let croppedRenderer = thumbnail["croppedSquareThumbnailRenderer"] as? [String: Any],
               let thumbnails = croppedRenderer["thumbnail"] as? [String: Any],
               let thumbList = thumbnails["thumbnails"] as? [[String: Any]]
            {
                return Self.normalizedThumbnailURLs(from: thumbList)
            }

            if let thumbnails = thumbnail["thumbnails"] as? [[String: Any]] {
                return Self.normalizedThumbnailURLs(from: thumbnails)
            }
        }

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

        if let foregroundThumbnail = data["foregroundThumbnail"] as? [String: Any] {
            if let musicThumbnailRenderer = foregroundThumbnail["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]]
            {
                return Self.normalizedThumbnailURLs(from: thumbnails)
            }
        }

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

    static func extractArtists(from data: [String: Any]) -> [Artist] {
        guard let subtitleData = data["subtitle"] as? [String: Any],
              let runs = subtitleData["runs"] as? [[String: Any]]
        else {
            return []
        }

        let fields = runs.split(whereSeparator: { run in
            guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return text == "•" || text == "·"
        })

        let parsedFields = fields.map { field -> (artists: [Artist], hasLinkedArtist: Bool) in
            var artists: [Artist] = []
            var hasLinkedArtist = false

            for run in field {
                guard let artistName = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !artistName.isEmpty,
                      !Self.isArtistSeparator(artistName)
                else {
                    continue
                }

                if let endpoint = run["navigationEndpoint"] as? [String: Any],
                   let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any]
                {
                    if let artist = Self.extractArtist(from: browseEndpoint, name: artistName) {
                        artists.append(artist)
                        hasLinkedArtist = true
                    }
                } else if run["navigationEndpoint"] == nil,
                          !Self.isMetadataText(artistName)
                {
                    artists.append(Artist(
                        id: Self.stableId(title: "artist", components: artistName),
                        name: artistName
                    ))
                }
            }

            return (artists, hasLinkedArtist)
        }

        let linkedFieldArtists = parsedFields.reduce(into: [Artist]()) { artists, field in
            if field.hasLinkedArtist {
                artists.append(contentsOf: field.artists)
            }
        }
        if !linkedFieldArtists.isEmpty {
            return linkedFieldArtists
        }

        return parsedFields.first(where: { !$0.artists.isEmpty })?.artists ?? []
    }

    static func extractAlbumLibraryTargetId(from value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let playlistId = dictionary["playlistId"] as? String,
               playlistId.hasPrefix("OLAK")
            {
                return playlistId
            }

            for child in dictionary.values {
                if let playlistId = self.extractAlbumLibraryTargetId(from: child) {
                    return playlistId
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let playlistId = self.extractAlbumLibraryTargetId(from: child) {
                    return playlistId
                }
            }
        }

        return nil
    }

    static func extractSubtitle(from data: [String: Any]) -> String? {
        if let subtitleData = data["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            let subtitle = Self.joinedRunText(runs)
            return subtitle.isEmpty ? nil : subtitle
        }
        return nil
    }

    static func extractSongCountFromSubtitle(from data: [String: Any]) -> Int? {
        guard let subtitle = extractSubtitle(from: data) else { return nil }
        return Self.extractSongCount(from: subtitle)
    }

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

    static func extractVideoId(from data: [String: Any]) -> String? {
        if let playlistItemData = data["playlistItemData"] as? [String: Any],
           let videoId = playlistItemData["videoId"] as? String
        {
            return videoId
        }

        if let endpoint = data["navigationEndpoint"] as? [String: Any],
           let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
           let videoId = watchEndpoint["videoId"] as? String
        {
            return videoId
        }

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

    static func isPlayableMusicItem(from data: [String: Any]) -> Bool {
        let displayPolicy = data["musicItemRendererDisplayPolicy"] as? String
        return displayPolicy != "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
    }

    static func extractBrowseId(from data: [String: Any]) -> String? {
        if let endpoint = data["navigationEndpoint"] as? [String: Any],
           let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            return browseId
        }
        return nil
    }

    static func extractPageType(from browseEndpoint: [String: Any]) -> String? {
        if let contextConfigs = browseEndpoint["browseEndpointContextSupportedConfigs"] as? [String: Any],
           let musicConfig = contextConfigs["browseEndpointContextMusicConfig"] as? [String: Any],
           let type = musicConfig["pageType"] as? String
        {
            return type
        }
        return nil
    }

    static func isArtistPageType(_ pageType: String?) -> Bool {
        guard let pageType else { return false }
        return Self.artistPageTypes.contains(pageType)
    }

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

    static func extractDurationFromFlexColumns(_ data: [String: Any]) -> TimeInterval? {
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

        if let flexColumns = data["flexColumns"] as? [[String: Any]] {
            for column in flexColumns.reversed() {
                if let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                   let text = renderer["text"] as? [String: Any],
                   let runs = text["runs"] as? [[String: Any]]
                {
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

        if let overlay = data["overlay"] as? [String: Any],
           let musicItemThumbnailOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = musicItemThumbnailOverlay["content"] as? [String: Any],
           let musicPlayButton = content["musicPlayButtonRenderer"] as? [String: Any],
           let accessibilityData = musicPlayButton["accessibilityPlayData"] as? [String: Any],
           let accessibilityLabel = accessibilityData["accessibilityData"] as? [String: Any],
           let label = accessibilityLabel["label"] as? String
        {
            if let duration = extractDurationFromAccessibilityLabel(label) {
                return duration
            }
        }

        return nil
    }

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

    static func extractSongCountFromFlexColumns(_ data: [String: Any]) -> Int? {
        guard let subtitle = extractSubtitleFromFlexColumns(data) else { return nil }
        return Self.extractSongCount(from: subtitle)
    }

    static func stripSongCountPattern(from text: String) -> String {
        var result = text.replacingOccurrences(
            of: #" • [\d,]+ (?:songs?|tracks?)"#,
            with: "",
            options: .regularExpression
        )

        if result.hasPrefix(" • ") {
            result = String(result.dropFirst(3))
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

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

    private static func isArtistSeparator(_ text: String) -> Bool {
        text == " • " || text == " · " || text == " & " || text == ", "
            || text == "•" || text == "·" || text == "&" || text == ","
    }

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

        guard let artistName = fallbackArtistName else {
            return []
        }

        return [Artist(
            id: Self.stableId(title: "upload-artist", components: artistName),
            name: artistName
        )]
    }

    static func extractAlbumFromFlexColumns(_ data: [String: Any]) -> Album? {
        guard let flexColumns = data["flexColumns"] as? [[String: Any]] else {
            return nil
        }

        for columnIndex in 1 ..< min(4, flexColumns.count) {
            guard let renderer = flexColumns[columnIndex]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                  let text = renderer["text"] as? [String: Any],
                  let runs = text["runs"] as? [[String: Any]]
            else {
                continue
            }

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
