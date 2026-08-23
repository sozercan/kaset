import Foundation

// MARK: - SearchResponseParser

enum SearchResponseParser {
    private static let logger = DiagnosticsLogger.api

    private enum ContentKind {
        case song
        case video
        case album
        case audiobook
        case artist
        case profile
        case playlist
        case podcastShow
        case podcastEpisode
    }

    private enum BrowseKind {
        case album
        case audiobook
        case artist
        case profile
        case playlist
        case podcastShow
        case podcastEpisode
    }

    private struct PlayableDestination {
        let videoId: String
        let musicVideoType: MusicVideoType?
    }

    private struct ParseAccumulator {
        var items: [SearchResultItem] = []
        var seenContentIdentities: Set<String> = []
        var continuationToken: String?

        mutating func append(_ item: SearchResultItem) {
            guard self.seenContentIdentities.insert(item.contentIdentity).inserted else {
                return
            }
            self.items.append(item)
        }

        mutating func captureContinuation(_ token: String?) {
            guard self.continuationToken == nil,
                  let token = token?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else {
                return
            }
            self.continuationToken = token
        }
    }

    static func parse(_ data: [String: Any]) -> SearchResponse {
        let sectionLists = Self.firstPageSectionLists(from: data)
        guard !sectionLists.isEmpty else {
            Self.logger.debug("SearchResponseParser: Failed to find a search section list. Top keys: \(data.keys.sorted())")
            return .empty
        }

        var accumulator = ParseAccumulator()
        for sectionList in sectionLists {
            Self.parseSectionList(sectionList, into: &accumulator)
        }

        return SearchResponse(
            items: accumulator.items,
            continuationToken: accumulator.continuationToken
        )
    }

    static func parseSongsOnly(_ data: [String: Any]) -> [Song] {
        self.parse(data).songs
    }

    static func parseAlbumsOnly(_ data: [String: Any]) -> ([Album], String?) {
        let response = Self.parse(data)
        return (response.albums, response.continuationToken)
    }

    static func parseArtistsOnly(_ data: [String: Any]) -> ([Artist], String?) {
        let response = Self.parse(data)
        return (response.artists, response.continuationToken)
    }

    static func parsePlaylistsOnly(_ data: [String: Any]) -> ([Playlist], String?) {
        let response = Self.parse(data)
        return (response.playlists, response.continuationToken)
    }

    static func parsePodcastsOnly(_ data: [String: Any]) -> ([PodcastShow], String?) {
        let response = Self.parse(data)
        return (response.podcastShows, response.continuationToken)
    }

    static func parseSongsWithContinuation(_ data: [String: Any]) -> ([Song], String?) {
        let response = Self.parse(data)
        return (response.songs, response.continuationToken)
    }

    static func parseContinuation(_ data: [String: Any]) -> SearchResponse {
        var accumulator = ParseAccumulator()

        if let continuationContents = data["continuationContents"] as? [String: Any],
           let shelf = continuationContents["musicShelfContinuation"] as? [String: Any]
        {
            Self.parseMusicShelf(shelf, into: &accumulator)
        }

        for items in Self.continuationActionItemGroups(from: data) {
            accumulator.items.reserveCapacity(accumulator.items.count + items.count)
            for item in items {
                Self.parseContainer(item, into: &accumulator)
            }
        }

        return SearchResponse(
            items: accumulator.items,
            continuationToken: accumulator.continuationToken
        )
    }
}

private extension SearchResponseParser {
    private static func firstPageSectionLists(from data: [String: Any]) -> [[String: Any]] {
        guard let contents = data["contents"] as? [String: Any] else {
            return []
        }

        if let directSectionList = contents["sectionListRenderer"] as? [String: Any] {
            return [directSectionList]
        }

        guard let tabbed = contents["tabbedSearchResultsRenderer"] as? [String: Any],
              let tabs = tabbed["tabs"] as? [[String: Any]]
        else {
            return []
        }

        var sectionLists: [[String: Any]] = []
        sectionLists.reserveCapacity(tabs.count)
        for tab in tabs {
            guard let tabRenderer = tab["tabRenderer"] as? [String: Any],
                  let content = tabRenderer["content"] as? [String: Any],
                  let sectionList = content["sectionListRenderer"] as? [String: Any]
            else {
                continue
            }
            sectionLists.append(sectionList)
        }
        return sectionLists
    }

