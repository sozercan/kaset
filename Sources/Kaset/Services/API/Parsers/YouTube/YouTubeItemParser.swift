import Foundation

/// Parses individual YouTube items from InnerTube responses.
///
/// YouTube is mid-migration between renderer generations (June 2026):
/// - Search serves legacy `videoRenderer` / `channelRenderer`
/// - Watch-next, channel pages, playlists, and playlist search serve the
///   newer `lockupViewModel`
///
/// This parser handles both shapes so surfaces keep working as YouTube
/// shifts more of them to view models.
enum YouTubeItemParser {
    // MARK: - Dispatch

    /// Extracts a video from any known item wrapper
    /// (`videoRenderer`, `gridVideoRenderer`, `compactVideoRenderer`,
    /// `richItemRenderer`, or a video `lockupViewModel`).
    static func video(fromAnyItem item: [String: Any]) -> YouTubeVideo? {
        if let renderer = item["videoRenderer"] as? [String: Any]
            ?? item["gridVideoRenderer"] as? [String: Any]
            ?? item["compactVideoRenderer"] as? [String: Any]
            ?? item["videoCardRenderer"] as? [String: Any]
            ?? item["playlistVideoRenderer"] as? [String: Any]
        {
            return self.video(fromVideoRenderer: renderer)
        }

        if let richItem = item["richItemRenderer"] as? [String: Any],
           let content = richItem["content"] as? [String: Any]
        {
            return self.video(fromAnyItem: content)
        }

        if let lockup = item["lockupViewModel"] as? [String: Any] {
            return self.video(fromLockup: lockup)
        }

        return nil
    }

    // MARK: - Legacy Renderers

