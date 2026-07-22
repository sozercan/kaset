import Foundation
import os

/// Parser for the signed-in user's Library browse responses.
enum LibraryContentParser {
    private static let logger = DiagnosticsLogger.api

    /// One page of saved albums and the token for the next page, when present.
    struct LibraryAlbumsPage {
        let albums: [Album]
        let nextPages: [String]
        let isRecognized: Bool

        var nextPage: String? {
            self.nextPages.first
        }

        init(albums: [Album], nextPage: String?, isRecognized: Bool) {
            self.albums = albums
            self.nextPages = nextPage.map { [$0] } ?? []
            self.isRecognized = isRecognized
        }

        init(albums: [Album], nextPages: [String], isRecognized: Bool) {
            self.albums = albums
            self.nextPages = nextPages
            self.isRecognized = isRecognized
        }
    }

    /// Source used for saved-album content in a combined Library response.
    enum LibraryAlbumsSource {
        case dedicated
        case landingFallback
        case partial

        var isAuthoritative: Bool {
            self == .dedicated
        }
    }

    /// Source used for followed-artist content in a combined Library response.
    enum LibraryArtistsSource {
        case dedicated
        case landingFallback
    }

    /// Parsed Library content from YouTube Music browse responses.
    struct LibraryContent {
        let playlists: [Playlist]
        let albums: [Album]
        let artists: [Artist]
        let podcastShows: [PodcastShow]
        let uploadedSongsPlaylist: Playlist?
        let albumsSource: LibraryAlbumsSource
        let artistsSource: LibraryArtistsSource
        let accountScope: String?

        init(
            playlists: [Playlist],
            albums: [Album] = [],
            artists: [Artist],
            podcastShows: [PodcastShow],
            uploadedSongsPlaylist: Playlist? = nil,
            albumsSource: LibraryAlbumsSource = .dedicated,
            artistsSource: LibraryArtistsSource = .dedicated,
            accountScope: String? = nil
        ) {
            self.playlists = playlists
            self.albums = albums
            self.artists = artists
            self.podcastShows = podcastShows
            self.uploadedSongsPlaylist = uploadedSongsPlaylist
            self.albumsSource = albumsSource
            self.artistsSource = artistsSource
            self.accountScope = accountScope
        }
    }

    private struct AlbumRendererInput {
        let renderer: [String: Any]
        let itemsKey: String
    }

    private struct ParsedAlbumRenderers {
        let albums: [Album]
        let nextPages: [String]
        let isRecognized: Bool
    }

    private struct LibraryItemCandidate {
        let sourceName: String
        let browseId: String
        let browseEndpoint: [String: Any]
        let title: String
        let subtitle: String?
        let subtitleRuns: [[String: Any]]
        let thumbnailURL: URL?
        let allowsRadioPlaylist: Bool
        let renderer: [String: Any]
    }

    static func parseLibraryPlaylists(_ data: [String: Any]) -> [Playlist] {
        self.parseLibraryContent(data).playlists
    }

    /// Parses albums from the dedicated saved-albums browse response.
    static func parseLibraryAlbums(_ data: [String: Any]) -> [Album] {
        let pageAlbums = self.parseLibraryAlbumsPage(data).albums
        return self.mergedLibraryAlbums(
            dedicated: pageAlbums,
            fallback: self.parseLibraryContent(data).albums
        )
    }

    /// Parses the first saved-albums page and its continuation token.
    static func parseLibraryAlbumsPage(_ data: [String: Any]) -> LibraryAlbumsPage {
        let genericAlbums = self.parseLibraryContent(data).albums
        let rendererInputs = ResponseTreeSearch.dictionaries(named: "gridRenderer", in: data).map {
            AlbumRendererInput(renderer: $0, itemsKey: "items")
        } + ResponseTreeSearch.dictionaries(named: "musicShelfRenderer", in: data).map {
            AlbumRendererInput(renderer: $0, itemsKey: "contents")
        }

        if !rendererInputs.isEmpty {
            let parsedRenderers = Self.parseAlbumRenderers(
                rendererInputs,
                allowAuthoritativeEmpty: Self.isTrustedSavedAlbumsResponse(data)
            )
            return LibraryAlbumsPage(
                albums: self.mergedLibraryAlbums(
                    dedicated: genericAlbums,
                    fallback: parsedRenderers.albums
                ),
                nextPages: parsedRenderers.nextPages,
                isRecognized: parsedRenderers.isRecognized
            )
        }

        if !genericAlbums.isEmpty {
            return LibraryAlbumsPage(albums: genericAlbums, nextPage: nil, isRecognized: true)
        }

        return LibraryAlbumsPage(albums: [], nextPage: nil, isRecognized: false)
    }