    private static func parseSectionList(
        _ sectionList: [String: Any],
        into accumulator: inout ParseAccumulator
    ) {
        if let contents = sectionList["contents"] as? [[String: Any]] {
            accumulator.items.reserveCapacity(accumulator.items.count + contents.count)
            for content in contents {
                self.parseContainer(content, into: &accumulator)
            }
        }

        accumulator.captureContinuation(Self.extractContinuationToken(from: sectionList))
    }

    private static func parseContainer(
        _ container: [String: Any],
        into accumulator: inout ParseAccumulator
    ) {
        if let card = container["musicCardShelfRenderer"] as? [String: Any] {
            self.parseCardShelf(card, into: &accumulator)
            return
        }

        if let shelf = container["musicShelfRenderer"] as? [String: Any] {
            Self.parseMusicShelf(shelf, into: &accumulator)
            return
        }

        if let itemSection = container["itemSectionRenderer"] as? [String: Any] {
            Self.parseItemSection(itemSection, into: &accumulator)
            return
        }

        if let renderer = container["musicResponsiveListItemRenderer"] as? [String: Any],
           let item = Self.parseResponsiveListItem(renderer)
        {
            accumulator.append(item)
            return
        }

        if let renderer = container["musicTwoRowItemRenderer"] as? [String: Any],
           let item = Self.parseTwoRowItem(renderer)
        {
            accumulator.append(item)
            return
        }

        if let renderer = container["musicMultiRowListItemRenderer"] as? [String: Any],
           let item = Self.parseMultiRowItem(renderer)
        {
            accumulator.append(item)
            return
        }

        accumulator.captureContinuation(Self.extractContinuationToken(fromContinuationItem: container))
    }

    private static func parseCardShelf(
        _ card: [String: Any],
        into accumulator: inout ParseAccumulator
    ) {
        let endpoints = Self.cardEndpointCandidates(from: card)
        if let item = Self.parseItemRenderer(card, endpointCandidates: endpoints) {
            accumulator.append(item)
        }

        if let contents = card["contents"] as? [[String: Any]] {
            for content in contents {
                Self.parseContainer(content, into: &accumulator)
            }
        }

        accumulator.captureContinuation(Self.extractContinuationToken(from: card))
    }

    private static func parseMusicShelf(
        _ shelf: [String: Any],
        into accumulator: inout ParseAccumulator
    ) {
        accumulator.captureContinuation(self.extractContinuationToken(from: shelf))

        guard let contents = shelf["contents"] as? [[String: Any]] else {
            return
        }
        accumulator.items.reserveCapacity(accumulator.items.count + contents.count)
        for content in contents {
            Self.parseContainer(content, into: &accumulator)
        }
    }

    private static func continuationActionItemGroups(
        from data: [String: Any]
    ) -> [[[String: Any]]] {
        var groups: [[[String: Any]]] = []
        for envelopeKey in [
            "onResponseReceivedCommands",
            "onResponseReceivedActions",
            "onResponseReceivedEndpoints",
        ] {
            guard let actions = data[envelopeKey] as? [[String: Any]] else {
                continue
            }
            for action in actions {
                for commandKey in [
                    "appendContinuationItemsAction",
                    "reloadContinuationItemsCommand",
                ] {
                    guard let command = action[commandKey] as? [String: Any],
                          let items = command["continuationItems"] as? [[String: Any]]
                    else {
                        continue
                    }
                    groups.append(items)
                }
            }
        }
        return groups
    }

    private static func parseItemSection(
        _ itemSection: [String: Any],
        into accumulator: inout ParseAccumulator
    ) {
        guard let contents = itemSection["contents"] as? [[String: Any]] else {
            return
        }
        accumulator.items.reserveCapacity(accumulator.items.count + contents.count)
        for content in contents {
            Self.parseContainer(content, into: &accumulator)
        }
    }