    /// Parses a legacy `videoRenderer` / `gridVideoRenderer` / `compactVideoRenderer`.
    static func video(fromVideoRenderer renderer: [String: Any]) -> YouTubeVideo? {
        guard let videoId = renderer["videoId"] as? String,
              let title = text(from: renderer["title"])
        else {
            return nil
        }

        let ownerRun = (renderer["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]]
            ?? (renderer["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let channelName = ownerRun?.first?["text"] as? String
        let channelId = (
            ((ownerRun?.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"]
                as? [String: Any])?["browseId"]
        ) as? String

        let lengthText = self.text(from: renderer["lengthText"])
        let isLive = self.hasLiveBadge(renderer["badges"]) || lengthText == nil && self.hasLiveOverlay(renderer)

        return YouTubeVideo(
            videoId: videoId,
            title: title,
            channelName: channelName,
            channelId: channelId,
            lengthText: lengthText,
            viewCountText: self.text(from: renderer["shortViewCountText"])
                ?? self.text(from: renderer["viewCountText"]),
            publishedText: self.text(from: renderer["publishedTimeText"]),
            thumbnailURL: self.thumbnailURL(fromThumbnail: renderer["thumbnail"]),
            isLive: isLive,
            isShort: self.isShort(navigationContainer: renderer["navigationEndpoint"]),
            watchedPercent: self.watchedPercent(ofRenderer: renderer)
        )
    }

    /// Parses a `shortsLockupViewModel` (Shorts shelves in feeds and search).
    static func short(fromShortsLockup lockup: [String: Any]) -> YouTubeVideo? {
        let onTapCommand = (lockup["onTap"] as? [String: Any])?["innertubeCommand"]
            as? [String: Any]
        let reelWatch = onTapCommand?["reelWatchEndpoint"] as? [String: Any]
        guard let videoId = reelWatch?["videoId"] as? String
            ?? (lockup["entityId"] as? String)?
            .split(separator: "-").last.map(String.init)
        else {
            return nil
        }

        let overlay = lockup["overlayMetadata"] as? [String: Any]
        guard let title = self.text(from: overlay?["primaryText"]) else {
            return nil
        }

        let sources = (
            (lockup["thumbnailViewModel"] as? [String: Any])?["image"] as? [String: Any]
        )?["sources"] as? [[String: Any]]

        return YouTubeVideo(
            videoId: videoId,
            title: title,
            viewCountText: self.text(from: overlay?["secondaryText"]),
            thumbnailURL: sources.flatMap { self.bestSourceURL(from: $0) },
            isShort: true
        )
    }

    /// Whether a navigation container points at the Shorts player
    /// (`reelWatchEndpoint` or a `/shorts/…` web URL).
    static func isShort(navigationContainer: Any?) -> Bool {
        guard let container = navigationContainer as? [String: Any] else { return false }
        if container["reelWatchEndpoint"] != nil {
            return true
        }
        let url = (
            (container["commandMetadata"] as? [String: Any])?["webCommandMetadata"]
                as? [String: Any]
        )?["url"] as? String
        return url?.hasPrefix("/shorts/") == true
    }

    /// Parses a legacy `channelRenderer` from channel search results.
    static func channel(fromChannelRenderer renderer: [String: Any]) -> YouTubeChannel? {
        guard let channelId = renderer["channelId"] as? String,
              let name = text(from: renderer["title"])
        else {
            return nil
        }

        // June 2026 quirk: `subscriberCountText` carries the handle
        // ("@veritasium") and `videoCountText` carries the subscriber count
        // ("20.8M subscribers"). Assign by content, not by field name.
        let subscriberField = self.text(from: renderer["subscriberCountText"])
        let videoCountField = self.text(from: renderer["videoCountText"])
        let handle = [subscriberField, videoCountField]
            .compactMap(\.self)
            .first { $0.hasPrefix("@") }
        let subscriberCount = [videoCountField, subscriberField]
            .compactMap(\.self)
            .first { !$0.hasPrefix("@") }

        return YouTubeChannel(
            channelId: channelId,
            name: name,
            handle: handle,
            subscriberCountText: subscriberCount,
            descriptionSnippet: self.text(from: renderer["descriptionSnippet"]),
            thumbnailURL: self.thumbnailURL(fromThumbnail: renderer["thumbnail"])
        )
    }

    // MARK: - Lockup View Models

    /// Parses a video `lockupViewModel` (watch-next, channel pages, playlists).
    static func video(fromLockup lockup: [String: Any]) -> YouTubeVideo? {
        guard (lockup["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO" else {
            return nil
        }

        let watchEndpoint = self.onTapCommand(of: lockup)?["watchEndpoint"] as? [String: Any]
        guard let videoId = watchEndpoint?["videoId"] as? String
            ?? lockup["contentId"] as? String
        else {
            return nil
        }

        let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"]
            as? [String: Any]
        guard let title = ((metadata?["title"] as? [String: Any])?["content"]) as? String else {
            return nil
        }

        let metadataRowTexts = self.metadataRowTexts(of: metadata)
        // Row 0 is typically the channel name; row 1 holds "X views · Y ago".
        let channelName = metadataRowTexts.first?.first
        let statsRow = metadataRowTexts.dropFirst().first ?? []
        let viewCountText = statsRow.first { $0.localizedCaseInsensitiveContains("view") }
            ?? statsRow.first
        let publishedText = statsRow.first { $0.localizedCaseInsensitiveContains("ago") }

        let badgeText = self.thumbnailBadgeText(of: lockup)
        let isShort = self.isShort(navigationContainer: self.onTapCommand(of: lockup))
            || self.hasPortraitThumbnail(of: lockup)

        return YouTubeVideo(
            videoId: videoId,
            title: title,
            channelName: channelName,
            channelId: self.channelBrowseId(of: metadata),
            lengthText: badgeText.flatMap { $0.contains(":") ? $0 : nil },
            viewCountText: viewCountText,
            publishedText: publishedText,
            thumbnailURL: self.thumbnailURL(fromLockup: lockup),
            isLive: badgeText?.localizedCaseInsensitiveCompare("live") == .orderedSame,
            isShort: isShort,
            watchedPercent: self.watchedPercent(ofLockup: lockup)
        )
    }

    /// Portrait (taller-than-wide) lockup thumbnails indicate Shorts.
    private static func hasPortraitThumbnail(of lockup: [String: Any]) -> Bool {
        let sources = (
            ((lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"]
                as? [String: Any])?["image"] as? [String: Any]
        )?["sources"] as? [[String: Any]]
        guard let first = sources?.first,
              let width = first["width"] as? Int,
              let height = first["height"] as? Int,
              width > 0
        else {
            return false
        }
        return height > width
    }

    /// Parses a playlist `lockupViewModel` (playlist search results, shelves).
    static func playlist(fromLockup lockup: [String: Any]) -> YouTubePlaylist? {
        guard (lockup["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_PLAYLIST" else {
            return nil
        }

        guard let playlistId = lockup["contentId"] as? String else {
            return nil
        }

        let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"]
            as? [String: Any]
        guard let title = ((metadata?["title"] as? [String: Any])?["content"]) as? String else {
            return nil
        }

        let metadataRowTexts = self.metadataRowTexts(of: metadata)
        let watchEndpoint = self.onTapCommand(of: lockup)?["watchEndpoint"] as? [String: Any]
        let badgeText = self.thumbnailBadgeText(of: lockup)

        return YouTubePlaylist(
            playlistId: playlistId,
            title: title,
            channelName: metadataRowTexts.first?.first,
            videoCountText: badgeText
                ?? metadataRowTexts.joined().first { $0.localizedCaseInsensitiveContains("video") },
            thumbnailURL: self.thumbnailURL(fromLockup: lockup),
            firstVideoId: watchEndpoint?["videoId"] as? String
        )
    }

    // MARK: - Shared Text/Thumbnail Helpers

    /// Extracts display text from InnerTube's three text encodings:
    /// `{"simpleText": ...}`, `{"runs": [{"text": ...}]}`, and `{"content": ...}`.
    static func text(from value: Any?) -> String? {
        guard let dict = value as? [String: Any] else {
            return value as? String
        }

        if let simple = dict["simpleText"] as? String {
            return simple
        }

        if let content = dict["content"] as? String {
            return content
        }

        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    /// Picks the largest thumbnail from a legacy `thumbnail.thumbnails` array.
    static func thumbnailURL(fromThumbnail value: Any?) -> URL? {
        guard let thumbnail = value as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]]
        else {
            return nil
        }
        return self.bestSourceURL(from: thumbnails)
    }

    /// Picks the largest image source from a lockup's `thumbnailViewModel`.
    static func thumbnailURL(fromLockup lockup: [String: Any]) -> URL? {
        let sources = (
            ((lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"]
                as? [String: Any])?["image"] as? [String: Any]
        )?["sources"] as? [[String: Any]]
        guard let sources else { return nil }
        return self.bestSourceURL(from: sources)
    }

    /// Picks the largest entry from an array of `{url, width, height}` sources,
    /// normalizing protocol-relative URLs.
    static func bestSourceURL(from sources: [[String: Any]]) -> URL? {
        let best = sources.max { lhs, rhs in
            ((lhs["width"] as? Int) ?? 0) < ((rhs["width"] as? Int) ?? 0)
        }
        guard var urlString = best?["url"] as? String else { return nil }
        if urlString.hasPrefix("//") {
            urlString = "https:" + urlString
        }
        return URL(string: urlString)
    }

    // MARK: - Private Lockup Helpers

    /// The lockup's primary tap command (`watchEndpoint`/`browseEndpoint` container).
    private static func onTapCommand(of lockup: [String: Any]) -> [String: Any]? {
        (
            ((lockup["rendererContext"] as? [String: Any])?["commandContext"]
                as? [String: Any])?["onTap"] as? [String: Any]
        )?["innertubeCommand"] as? [String: Any]
    }

    /// Metadata row texts: one inner array of part texts per row.
    private static func metadataRowTexts(of metadata: [String: Any]?) -> [[String]] {
        let rows = (
            (metadata?["metadata"] as? [String: Any])?["contentMetadataViewModel"]
                as? [String: Any]
        )?["metadataRows"] as? [[String: Any]] ?? []

        return rows.compactMap { row in
            guard let parts = row["metadataParts"] as? [[String: Any]] else { return nil }
            let texts = parts.compactMap { part in
                (part["text"] as? [String: Any])?["content"] as? String
            }
            return texts.isEmpty ? nil : texts
        }
    }

    /// The channel browse ID from the lockup metadata's avatar/byline, when present.
    private static func channelBrowseId(of metadata: [String: Any]?) -> String? {
        guard let metadata else { return nil }
        return self.firstBrowseId(in: metadata, matchingPrefix: "UC")
    }

    /// Duration or count badge text from the lockup's thumbnail overlay,
    /// e.g. "17:10" for videos or "120 videos" for playlists.
    private static func thumbnailBadgeText(of lockup: [String: Any]) -> String? {
        let overlays = (
            (lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"]
                as? [String: Any]
        )?["overlays"] as? [[String: Any]] ?? []

        for overlay in overlays {
            let badges = (overlay["thumbnailBottomOverlayViewModel"] as? [String: Any])?["badges"]
                as? [[String: Any]]
                ?? (overlay["thumbnailOverlayBadgeViewModel"] as? [String: Any])?["thumbnailBadges"]
                as? [[String: Any]]
                ?? []
            for badge in badges {
                if let text = (badge["thumbnailBadgeViewModel"] as? [String: Any])?["text"]
                    as? String
                {
                    return text
                }
            }
        }
        return nil
    }

    /// Depth-first search for the first `browseEndpoint.browseId` with the given prefix.
    private static func firstBrowseId(in value: Any, matchingPrefix prefix: String) -> String? {
        if let dict = value as? [String: Any] {
            if let browseEndpoint = dict["browseEndpoint"] as? [String: Any],
               let browseId = browseEndpoint["browseId"] as? String,
               browseId.hasPrefix(prefix)
            {
                return browseId
            }
            for nested in dict.values {
                if let found = self.firstBrowseId(in: nested, matchingPrefix: prefix) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = self.firstBrowseId(in: element, matchingPrefix: prefix) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Watched Progress

    /// Resume-progress percent from a lockup's thumbnail overlay
    /// (`progressBar`, a sibling of the `badges` key read by
    /// `thumbnailBadgeText(of:)`). `nil` when the video is unwatched.
    private static func watchedPercent(ofLockup lockup: [String: Any]) -> Int? {
        let overlays = (
            (lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
        )?["overlays"] as? [[String: Any]] ?? []

        for overlay in overlays {
            guard let bottom = overlay["thumbnailBottomOverlayViewModel"] as? [String: Any],
                  let bar = bottom["progressBar"] as? [String: Any],
                  let viewModel = bar["thumbnailOverlayProgressBarViewModel"] as? [String: Any]
            else {
                continue
            }
            if let percent = Self.percentValue(viewModel["startPercent"]) {
                return percent
            }
        }
        return nil
    }

    /// Resume-progress percent from a legacy `videoRenderer.thumbnailOverlays`
    /// array (`thumbnailOverlayResumePlaybackRenderer.percentDurationWatched`).
    private static func watchedPercent(ofRenderer renderer: [String: Any]) -> Int? {
        guard let overlays = renderer["thumbnailOverlays"] as? [[String: Any]] else {
            return nil
        }

        for overlay in overlays {
            guard let resume = overlay["thumbnailOverlayResumePlaybackRenderer"] as? [String: Any]
            else {
                continue
            }
            if let percent = Self.percentValue(resume["percentDurationWatched"]) {
                return percent
            }
        }
        return nil
    }

    /// Coerces an InnerTube percent (Int or Double encoding) into a clamped
    /// 1…100 Int. A non-positive percent means "no resume progress" (YouTube
    /// emits this for unwatched/preview lockups), so it maps to `nil` and the
    /// progress bar stays hidden.
    private static func percentValue(_ raw: Any?) -> Int? {
        guard let value = (raw as? Int) ?? (raw as? Double).map(Int.init) else {
            return nil
        }
        return value > 0 ? min(value, 100) : nil
    }

    // MARK: - Badges

    private static func hasLiveBadge(_ badges: Any?) -> Bool {
        guard let badges = badges as? [[String: Any]] else { return false }
        return badges.contains { badge in
            let style = (badge["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String
            return style == "BADGE_STYLE_TYPE_LIVE_NOW"
        }
    }

    private static func hasLiveOverlay(_ renderer: [String: Any]) -> Bool {
        guard let overlays = renderer["thumbnailOverlays"] as? [[String: Any]] else { return false }
        return overlays.contains { overlay in
            let style = (overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"]
                as? String
            return style == "LIVE"
        }
    }
}