    /// Parses a saved-albums continuation response in legacy or append-action format.
    static func parseLibraryAlbumsContinuation(_ data: [String: Any]) -> LibraryAlbumsPage {
        if let gridContinuation = ResponseTreeSearch.firstDictionary(named: "gridContinuation", in: data) {
            guard let items = gridContinuation["items"] as? [[String: Any]] else {
                return LibraryAlbumsPage(albums: [], nextPage: nil, isRecognized: false)
            }
            let parsedItems = Self.parseRecognizedAlbumItems(items)
            let nextPage = Self.nextPage(from: gridContinuation, itemsKey: "items")
            let hasContinuationSentinel = items.contains { $0["continuationItemRenderer"] != nil }
            let advertisesContinuation = hasContinuationSentinel || gridContinuation["continuations"] != nil
            return LibraryAlbumsPage(
                albums: parsedItems.albums,
                nextPage: nextPage,
                isRecognized: parsedItems.isRecognized
                    && (!advertisesContinuation || nextPage != nil)
            )
        }

        if let shelfContinuation = ResponseTreeSearch.firstDictionary(named: "musicShelfContinuation", in: data) {
            guard let items = shelfContinuation["contents"] as? [[String: Any]] else {
                return LibraryAlbumsPage(albums: [], nextPage: nil, isRecognized: false)
            }
            let parsedItems = Self.parseRecognizedAlbumItems(items)
            let nextPage = Self.nextPage(from: shelfContinuation, itemsKey: "contents")
            let hasContinuationSentinel = items.contains { $0["continuationItemRenderer"] != nil }
            let advertisesContinuation = hasContinuationSentinel || shelfContinuation["continuations"] != nil
            return LibraryAlbumsPage(
                albums: parsedItems.albums,
                nextPage: nextPage,
                isRecognized: parsedItems.isRecognized
                    && (!advertisesContinuation || nextPage != nil)
            )
        }

        if let appendAction = ResponseTreeSearch.firstDictionary(named: "appendContinuationItemsAction", in: data) {
            guard let items = appendAction["continuationItems"] as? [[String: Any]] else {
                return LibraryAlbumsPage(albums: [], nextPage: nil, isRecognized: false)
            }
            let parsedItems = Self.parseRecognizedAlbumItems(items)
            let nextPage = Self.nextPage(from: appendAction, itemsKey: "continuationItems")
            let hasContinuationSentinel = items.contains { $0["continuationItemRenderer"] != nil }
            let advertisesContinuation = hasContinuationSentinel || appendAction["continuations"] != nil
            return LibraryAlbumsPage(
                albums: parsedItems.albums,
                nextPage: nextPage,
                isRecognized: parsedItems.isRecognized
                    && (!advertisesContinuation || nextPage != nil)
            )
        }

        return LibraryAlbumsPage(albums: [], nextPage: nil, isRecognized: false)
    }

    /// Parses library content from browse response, returning playlists, albums, artists, and podcast shows.
    static func parseLibraryContent(_ data: [String: Any]) -> LibraryContent {
        var playlists: [Playlist] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var podcastShows: [PodcastShow] = []

        for sectionData in Self.extractLibrarySections(from: data) {
            Self.appendLibraryItems(
                from: sectionData,
                playlists: &playlists,
                albums: &albums,
                artists: &artists,
                podcastShows: &podcastShows
            )
        }

        return LibraryContent(
            playlists: playlists,
            albums: albums,
            artists: artists,
            podcastShows: podcastShows
        )
    }

    /// Merges library playlists using the dedicated endpoint as authoritative while retaining landing-only items.
    static func mergedLibraryPlaylists(dedicated dedicatedPlaylists: [Playlist], fallback fallbackPlaylists: [Playlist]) -> [Playlist] {
        var mergedPlaylists = dedicatedPlaylists
        var seenPlaylistKeys = Set(dedicatedPlaylists.map { LibraryContentIdentity.playlistKey(for: $0) })

        for playlist in fallbackPlaylists {
            let playlistKey = LibraryContentIdentity.playlistKey(for: playlist)
            guard seenPlaylistKeys.insert(playlistKey).inserted else { continue }
            mergedPlaylists.append(playlist)
        }

        return mergedPlaylists
    }