    private static func parseResponsiveListItem(_ renderer: [String: Any]) -> SearchResultItem? {
        self.parseItemRenderer(
            renderer,
            endpointCandidates: self.responsiveEndpointCandidates(from: renderer)
        )
    }

    private static func parseTwoRowItem(_ renderer: [String: Any]) -> SearchResultItem? {
        self.parseItemRenderer(
            renderer,
            endpointCandidates: self.directItemEndpointCandidates(from: renderer)
        )
    }

    private static func parseMultiRowItem(_ renderer: [String: Any]) -> SearchResultItem? {
        self.parseItemRenderer(
            renderer,
            endpointCandidates: self.multiRowEndpointCandidates(from: renderer)
        )
    }

    private static func parseItemRenderer(
        _ renderer: [String: Any],
        endpointCandidates: [[String: Any]]
    ) -> SearchResultItem? {
        let title = Self.itemTitle(from: renderer) ?? "Unknown"
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: renderer)
        let contentKind = Self.contentKind(from: renderer)

        var episodeBrowseId: String?
        for endpoint in endpointCandidates {
            guard let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  let browseId = browseEndpoint["browseId"] as? String,
                  let browseKind = Self.browseKind(
                      browseId: browseId,
                      pageType: ParsingHelpers.extractPageType(from: browseEndpoint),
                      contentKind: contentKind
                  )
            else {
                continue
            }

            if browseKind == .podcastEpisode {
                episodeBrowseId = episodeBrowseId ?? browseId
                continue
            }

            return Self.makeBrowseItem(
                kind: browseKind,
                browseId: browseId,
                title: title,
                thumbnailURL: thumbnailURL,
                renderer: renderer
            )
        }

        for endpoint in endpointCandidates {
            let watchPlaylistId = (endpoint["watchPlaylistEndpoint"] as? [String: Any])?["playlistId"] as? String
            let contextualPlaylistId = contentKind == .playlist
                ? (endpoint["watchEndpoint"] as? [String: Any])?["playlistId"] as? String
                : nil
            if let playlistId = watchPlaylistId ?? contextualPlaylistId,
               playlistId.hasPrefix("VL") || playlistId.hasPrefix("PL")
               || playlistId.hasPrefix("VM") || playlistId.hasPrefix("RD")
            {
                return Self.makeBrowseItem(kind: .playlist, browseId: playlistId, title: title, thumbnailURL: thumbnailURL, renderer: renderer)
            }
        }

        guard let playable = Self.playableDestination(
            from: renderer,
            endpointCandidates: endpointCandidates
        ) else {
            return nil
        }

        if episodeBrowseId != nil
            || contentKind == .podcastEpisode
            || playable.musicVideoType == .podcastEpisode
        {
            return .podcastEpisode(Self.makePodcastEpisode(
                renderer: renderer,
                title: title,
                thumbnailURL: thumbnailURL,
                videoId: playable.videoId
            ))
        }

