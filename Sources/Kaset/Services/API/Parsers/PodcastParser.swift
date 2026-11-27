import Foundation

enum PodcastParser {
    private static let logger = DiagnosticsLogger.api

    static func parseDiscovery(_ data: [String: Any]) -> [PodcastSection] {
        var sections: [PodcastSection] = []

        guard let contents = data["contents"] as? [String: Any],
              let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            Self.logger.debug("PodcastParser: No standard structure found. Top keys: \(data.keys.sorted())")
            return []
        }

        for sectionData in sectionContents {
            if let section = Self.parsePodcastSection(sectionData) {
                sections.append(section)
            }
        }

        return sections
    }

    static func parseContinuation(_ data: [String: Any]) -> [PodcastSection] {
        var sections: [PodcastSection] = []

        if let continuationContents = data["continuationContents"] as? [String: Any],
           let sectionListContinuation = continuationContents["sectionListContinuation"] as? [String: Any],
           let contents = sectionListContinuation["contents"] as? [[String: Any]]
        {
            for sectionData in contents {
                if let section = Self.parsePodcastSection(sectionData) {
                    sections.append(section)
                }
            }
        }

        if let continuationContents = data["continuationContents"] as? [String: Any],
           let carouselContinuation = continuationContents["musicCarouselShelfContinuation"] as? [String: Any],
           let contents = carouselContinuation["contents"] as? [[String: Any]]
        {
            var items: [PodcastSectionItem] = []
            for itemData in contents {
                if let item = Self.parsePodcastItem(itemData) {
                    items.append(item)
                }
            }
            if !items.isEmpty {
                let firstItemId = items.first.map { Self.extractPodcastItemId($0) } ?? ""
                let stableId = ParsingHelpers.stableId(title: "More", components: firstItemId)
                sections.append(PodcastSection(id: stableId, title: "More", items: items))
            }
        }

        return sections
    }

    private static func parsePodcastSection(_ data: [String: Any]) -> PodcastSection? {
        if let carouselRenderer = data["musicCarouselShelfRenderer"] as? [String: Any] {
            return self.parseMusicCarouselShelf(carouselRenderer)
        }

        if let shelfRenderer = data["musicShelfRenderer"] as? [String: Any] {
            return Self.parseMusicShelf(shelfRenderer)
        }

        if let itemSectionRenderer = data["itemSectionRenderer"] as? [String: Any],
           let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
        {
            for itemContent in itemContents {
                if let section = Self.parsePodcastSection(itemContent) {
                    return section
                }
            }
        }

        return nil
    }

    private static func parseMusicCarouselShelf(_ data: [String: Any]) -> PodcastSection? {
        let title = Self.extractCarouselTitle(from: data) ?? "Podcasts"

        guard let contents = data["contents"] as? [[String: Any]] else {
            return nil
        }

        var items: [PodcastSectionItem] = []
        for itemData in contents {
            if let item = Self.parsePodcastItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

        let firstItemId = items.first.map { Self.extractPodcastItemId($0) } ?? ""
        let stableId = ParsingHelpers.stableId(title: title, components: firstItemId)

        return PodcastSection(
            id: stableId,
            title: title,
            items: items
        )
    }

    private static func parseMusicShelf(_ data: [String: Any]) -> PodcastSection? {
        let title = ParsingHelpers.extractTitle(from: data) ?? "Podcasts"

        guard let contents = data["contents"] as? [[String: Any]] else {
            return nil
        }

        var items: [PodcastSectionItem] = []
        for itemData in contents {
            if let item = Self.parsePodcastItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

        let firstItemId = items.first.map { Self.extractPodcastItemId($0) } ?? ""
        let stableId = ParsingHelpers.stableId(title: title, components: firstItemId)

        return PodcastSection(
            id: stableId,
            title: title,
            items: items
        )
    }

    private static func parsePodcastItem(_ data: [String: Any]) -> PodcastSectionItem? {
        if let twoRowRenderer = data["musicTwoRowItemRenderer"] as? [String: Any] {
            return self.parseTwoRowItem(twoRowRenderer)
        }

        if let multiRowRenderer = data["musicMultiRowListItemRenderer"] as? [String: Any] {
            return Self.parseMultiRowListItem(multiRowRenderer)
        }

        if let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] {
            return Self.parseResponsiveListItem(responsiveRenderer)
        }

        return nil
    }

    private static func parseTwoRowItem(_ data: [String: Any]) -> PodcastSectionItem? {
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)

        guard let title = ParsingHelpers.extractTitle(from: data) else {
            return nil
        }

        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        if browseId.hasPrefix("MPSPP") {
            let author = ParsingHelpers.extractSubtitle(from: data)
            let show = PodcastShow(
                id: browseId,
                title: title,
                author: author,
                description: nil,
                thumbnailURL: thumbnailURL,
                episodeCount: nil
            )
            return .show(show)
        }

        if let watchEndpoint = navigationEndpoint["watchEndpoint"] as? [String: Any],
           let videoId = watchEndpoint["videoId"] as? String
        {
            let episode = PodcastEpisode(
                id: videoId,
                title: title,
                showTitle: ParsingHelpers.extractSubtitle(from: data),
                showBrowseId: nil,
                description: nil,
                thumbnailURL: thumbnailURL,
                publishedDate: nil,
                duration: nil,
                durationSeconds: nil,
                playbackProgress: 0,
                isPlayed: false
            )
            return .episode(episode)
        }

        return nil
    }

    private static func parseMultiRowListItem(_ data: [String: Any]) -> PodcastSectionItem? {
        guard let onTap = data["onTap"] as? [String: Any],
              let watchEndpoint = onTap["watchEndpoint"] as? [String: Any],
              let videoId = watchEndpoint["videoId"] as? String
        else {
            return nil
        }

        let title = Self.extractMultiRowTitle(from: data) ?? "Unknown Episode"

        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)

        let showTitle = Self.extractMultiRowSubtitle(from: data)

        let showBrowseId = Self.extractShowBrowseId(from: data)

        var playbackProgress: Double = 0
        var isPlayed = false
        var hasExplicitPlayedStatus = false

        let progressRenderer = (data["playbackProgress"] as? [String: Any])?["musicPlaybackProgressRenderer"] as? [String: Any]
            ?? (data["playbackProgress"] as? [String: Any])

        if let percentage = progressRenderer?["playbackProgressPercentage"] as? Int {
            playbackProgress = Double(percentage) / 100.0
            isPlayed = percentage >= 95
            hasExplicitPlayedStatus = true
        }

        var hasExplicitIsPlayed = false
        if let explicitPlayed = data["isPlayed"] as? Bool {
            isPlayed = explicitPlayed
            hasExplicitIsPlayed = true
            hasExplicitPlayedStatus = true
            if explicitPlayed {
                playbackProgress = 1.0
            }
        } else if let explicitPlayed = progressRenderer?["isPlayed"] as? Bool {
            isPlayed = explicitPlayed
            hasExplicitIsPlayed = true
            hasExplicitPlayedStatus = true
            if explicitPlayed {
                playbackProgress = 1.0
            }
        }

        if !hasExplicitIsPlayed,
           let playbackState = (data["playbackState"] as? String)
           ?? (progressRenderer?["playbackState"] as? String)
        {
            hasExplicitPlayedStatus = true
            if !isPlayed, playbackState == "PLAYBACK_STATE_PLAYED" || playbackState == "PLAYED" {
                isPlayed = true
                playbackProgress = 1.0
            }
        }

        if !isPlayed,
           !hasExplicitPlayedStatus,
           progressRenderer == nil,
           let playedTextRuns = data["playedText"] as? [String: Any],
           let runs = playedTextRuns["runs"] as? [[String: Any]],
           let text = runs.first?["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            isPlayed = true
            playbackProgress = 1.0
        }

        var duration: String?
        var durationSeconds: Int?

        if let durationText = data["durationText"] as? [String: Any],
           let runs = durationText["runs"] as? [[String: Any]],
           let durationStr = runs.first?["text"] as? String
        {
            duration = durationStr
            durationSeconds = Self.parseDurationToSeconds(durationStr)
        }

        var publishedDate: String?
        if let publishedTimeText = data["publishedTimeText"] as? [String: Any],
           let runs = publishedTimeText["runs"] as? [[String: Any]],
           let dateStr = runs.first?["text"] as? String
        {
            publishedDate = dateStr
        }

        var description: String?
        if let descriptionData = data["description"] as? [String: Any],
           let runs = descriptionData["runs"] as? [[String: Any]]
        {
            description = ParsingHelpers.joinedRunText(runs)
        }

        let episode = PodcastEpisode(
            id: videoId,
            title: title,
            showTitle: showTitle,
            showBrowseId: showBrowseId,
            description: description,
            thumbnailURL: thumbnailURL,
            publishedDate: publishedDate,
            duration: duration,
            durationSeconds: durationSeconds,
            playbackProgress: playbackProgress,
            isPlayed: isPlayed
        )

        return .episode(episode)
    }

    private static func parseResponsiveListItem(_ data: [String: Any]) -> PodcastSectionItem? {
        guard let videoId = ParsingHelpers.extractVideoId(from: data) else {
            if let browseId = ParsingHelpers.extractBrowseId(from: data),
               browseId.hasPrefix("MPSPP")
            {
                let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown Show"
                let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)
                let author = ParsingHelpers.extractSubtitleFromFlexColumns(data)

                let show = PodcastShow(
                    id: browseId,
                    title: title,
                    author: author,
                    description: nil,
                    thumbnailURL: thumbnailURL,
                    episodeCount: nil
                )
                return .show(show)
            }
            return nil
        }

        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown Episode"
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)
        let showTitle = ParsingHelpers.extractSubtitleFromFlexColumns(data)

        let episode = PodcastEpisode(
            id: videoId,
            title: title,
            showTitle: showTitle,
            showBrowseId: nil,
            description: nil,
            thumbnailURL: thumbnailURL,
            publishedDate: nil,
            duration: nil,
            durationSeconds: nil,
            playbackProgress: 0,
            isPlayed: false
        )

        return .episode(episode)
    }

    static func parseShowDetail( // swiftlint:disable:this function_body_length cyclomatic_complexity
        _ data: [String: Any],
        showId: String
    ) -> PodcastShowDetail {
        var showTitle = ""
        var author: String?
        var description: String?
        var thumbnailURL: URL?
        var episodes: [PodcastEpisode] = []
        var continuationToken: String?
        var isSubscribed = false

        if let header = data["header"] as? [String: Any],
           let musicDetailHeaderRenderer = header["musicDetailHeaderRenderer"] as? [String: Any]
        {
            showTitle = ParsingHelpers.extractTitle(from: musicDetailHeaderRenderer) ?? ""
            author = ParsingHelpers.extractSubtitle(from: musicDetailHeaderRenderer)
            description = Self.extractDescription(from: musicDetailHeaderRenderer)

            thumbnailURL = ParsingHelpers.extractThumbnailURL(from: musicDetailHeaderRenderer)
        }

        if let contents = data["contents"] as? [String: Any],
           let twoColumnResults = contents["twoColumnBrowseResultsRenderer"] as? [String: Any]
        {
            if let tabs = twoColumnResults["tabs"] as? [[String: Any]],
               let firstTab = tabs.first,
               let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
               let tabContent = tabRenderer["content"] as? [String: Any],
               let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
               let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
            {
                for sectionData in sectionContents {
                    if let headerRenderer = sectionData["musicResponsiveHeaderRenderer"] as? [String: Any] {
                        showTitle = ParsingHelpers.extractTitle(from: headerRenderer) ?? showTitle
                        author = ParsingHelpers.extractSubtitle(from: headerRenderer) ?? author
                        description = Self.extractDescription(from: headerRenderer) ?? description

                        if let headerThumbnailURL = ParsingHelpers.extractThumbnailURL(from: headerRenderer) {
                            thumbnailURL = headerThumbnailURL
                        }

                        if let buttons = headerRenderer["buttons"] as? [[String: Any]] {
                            for button in buttons {
                                if let toggleButton = button["toggleButtonRenderer"] as? [String: Any],
                                   let toggled = toggleButton["isToggled"] as? Bool
                                {
                                    isSubscribed = toggled
                                    break
                                }
                            }
                        }
                    }
                }
            }

            if let secondaryContents = twoColumnResults["secondaryContents"] as? [String: Any],
               let sectionListRenderer = secondaryContents["sectionListRenderer"] as? [String: Any],
               let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
            {
                for sectionData in sectionContents {
                    if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
                       let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                    {
                        for itemData in shelfContents {
                            if let item = Self.parsePodcastItem(itemData),
                               case let .episode(episode) = item
                            {
                                episodes.append(episode)
                            }
                        }

                        if let continuations = shelfRenderer["continuations"] as? [[String: Any]],
                           let firstContinuation = continuations.first,
                           let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
                           let token = nextContinuationData["continuation"] as? String
                        {
                            continuationToken = token
                        }
                    }
                }
            }
        }

        if episodes.isEmpty,
           let contents = data["contents"] as? [String: Any],
           let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
           let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
           let firstTab = tabs.first,
           let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
           let tabContent = tabRenderer["content"] as? [String: Any],
           let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
           let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        {
            for sectionData in sectionContents {
                if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
                   let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                {
                    for itemData in shelfContents {
                        if let item = Self.parsePodcastItem(itemData),
                           case let .episode(episode) = item
                        {
                            episodes.append(episode)
                        }
                    }

                    if continuationToken == nil,
                       let continuations = shelfRenderer["continuations"] as? [[String: Any]],
                       let firstContinuation = continuations.first,
                       let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
                       let token = nextContinuationData["continuation"] as? String
                    {
                        continuationToken = token
                    }
                }
            }
        }

        let show = PodcastShow(
            id: showId,
            title: showTitle,
            author: author,
            description: description,
            thumbnailURL: thumbnailURL,
            episodeCount: episodes.count
        )

        return PodcastShowDetail(
            show: show,
            episodes: episodes,
            continuationToken: continuationToken,
            isSubscribed: isSubscribed
        )
    }

    static func parseEpisodesContinuation(_ data: [String: Any]) -> PodcastEpisodesContinuation {
        var episodes: [PodcastEpisode] = []
        var continuationToken: String?

        if let continuationContents = data["continuationContents"] as? [String: Any],
           let shelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any],
           let contents = shelfContinuation["contents"] as? [[String: Any]]
        {
            for itemData in contents {
                if let item = Self.parsePodcastItem(itemData),
                   case let .episode(episode) = item
                {
                    episodes.append(episode)
                }
            }

            if let continuations = shelfContinuation["continuations"] as? [[String: Any]],
               let firstContinuation = continuations.first,
               let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
               let token = nextContinuationData["continuation"] as? String
            {
                continuationToken = token
            }
        }

        return PodcastEpisodesContinuation(
            episodes: episodes,
            continuationToken: continuationToken
        )
    }

    private static func extractPodcastItemId(_ item: PodcastSectionItem) -> String {
        switch item {
        case let .show(show): show.id
        case let .episode(episode): episode.id
        }
    }

    private static func extractCarouselTitle(from data: [String: Any]) -> String? {
        if let header = data["header"] as? [String: Any],
           let headerRenderer = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
        {
            return ParsingHelpers.extractTitle(from: headerRenderer)
        }
        return nil
    }

    private static func extractMultiRowTitle(from data: [String: Any]) -> String? {
        if let title = data["title"] as? [String: Any],
           let runs = title["runs"] as? [[String: Any]],
           let text = runs.first?["text"] as? String
        {
            return text
        }
        return nil
    }

    private static func extractMultiRowSubtitle(from data: [String: Any]) -> String? {
        if let subtitle = data["subtitle"] as? [String: Any],
           let runs = subtitle["runs"] as? [[String: Any]],
           let text = runs.first?["text"] as? String
        {
            return text
        }
        return nil
    }

    private static func extractShowBrowseId(from data: [String: Any]) -> String? {
        if let subtitle = data["subtitle"] as? [String: Any],
           let runs = subtitle["runs"] as? [[String: Any]]
        {
            for run in runs {
                if let navigationEndpoint = run["navigationEndpoint"] as? [String: Any],
                   let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
                   let browseId = browseEndpoint["browseId"] as? String,
                   browseId.hasPrefix("MPSPP")
                {
                    return browseId
                }
            }
        }
        return nil
    }

    private static func extractDescription(from data: [String: Any]) -> String? {
        if let description = data["description"] as? [String: Any],
           let runs = description["runs"] as? [[String: Any]]
        {
            return ParsingHelpers.joinedRunText(runs)
        }
        return nil
    }

    private static func parseDurationToSeconds(_ string: String) -> Int? {
        if string.hasSuffix(" min") {
            let numberPart = string.dropLast(4)
            if let minutes = Int(numberPart) {
                return minutes * 60
            }
        }

        let components = string.split(separator: ":").compactMap { Int($0) }
        if components.count == 2 {
            return components[0] * 60 + components[1]
        } else if components.count == 3 {
            return components[0] * 3600 + components[1] * 60 + components[2]
        }

        return nil
    }

    static func isPodcastShow(_ browseId: String) -> Bool {
        browseId.hasPrefix("MPSPP")
    }

    static func isPodcastContent(_ data: [String: Any]) -> Bool {
        if data["musicMultiRowListItemRenderer"] != nil {
            return true
        }

        if let multiRow = data["musicMultiRowListItemRenderer"] as? [String: Any],
           multiRow["playbackProgress"] != nil
        {
            return true
        }

        if let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
           let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String,
           browseId.hasPrefix("MPSPP")
        {
            return true
        }

        return false
    }
}