    /// Merges dedicated saved albums with any landing-page preview albums.
    static func mergedLibraryAlbums(dedicated dedicatedAlbums: [Album], fallback fallbackAlbums: [Album]) -> [Album] {
        var mergedAlbums = dedicatedAlbums
        var seenAlbumIDs = Set(dedicatedAlbums.map(\.id))

        for album in fallbackAlbums {
            guard seenAlbumIDs.insert(album.id).inserted else { continue }
            mergedAlbums.append(album)
        }

        return mergedAlbums
    }

    /// Parses artists from the dedicated library artists browse response.
    static func parseLibraryArtists(_ data: [String: Any]) -> [Artist] {
        var artists: [Artist] = []
        var ignoredPlaylists: [Playlist] = []
        var ignoredAlbums: [Album] = []
        var ignoredPodcastShows: [PodcastShow] = []

        for sectionData in Self.extractLibrarySections(from: data) {
            Self.appendLibraryItems(
                from: sectionData,
                playlists: &ignoredPlaylists,
                albums: &ignoredAlbums,
                artists: &artists,
                podcastShows: &ignoredPodcastShows
            )
        }

        return LibraryContentIdentity.deduplicatedArtists(artists)
    }

    /// Parses the uploaded songs browse endpoint into a virtual playlist tile for Library.
    static func parseUploadedSongsPlaylist(_ data: [String: Any]) -> Playlist? {
        let detail = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: Playlist.uploadedSongsBrowseID).detail
        guard !detail.tracks.isEmpty || (detail.trackCount ?? 0) > 0 else {
            return nil
        }