        let isVideo = contentKind == .video || Self.isVideoResult(playable.musicVideoType)
        let song = Self.makeSong(
            renderer: renderer,
            title: title,
            thumbnailURL: thumbnailURL,
            destination: playable
        )
        return isVideo ? .video(song) : .song(song)
    }

    private static func makeBrowseItem(
        kind: BrowseKind,
        browseId: String,
        title: String,
        thumbnailURL: URL?,
        renderer: [String: Any]
    ) -> SearchResultItem? {
        switch kind {
        case .album, .audiobook:
            let artists = Self.itemArtists(from: renderer, allowPlainTextFallback: false)
            let album = Album(
                id: browseId,
                title: title,
                artists: artists.isEmpty ? nil : artists,
                thumbnailURL: thumbnailURL,
                year: Self.metadataComponents(from: renderer).first(where: Self.isYear),
                trackCount: nil
            )
            return kind == .audiobook ? .audiobook(album) : .album(album)

        case .artist, .profile:
            let profileKind: ArtistProfileKind = kind == .profile ? .profile : .artist
            let artist = Artist(
                id: browseId,
                name: title,
                thumbnailURL: thumbnailURL,
                subtitle: Self.semanticSubtitle(from: renderer),
                profileKind: profileKind
            )
            return kind == .profile ? .profile(artist) : .artist(artist)

        case .playlist:
            let subtitleRuns = Self.metadataRuns(from: renderer)
            let author = ParsingHelpers.extractFirstNavigableArtist(from: subtitleRuns)
                ?? Self.fallbackCreatorName(from: renderer).map {
                    Artist.inline(name: $0, namespace: "playlist-author")
                }
            let songCount = Self.songCount(from: renderer)
            return .playlist(Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: songCount,
                author: author
            ))

        case .podcastShow:
            return .podcastShow(PodcastShow(
                id: browseId,
                title: title,
                author: self.fallbackCreatorName(from: renderer),
                description: self.descriptionText(from: renderer),
                thumbnailURL: thumbnailURL,
                episodeCount: nil
            ))

        case .podcastEpisode:
            return nil
        }
    }

    private static func makeSong(
        renderer: [String: Any],
        title: String,
        thumbnailURL: URL?,
        destination: PlayableDestination
    ) -> Song {
        let musicVideoType = destination.musicVideoType
        return Song(
            id: destination.videoId,
            title: title,
            artists: Self.itemArtists(from: renderer, allowPlainTextFallback: true),
            album: ParsingHelpers.extractAlbumFromFlexColumns(renderer),
            duration: ParsingHelpers.extractDurationFromFlexColumns(renderer),
            thumbnailURL: thumbnailURL,
            videoId: destination.videoId,
            isPlayable: ParsingHelpers.isPlayableMusicItem(from: renderer),
            hasVideo: musicVideoType?.hasVideoContent,
            musicVideoType: musicVideoType,
            isExplicit: ParsingHelpers.extractIsExplicit(from: renderer)
        )
    }

    private static func makePodcastEpisode(
        renderer: [String: Any],
        title: String,
        thumbnailURL: URL?,
        videoId: String
    ) -> PodcastEpisode {
        let metadataRuns = Self.metadataRuns(from: renderer)
        let showRun = metadataRuns.first { run in
            guard let endpoint = Self.unwrapEndpoint(run["navigationEndpoint"]),
                  let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  let browseId = browseEndpoint["browseId"] as? String
            else {
                return false
            }
            return browseId.hasPrefix("MPSPP")
        }
        let showTitle = (showRun?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showBrowseId = showRun
            .flatMap { Self.unwrapEndpoint($0["navigationEndpoint"]) }
            .flatMap { $0["browseEndpoint"] as? [String: Any] }
            .flatMap { $0["browseId"] as? String }

        let components = Self.metadataComponents(from: renderer)
        let publishedDate = components.first(where: Self.looksLikePublishedDate)
        let durationText = components.first { component in
            component != publishedDate && Self.looksLikeDuration(component)
        }
        let durationSeconds = ParsingHelpers.extractDurationFromFlexColumns(renderer)
            ?? durationText.flatMap(Self.durationSeconds)
        let fallbackShowTitle = components.first { component in
            component != durationText
                && component != publishedDate
                && !Self.looksLikeCount(component)
        }

        let progress = Self.playbackProgress(from: renderer)
        return PodcastEpisode(
            id: videoId,
            title: title,
            showTitle: showTitle ?? fallbackShowTitle,
            showBrowseId: showBrowseId,
            description: Self.descriptionText(from: renderer),
            thumbnailURL: thumbnailURL,
            publishedDate: publishedDate,
            duration: durationText,
            durationSeconds: durationSeconds.map(Int.init),
            playbackProgress: progress,
            isPlayed: (renderer["isPlayed"] as? Bool) ?? (progress >= 1)
        )
    }
}

private extension SearchResponseParser {
    private static func responsiveEndpointCandidates(from renderer: [String: Any]) -> [[String: Any]] {
        var endpoints: [[String: Any]] = []
        Self.appendEndpoint(renderer["navigationEndpoint"], to: &endpoints)
        Self.appendEndpoint(Self.titleRun(from: renderer)?["navigationEndpoint"], to: &endpoints)
        Self.appendEndpoint(renderer["onTap"], to: &endpoints)
        Self.appendEndpoint(Self.playEndpoint(from: renderer["overlay"]), to: &endpoints)
        return endpoints
    }

    private static func directItemEndpointCandidates(from renderer: [String: Any]) -> [[String: Any]] {
        var endpoints: [[String: Any]] = []
        Self.appendEndpoint(renderer["navigationEndpoint"], to: &endpoints)
        Self.appendEndpoint(Self.titleRun(from: renderer)?["navigationEndpoint"], to: &endpoints)
        Self.appendEndpoint(renderer["onTap"], to: &endpoints)
        Self.appendEndpoint(Self.playEndpoint(from: renderer["thumbnailOverlay"]), to: &endpoints)
        Self.appendEndpoint(Self.playEndpoint(from: renderer["overlay"]), to: &endpoints)
        return endpoints
    }

    private static func multiRowEndpointCandidates(from renderer: [String: Any]) -> [[String: Any]] {
        var endpoints: [[String: Any]] = []
        Self.appendEndpoint(renderer["onTap"], to: &endpoints)
        Self.appendEndpoint(renderer["navigationEndpoint"], to: &endpoints)
        Self.appendEndpoint(Self.titleRun(from: renderer)?["navigationEndpoint"], to: &endpoints)
        Self.appendEndpoint(Self.playEndpoint(from: renderer["overlay"]), to: &endpoints)
        return endpoints
    }

    private static func cardEndpointCandidates(from card: [String: Any]) -> [[String: Any]] {
        var endpoints: [[String: Any]] = []
        Self.appendEndpoint(Self.titleRun(from: card)?["navigationEndpoint"], to: &endpoints)
        Self.appendEndpoint(card["navigationEndpoint"], to: &endpoints)
        Self.appendEndpoint(card["onTap"], to: &endpoints)
        Self.appendEndpoint(Self.playEndpoint(from: card["thumbnailOverlay"]), to: &endpoints)
        Self.appendEndpoint(Self.playEndpoint(from: card["overlay"]), to: &endpoints)
        return endpoints
    }

    private static func appendEndpoint(_ value: Any?, to endpoints: inout [[String: Any]]) {
        guard let endpoint = unwrapEndpoint(value) else {
            return
        }
        endpoints.append(endpoint)
    }

    private static func unwrapEndpoint(_ value: Any?) -> [String: Any]? {
        guard let endpoint = value as? [String: Any] else {
            return nil
        }
        return (endpoint["innertubeCommand"] as? [String: Any]) ?? endpoint
    }

    private static func playEndpoint(from overlayValue: Any?) -> [String: Any]? {
        guard let overlay = overlayValue as? [String: Any],
              let thumbnailOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
              let content = thumbnailOverlay["content"] as? [String: Any],
              let playButton = content["musicPlayButtonRenderer"] as? [String: Any]
        else {
            return nil
        }
        return Self.unwrapEndpoint(playButton["playNavigationEndpoint"])
    }

    private static func playableDestination(
        from renderer: [String: Any],
        endpointCandidates: [[String: Any]]
    ) -> PlayableDestination? {
        let musicVideoType = Self.firstMusicVideoType(
            from: renderer,
            endpointCandidates: endpointCandidates
        )

        if let playlistItemData = renderer["playlistItemData"] as? [String: Any],
           let videoId = playlistItemData["videoId"] as? String,
           !videoId.isEmpty
        {
            return PlayableDestination(videoId: videoId, musicVideoType: musicVideoType)
        }

        for endpoint in endpointCandidates {
            let wrapper = ["navigationEndpoint": endpoint]
            guard let videoId = ParsingHelpers.extractVideoId(from: wrapper),
                  !videoId.isEmpty
            else {
                continue
            }
            let endpointType = ParsingHelpers.extractMusicVideoType(from: wrapper) ?? musicVideoType
            return PlayableDestination(videoId: videoId, musicVideoType: endpointType)
        }

        return nil
    }