        let title = detail.title == "Unknown Playlist" ? "Uploaded Songs" : detail.title
        return Playlist(
            id: Playlist.uploadedSongsBrowseID,
            title: title,
            description: nil,
            thumbnailURL: detail.thumbnailURL ?? detail.tracks.first?.thumbnailURL,
            trackCount: max(detail.trackCount ?? 0, detail.tracks.count),
            author: Artist.inline(name: "Uploads", namespace: "library-upload"),
            canDelete: false
        )
    }

    private static func extractLibrarySections(from data: [String: Any]) -> [[String: Any]] {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return []
        }

        return sectionContents
    }

    private static func appendLibraryItems(
        from sectionData: [String: Any],
        playlists: inout [Playlist],
        albums: inout [Album],
        artists: inout [Artist],
        podcastShows: inout [PodcastShow]
    ) {
        // Try gridRenderer
        if let gridRenderer = sectionData["gridRenderer"] as? [String: Any],
           let items = gridRenderer["items"] as? [[String: Any]]
        {
            for itemData in items {
                let candidate: LibraryItemCandidate? = if let twoRowRenderer = itemData["musicTwoRowItemRenderer"] as? [String: Any] {
                    Self.twoRowCandidate(from: twoRowRenderer)
                } else if let responsiveRenderer = itemData["musicResponsiveListItemRenderer"] as? [String: Any] {
                    Self.responsiveCandidate(from: responsiveRenderer)
                } else {
                    nil
                }
                Self.appendLibraryItem(
                    candidate,
                    playlists: &playlists,
                    albums: &albums,
                    artists: &artists,
                    podcastShows: &podcastShows
                )
            }
        }

        // Try itemSectionRenderer > musicShelfRenderer
        if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
           let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
        {
            for itemContent in itemContents {
                guard let shelfRenderer = itemContent["musicShelfRenderer"] as? [String: Any],
                      let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                else { continue }

                Self.appendResponsiveLibraryItems(
                    shelfContents,
                    playlists: &playlists,
                    albums: &albums,
                    artists: &artists,
                    podcastShows: &podcastShows
                )
            }
        }

        // Try musicShelfRenderer directly
        if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
           let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
        {
            Self.appendResponsiveLibraryItems(
                shelfContents,
                playlists: &playlists,
                albums: &albums,
                artists: &artists,
                podcastShows: &podcastShows
            )
        }
    }

    private static func appendResponsiveLibraryItems(
        _ shelfContents: [[String: Any]],
        playlists: inout [Playlist],
        albums: inout [Album],
        artists: inout [Artist],
        podcastShows: inout [PodcastShow]
    ) {
        for shelfItem in shelfContents {
            guard let responsiveRenderer = shelfItem["musicResponsiveListItemRenderer"] as? [String: Any] else { continue }
            Self.appendLibraryItem(
                Self.responsiveCandidate(from: responsiveRenderer),
                playlists: &playlists,
                albums: &albums,
                artists: &artists,
                podcastShows: &podcastShows
            )
        }
    }

    private static func isTrustedSavedAlbumsResponse(_ data: [String: Any]) -> Bool {
        self.trackingValue(for: "logged_in", in: data) == "1"
            && self.trackingValue(for: "browse_id", in: data) == "FEmusic_liked_albums"
    }

    private static func trackingValue(for key: String, in data: [String: Any]) -> String? {
        guard let responseContext = data["responseContext"] as? [String: Any],
              let serviceTrackingParams = responseContext["serviceTrackingParams"] as? [[String: Any]]
        else {
            return nil
        }

        for serviceTrackingParam in serviceTrackingParams {
            guard let params = serviceTrackingParam["params"] as? [[String: Any]] else { continue }
            if let matchingParam = params.first(where: { $0["key"] as? String == key }) {
                return matchingParam["value"] as? String
            }
        }

        return nil
    }

    private static func parseAlbumRenderers(
        _ rendererInputs: [AlbumRendererInput],
        allowAuthoritativeEmpty: Bool
    ) -> ParsedAlbumRenderers {
        var albums: [Album] = []
        var nextPages: [String] = []
        var foundRelevantRenderer = false
        var foundPartialRenderer = false

        for input in rendererInputs {
            guard let items = input.renderer[input.itemsKey] as? [[String: Any]] else { continue }
            let parsedItems = Self.parseRecognizedAlbumItems(items)
            let nextPage = Self.nextPage(from: input.renderer, itemsKey: input.itemsKey)
            let hasContinuationSentinel = items.contains { $0["continuationItemRenderer"] != nil }
            let hasRendererContinuations = input.renderer["continuations"] != nil
            let advertisesContinuation = hasContinuationSentinel || hasRendererContinuations
            let consumedContinuation = !advertisesContinuation || nextPage != nil
            let rendererIsRecognized = parsedItems.isRecognized && consumedContinuation
            let hasAlbums = !parsedItems.albums.isEmpty
            let isContinuationOnlyRenderer = parsedItems.albums.isEmpty
                && (advertisesContinuation || nextPage != nil)
            let isTrustedEmptyRenderer = parsedItems.albums.isEmpty
                && !hasContinuationSentinel
                && rendererInputs.count == 1
                && allowAuthoritativeEmpty
            let isRelevantRenderer = hasAlbums || isContinuationOnlyRenderer || isTrustedEmptyRenderer

            guard isRelevantRenderer else { continue }
            foundRelevantRenderer = true
            if !rendererIsRecognized {
                foundPartialRenderer = true
            }

            albums = self.mergedLibraryAlbums(
                dedicated: albums,
                fallback: parsedItems.albums
            )
            if let nextPage, !nextPages.contains(nextPage) {
                nextPages.append(nextPage)
            }
        }

        return ParsedAlbumRenderers(
            albums: albums,
            nextPages: nextPages,
            isRecognized: foundRelevantRenderer && !foundPartialRenderer
        )
    }

    private static func parseRecognizedAlbumItems(
        _ items: [[String: Any]]
    ) -> (albums: [Album], isRecognized: Bool) {
        let contentItems = items.filter { $0["continuationItemRenderer"] == nil }
        let albums = Self.parseAlbumItems(contentItems)
        return (
            albums: albums,
            isRecognized: contentItems.isEmpty || albums.count == contentItems.count
        )
    }

    private static func parseAlbumItems(_ items: [[String: Any]]) -> [Album] {
        items.compactMap { item -> Album? in
            let candidate: LibraryItemCandidate? = if let twoRowRenderer = item["musicTwoRowItemRenderer"] as? [String: Any] {
                Self.twoRowCandidate(from: twoRowRenderer)
            } else if let responsiveRenderer = item["musicResponsiveListItemRenderer"] as? [String: Any] {
                Self.responsiveCandidate(from: responsiveRenderer)
            } else {
                nil
            }

            guard let candidate, Self.isAlbum(candidate) else { return nil }
            return Self.album(from: candidate)
        }
    }

    private static func twoRowCandidate(from data: [String: Any]) -> LibraryItemCandidate? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            self.logger.debug("parseLibraryItem: No browseId found")
            return nil
        }

        return LibraryItemCandidate(
            sourceName: "parseLibraryItem",
            browseId: browseId,
            browseEndpoint: browseEndpoint,
            title: ParsingHelpers.extractTitle(from: data) ?? "Unknown",
            subtitle: ParsingHelpers.extractSubtitle(from: data),
            subtitleRuns: Self.twoRowSubtitleRuns(from: data),
            thumbnailURL: ParsingHelpers.extractThumbnailURL(from: data),
            allowsRadioPlaylist: true,
            renderer: data
        )
    }

    private static func responsiveCandidate(from data: [String: Any]) -> LibraryItemCandidate? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            self.logger.debug("parseLibraryItemFromResponsive: No browseId found, keys: \(Array(data.keys))")
            return nil
        }

        return LibraryItemCandidate(
            sourceName: "parseLibraryItemFromResponsive",
            browseId: browseId,
            browseEndpoint: browseEndpoint,
            title: ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown",
            subtitle: ParsingHelpers.extractSubtitleFromFlexColumns(data),
            subtitleRuns: Self.responsiveSubtitleRuns(from: data),
            thumbnailURL: ParsingHelpers.extractThumbnailURL(from: data),
            allowsRadioPlaylist: false,
            renderer: data
        )
    }

    private static func appendLibraryItem(
        _ candidate: LibraryItemCandidate?,
        playlists: inout [Playlist],
        albums: inout [Album],
        artists: inout [Artist],
        podcastShows: inout [PodcastShow]
    ) {
        guard let candidate else { return }

        Self.logger.info("\(candidate.sourceName): browseId=\(candidate.browseId, privacy: .public), title=\(candidate.title, privacy: .public)")

        if candidate.browseId.hasPrefix("MPSPP") {
            podcastShows.append(Self.podcastShow(from: candidate))
            Self.logger.info("\(candidate.sourceName): Added podcast show: \(candidate.title)")
        } else if Self.isAlbum(candidate) {
            albums.append(Self.album(from: candidate))
            Self.logger.info("\(candidate.sourceName): Added album: \(candidate.title)")
        } else if Self.isPlaylistBrowseID(candidate.browseId, allowsRadioPlaylist: candidate.allowsRadioPlaylist) {
            playlists.append(Self.playlist(from: candidate))
            Self.logger.info("\(candidate.sourceName): Added playlist: \(candidate.title)")
        } else if Artist.isNavigableId(candidate.browseId) {
            artists.append(Self.artist(from: candidate))
            Self.logger.info("\(candidate.sourceName): Added artist: \(candidate.title)")
        } else if candidate.sourceName == "parseLibraryItemFromResponsive" {
            Self.logger.info("\(candidate.sourceName): Skipping unknown prefix: \(candidate.browseId)")
        }
    }

    private static func podcastShow(from candidate: LibraryItemCandidate) -> PodcastShow {
        PodcastShow(
            id: candidate.browseId,
            title: candidate.title,
            author: candidate.subtitle,
            description: nil,
            thumbnailURL: candidate.thumbnailURL,
            episodeCount: nil
        )
    }

    private static func playlist(from candidate: LibraryItemCandidate) -> Playlist {
        Playlist(
            id: candidate.browseId,
            title: candidate.title,
            description: nil,
            thumbnailURL: candidate.thumbnailURL,
            trackCount: nil,
            author: candidate.subtitle.map { Artist.inline(name: $0, namespace: "playlist-author") },
            canDelete: PlaylistEditability.canDeletePlaylist(from: candidate.renderer)
        )
    }

    private static func album(from candidate: LibraryItemCandidate) -> Album {
        var seenArtistIDs = Set<String>()
        let linkedArtists = candidate.subtitleRuns.compactMap { run -> Artist? in
            guard let name = Self.normalizedRunText(run),
                  let navigationEndpoint = run["navigationEndpoint"] as? [String: Any],
                  let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
                  let artistID = browseEndpoint["browseId"] as? String,
                  Artist.isNavigableId(artistID),
                  seenArtistIDs.insert(artistID).inserted
            else {
                return nil
            }

            return Artist(
                id: artistID,
                name: name,
                profileKind: Artist.profileKind(forPageType: ParsingHelpers.extractPageType(from: browseEndpoint))
            )
        }

        let year = candidate.subtitleRuns
            .compactMap(Self.normalizedRunText)
            .first(where: Self.isAlbumYear)

        let artists: [Artist]? = if linkedArtists.isEmpty {
            Self.fallbackAlbumArtist(from: candidate.subtitleRuns, year: year).map {
                [Artist.inline(name: $0, namespace: "library-album-artist")]
            }
        } else {
            linkedArtists
        }

        return Album(
            id: candidate.browseId,
            title: candidate.title,
            artists: artists,
            thumbnailURL: candidate.thumbnailURL,
            year: year,
            trackCount: nil,
            libraryTargetId: ParsingHelpers.extractAlbumLibraryTargetId(from: candidate.renderer)
        )
    }

    private static func artist(from candidate: LibraryItemCandidate) -> Artist {
        let pageType = ParsingHelpers.extractPageType(from: candidate.browseEndpoint)
        return Artist(
            id: candidate.browseId,
            name: candidate.title,
            thumbnailURL: candidate.thumbnailURL,
            profileKind: Artist.profileKind(forPageType: pageType)
        )
    }

    private static func isAlbum(_ candidate: LibraryItemCandidate) -> Bool {
        let pageType = ParsingHelpers.extractPageType(from: candidate.browseEndpoint)
        return pageType == "MUSIC_PAGE_TYPE_ALBUM"
            || candidate.browseId.hasPrefix("MPRE")
            || candidate.browseId.hasPrefix("OLAK")
    }

    private static func twoRowSubtitleRuns(from data: [String: Any]) -> [[String: Any]] {
        guard let subtitle = data["subtitle"] as? [String: Any],
              let runs = subtitle["runs"] as? [[String: Any]]
        else {
            return []
        }

        return runs
    }

    private static func responsiveSubtitleRuns(from data: [String: Any]) -> [[String: Any]] {
        guard let flexColumns = data["flexColumns"] as? [[String: Any]],
              flexColumns.count > 1,
              let renderer = flexColumns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = renderer["text"] as? [String: Any],
              let runs = text["runs"] as? [[String: Any]]
        else {
            return []
        }

        return runs
    }

    private static func normalizedRunText(_ run: [String: Any]) -> String? {
        guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text != "•",
              text != "&",
              text != ","
        else {
            return nil
        }

        return text
    }

    private static func fallbackAlbumArtist(from runs: [[String: Any]], year: String?) -> String? {
        let metadata = runs.compactMap(Self.normalizedRunText).filter { text in
            text != year && !Self.albumTypeLabels.contains(text.lowercased())
        }
        return metadata.last
    }

    private static func isAlbumYear(_ text: String) -> Bool {
        guard text.count == 4,
              text.allSatisfy(\.isNumber),
              let year = Int(text)
        else {
            return false
        }

        return (1900 ... 2100).contains(year)
    }

    private static func nextPage(from renderer: [String: Any], itemsKey: String) -> String? {
        if let continuations = renderer["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
           let cursor = nextContinuationData["continuation"] as? String
        {
            return cursor
        }

        guard let items = renderer[itemsKey] as? [[String: Any]],
              let lastItem = items.last,
              let continuationItemRenderer = lastItem["continuationItemRenderer"] as? [String: Any],
              let continuationEndpoint = continuationItemRenderer["continuationEndpoint"] as? [String: Any]
        else {
            return nil
        }

        if let continuationCommand = continuationEndpoint["continuationCommand"] as? [String: Any],
           let cursor = continuationCommand["token"] as? String
        {
            return cursor
        }

        guard let commandExecutor = continuationEndpoint["commandExecutorCommand"] as? [String: Any],
              let commands = commandExecutor["commands"] as? [[String: Any]]
        else {
            return nil
        }

        for command in commands {
            if let continuationCommand = command["continuationCommand"] as? [String: Any],
               let cursor = continuationCommand["token"] as? String
            {
                return cursor
            }
        }

        return nil
    }

    private static let albumTypeLabels = Set(["album", "single", "ep"])

    private static func isPlaylistBrowseID(_ browseID: String, allowsRadioPlaylist: Bool) -> Bool {
        browseID.hasPrefix("VL") || browseID.hasPrefix("PL") || (allowsRadioPlaylist && browseID.hasPrefix("RDCLAK"))
    }
}