    private static func firstMusicVideoType(
        from renderer: [String: Any],
        endpointCandidates: [[String: Any]]
    ) -> MusicVideoType? {
        if let type = ParsingHelpers.extractMusicVideoType(from: renderer) {
            return type
        }

        for endpoint in endpointCandidates {
            if let type = ParsingHelpers.extractMusicVideoType(from: ["navigationEndpoint": endpoint]) {
                return type
            }
        }
        return nil
    }

    private static func contentKind(from renderer: [String: Any]) -> ContentKind? {
        for run in self.metadataRuns(from: renderer) {
            guard let text = run["text"] as? String else {
                continue
            }
            for component in Self.splitMetadataText(text) {
                if let kind = Self.contentKind(fromLabel: component) {
                    return kind
                }
            }
        }
        return nil
    }

    private static func contentKind(fromLabel label: String) -> ContentKind? {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "song", "أغنية", "titel", "canción", "morceau", "lagu", "brano", "노래",
             "nummer", "utwór", "música", "трек", "låt", "şarkı", "пісня":
            .song
        case "video", "فيديو", "vídeo", "vidéo", "동영상", "wideo", "видео", "відео":
            .video
        case "album", "single", "ep", "ألبوم", "álbum", "앨범", "альбом", "albüm":
            .album
        case "audiobook", "كتاب صوتي", "hörbuch", "audiolibro", "livre audio", "buku audio",
             "오디오북", "luisterboek", "аудиокнига", "ljudbok", "sesli kitap", "аудіокнига":
            .audiobook
        case "artist", "فنان", "interpret", "artista", "artiste", "artis", "아티스트",
             "artiest", "artysta", "исполнитель", "sanatçı", "виконавець":
            .artist
        case "profile", "الملف الشخصي", "profil", "perfil", "profilo", "프로필", "profiel",
             "профиль", "профіль":
            .profile
        case "playlist", "قائمة تشغيل", "lista de reproducción", "daftar putar", "재생목록",
             "afspeellijst", "playlista", "lista de reprodução", "плейлист", "spellista", "çalma listesi":
            .playlist
        case "podcast", "بودكاست", "팟캐스트", "подкаст", "podd":
            .podcastShow
        case "episode", "podcast episode", "حلقة", "folge", "episodio", "épisode", "에피소드",
             "aflevering", "odcinek", "episódio", "выпуск", "avsnitt", "bölüm", "епізод":
            .podcastEpisode
        default:
            nil
        }
    }

    private static func browseKind(
        browseId: String,
        pageType: String?,
        contentKind: ContentKind?
    ) -> BrowseKind? {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM":
            return .album
        case "MUSIC_PAGE_TYPE_AUDIOBOOK":
            return .audiobook
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
            return .artist
        case "MUSIC_PAGE_TYPE_USER_CHANNEL":
            return .profile
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist
        case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE":
            return .podcastShow
        default:
            break
        }

        if browseId.hasPrefix("MPSPP") {
            return .podcastShow
        }
        if browseId.hasPrefix("MPED") || contentKind == .podcastEpisode {
            return .podcastEpisode
        }
        if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            return contentKind == .audiobook ? .audiobook : .album
        }
        if browseId.hasPrefix("VL") || browseId.hasPrefix("PL")
            || browseId.hasPrefix("VM") || browseId.hasPrefix("RD")
        {
            return .playlist
        }
        if Artist.isNavigableId(browseId) {
            return contentKind == .profile ? .profile : .artist
        }
        return nil
    }

    private static func isVideoResult(_ musicVideoType: MusicVideoType?) -> Bool {
        switch musicVideoType {
        case .omv, .ugc, .officialSourceMusic:
            true
        case .atv, .podcastEpisode, nil:
            false
        }
    }

    private static func itemTitle(from renderer: [String: Any]) -> String? {
        ParsingHelpers.extractTitleFromFlexColumns(renderer)
            ?? ParsingHelpers.extractTitle(from: renderer)
    }

    private static func titleRun(from renderer: [String: Any]) -> [String: Any]? {
        if let flexColumns = renderer["flexColumns"] as? [[String: Any]],
           let firstColumn = flexColumns.first,
           let columnRenderer = firstColumn["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let text = columnRenderer["text"] as? [String: Any],
           let runs = text["runs"] as? [[String: Any]]
        {
            return runs.first
        }

        if let title = renderer["title"] as? [String: Any],
           let runs = title["runs"] as? [[String: Any]]
        {
            return runs.first
        }
        return nil
    }

    private static func metadataRuns(from renderer: [String: Any]) -> [[String: Any]] {
        if let flexColumns = renderer["flexColumns"] as? [[String: Any]] {
            var runs: [[String: Any]] = []
            for column in flexColumns.dropFirst() {
                guard let columnRenderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                      let text = columnRenderer["text"] as? [String: Any],
                      let columnRuns = text["runs"] as? [[String: Any]]
                else { continue }
                runs.append(contentsOf: columnRuns)
            }
            if !runs.isEmpty {
                return runs
            }
        }

        var runs: [[String: Any]] = []
        for key in ["subtitle", "secondSubtitle"] {
            guard let subtitle = renderer[key] as? [String: Any],
                  let subtitleRuns = subtitle["runs"] as? [[String: Any]]
            else {
                continue
            }
            runs.append(contentsOf: subtitleRuns)
        }
        return runs
    }

    private static func metadataComponents(from renderer: [String: Any]) -> [String] {
        var components: [String] = []
        for run in Self.metadataRuns(from: renderer) {
            guard let text = run["text"] as? String else {
                continue
            }
            for component in Self.splitMetadataText(text)
                where Self.contentKind(fromLabel: component) == nil
            {
                components.append(component)
            }
        }
        return components
    }

    private static func semanticSubtitle(from renderer: [String: Any]) -> String? {
        let components = Self.metadataComponents(from: renderer)
        return components.isEmpty ? nil : components.joined(separator: " • ")
    }

    private static func itemArtists(
        from renderer: [String: Any],
        allowPlainTextFallback: Bool
    ) -> [Artist] {
        if renderer["flexColumns"] != nil {
            let artists = ParsingHelpers.extractArtistsFromFlexColumns(renderer).filter { artist in
                artist.hasNavigableId || Self.contentKind(fromLabel: artist.name) == nil
            }
            if !artists.isEmpty {
                return artists
            }
        }

        let runs = Self.metadataRuns(from: renderer)
        var artists: [Artist] = []
        for run in runs {
            guard let name = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let endpoint = Self.unwrapEndpoint(run["navigationEndpoint"]),
                  let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  let artist = ParsingHelpers.extractArtist(from: browseEndpoint, name: name)
            else {
                continue
            }
            artists.append(artist)
        }
        if !artists.isEmpty || !allowPlainTextFallback {
            return artists
        }

        guard let fallbackName = Self.metadataComponents(from: renderer).first(where: { component in
            !Self.isNonArtistMetadata(component)
        }) else {
            return []
        }
        return [Artist.inline(name: fallbackName, namespace: "search-artist")]
    }

    private static func fallbackCreatorName(from renderer: [String: Any]) -> String? {
        self.metadataComponents(from: renderer).first { component in
            !Self.isNonArtistMetadata(component)
        }
    }

    private static func isNonArtistMetadata(_ text: String) -> Bool {
        if self.contentKind(fromLabel: text) != nil {
            return true
        }
        if ParsingHelpers.parseDuration(text) != nil || self.hasLocalizedCountUnit(text) {
            return true
        }

        let patterns = [
            #"^\s*\d+(?:[.,]\d+)?\s*(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\s*$"#,
            #"^\s*\d+\s*(?:seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?|years?|[smhdwy])\s+ago\s*$"#,
            #"^\s*(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+\d{1,2}(?:,\s*\d{4})?\s*$"#,
            #"^\s*(?:\d{4}|\d{4}-\d{1,2}-\d{1,2})\s*$"#,
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func songCount(from renderer: [String: Any]) -> Int? {
        if renderer["flexColumns"] != nil {
            return ParsingHelpers.extractSongCountFromFlexColumns(renderer)
        }
        return ParsingHelpers.extractSongCountFromSubtitle(from: renderer)
    }
}
