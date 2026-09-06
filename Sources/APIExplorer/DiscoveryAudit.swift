import CoreFoundation
import Foundation

func discoveryHelp() -> String {
    var lines = [
        "Usage: discover <endpoint> <body-json> [--guest] [--follow N] [-v] [-o report.txt]",
        "Use --body-file <mode-0600-path|-> for private IDs or opaque request parameters.",
        "Supported read-only endpoints and fields:",
    ]
    for endpoint in DiscoveryRequest.allowedFields.keys.sorted() {
        lines.append("  " + endpoint + ": " + (DiscoveryRequest.allowedFields[endpoint] ?? []).sorted().joined(separator: ", "))
    }
    lines += [
        "Navigation indices are local to each response. Repeat --follow for up to five hops.",
        "Responses can reorder between runs. Inspect the selected route at each step.",
        "Authentication is reused for every hop when Kaset cookies exist; --guest suppresses it.",
        "-v adds field/type paths, never raw values. -o saves only the redacted report.",
        "--ios-music or --android-music uses that mobile profile on every hop, with no web API key.",
        "--mobile-web-key adds the resolved web API key to mobile discovery for auth comparison.",
        "--mobile-cookie-only omits SAPISIDHASH on mobile discovery while retaining saved cookies.",
        "--mobile-token-file <mode-0600-path> uses a mobile OAuth access token instead of web cookies.",
        "Token files must be owned by you, have mode 0600 and no extended ACL, and not be symlinks.",
        "The report destination must not refer to the cookie archive, token file, or request-body file, including redirected stdin.",
        "Do not put tokens in command arguments, reports, or chat. Token acquisition is separate.",
        "Web-cookie mobile probes were rejected; cookie-only probes returned a guest session.",
        "A content envelope or HTTP 200 alone does not prove a feature works or auth succeeded.",
        "Only FEmusic_charts accepts formData, with one two-letter country in selectedValues.",
        "Library chips and sort menus expose only their browse reads; bundled state changes stay hidden.",
        "Taste-profile acceptance buttons are inspected without exposing a replayable action.",
        "Examples:",
        "  swift run api-explorer discover browse '{\"browseId\":\"FEmusic_charts\"}' --guest",
        "  swift run api-explorer discover next '{\"videoId\":\"dQw4w9WgXcQ\"}' --guest",
        "  swift run api-explorer discover browse '{\"browseId\":\"FEmusic_home\"}' --guest --follow 0",
        "  swift run api-explorer discover browse '{\"browseId\":\"FEmusic_home\"}' --ios-music --guest -v",
    ]
    return lines.joined(separator: "\n")
}

// MARK: - DiscoveryRequest

/// A small read-only subset of InnerTube. In particular, browse + formData can
/// update a taste profile, so checking the endpoint alone is not sufficient.
/// Charts country selection is the only supported form, constrained separately.
struct DiscoveryRequest {
    let endpoint: String
    let body: [String: Any]

    static let allowedFields: [String: Set<String>] = [
        "browse": ["browseId", "params", "continuation"],
        "search": ["query", "params", "continuation"],
        "next": [
            "videoId", "playlistId", "params", "continuation", "index", "playlistSetVideoId",
            "isAudioOnly", "enablePersistentPlaylistPanel", "tunerSettingValue",
        ],
        "player": ["videoId"],
        "music/get_queue": ["videoIds", "playlistId"],
        "music/get_search_suggestions": ["input"],
        "get_transcript": ["params"],
    ]

    init(endpoint: String, body: [String: Any]) throws {
        guard var allowed = Self.allowedFields[endpoint] else { throw DiscoveryError.unsupportedRequest }
        if endpoint == "browse", body["browseId"] as? String == "FEmusic_charts" {
            allowed.insert("formData")
        }
        guard Set(body.keys).isSubset(of: allowed), !body.isEmpty,
              JSONSerialization.isValidJSONObject(body)
        else { throw DiscoveryError.unsupportedRequest }

        for (key, value) in body {
            switch key {
            case "formData":
                guard let form = value as? [String: Any], Set(form.keys) == ["selectedValues"],
                      let countries = form["selectedValues"] as? [String], countries.count == 1,
                      countries.allSatisfy(Self.isCountryCode)
                else { throw DiscoveryError.unsupportedRequest }
            case "videoIds":
                guard let ids = value as? [String], !ids.isEmpty, ids.count <= 50,
                      ids.allSatisfy({ !$0.isEmpty && $0.count <= 128 })
                else { throw DiscoveryError.unsupportedRequest }
            case "index":
                guard let scalar = value as? NSNumber, CFGetTypeID(scalar) != CFBooleanGetTypeID(),
                      let number = value as? Int, (0 ... 100_000).contains(number)
                else {
                    throw DiscoveryError.unsupportedRequest
                }
            case "isAudioOnly", "enablePersistentPlaylistPanel":
                guard let scalar = value as? NSNumber, CFGetTypeID(scalar) == CFBooleanGetTypeID() else {
                    throw DiscoveryError.unsupportedRequest
                }
            default:
                guard let text = value as? String, !text.isEmpty, text.utf8.count <= 32768 else {
                    throw DiscoveryError.unsupportedRequest
                }
            }
        }
        let required: [String: Set<String>] = [
            "browse": ["browseId", "continuation"],
            "search": ["query", "continuation"],
            "next": ["videoId", "playlistId", "continuation"],
            "player": ["videoId"],
            "music/get_queue": ["videoIds", "playlistId"],
            "music/get_search_suggestions": ["input"],
            "get_transcript": ["params"],
        ]
        guard let requiredKeys = required[endpoint], !requiredKeys.isDisjoint(with: body.keys) else {
            throw DiscoveryError.unsupportedRequest
        }
        self.endpoint = endpoint
        self.body = body
    }

    static func isCountryCode(_ value: String) -> Bool {
        value.utf8.count == 2 && value.unicodeScalars.allSatisfy { (65 ... 90).contains($0.value) }
    }

    var identity: Data {
        (try? JSONSerialization.data(
            withJSONObject: ["endpoint": self.endpoint, "body": self.body], options: [.sortedKeys]
        )) ?? Data()
    }

    var summary: String {
        let destination = (self.body["browseId"] as? String).map { " " + DiscoveryAudit.browseFamily($0) } ?? ""
        let country = ((self.body["formData"] as? [String: Any])?["selectedValues"] as? [String])?.first
        let selection = country.map { " country=" + $0 } ?? ""
        return self.endpoint + destination + selection + " fields=[" + self.body.keys.sorted().joined(separator: ", ") + "]"
    }
}

// MARK: - DiscoveryError

enum DiscoveryError: Error, Equatable {
    case unsupportedRequest
    case invalidMobileToken
}

// MARK: - DiscoveryNavigation

struct DiscoveryNavigation {
    let request: DiscoveryRequest
    let source: String
    let label: String?

    var summary: String {
        self.request.summary + " via " + self.source + (self.label.map { " label=" + $0 } ?? "")
    }

    var priority: Int {
        if self.request.endpoint == "get_transcript" {
            return 0
        }
        if self.request.body["formData"] != nil {
            return 3
        }
        if let browseID = self.request.body["browseId"] as? String {
            if browseID.hasPrefix("MPTC") {
                return 0
            }
            if browseID.hasPrefix("MPTR") {
                return 1
            }
            if browseID.hasPrefix("MPLY") {
                return 2
            }
        }
        if self.source.contains("chip") || self.source.contains("Chip") {
            return 3
        }
        if self.source == "musicMultiSelectMenuItemRenderer" || self.source.contains("dropdown") || self.source.contains("Dropdown") {
            return 4
        }
        if self.request.body["continuation"] != nil {
            return 5
        }
        return self.request.endpoint == "browse" ? 6 : 7
    }
}

// MARK: - DiscoveryAudit

/// Stores replayable values only in memory. Reports contain schema names, counts,
/// fixed UI labels, and browse-ID families, never response text or opaque values.
struct DiscoveryAudit {
    private(set) var navigation: [DiscoveryNavigation] = []
    private(set) var renderers: [String: Int] = [:]
    private(set) var rendererFields: [String: Set<String>] = [:]
    private(set) var schema: Set<String> = []
    private(set) var labels: [String: Int] = [:]
    private(set) var pageTypes: [String: Int] = [:]
    private(set) var observedCommands: [String: Int] = [:]
    private(set) var counterpartCount = 0
    private(set) var creditSectionCount = 0
    private(set) var populatedCreditSectionCount = 0
    private(set) var chartCountryCount = 0
    private(set) var selectedChartCountries: [String] = []
    private(set) var selectedChips: Set<String> = []
    private(set) var sortMenuTitles: Set<String> = []
    private(set) var speedDialItemCount = 0
    private(set) var speedDialShortcutCount = 0
    private(set) var homeShelves: [String] = []
    private(set) var truncated = false
    private(set) var schemaTruncated = false
    let serverLoggedOut: Bool?
    let hasAPIError: Bool
    let apiErrorSummary: String?
    let hasContent: Bool
    private var identities: Set<Data> = []
    private var visitedNodes = 0

    /// Response dictionaries can be keyed by private IDs, even all-letter ones.
    /// Extend this list only with verified, static schema names.
    private static let safeSchemaKeys: Set<String> = [
        "responseContext", "mainAppWebResponseContext", "loggedOut", "serviceTrackingParams", "service", "params",
        "key", "value", "visitorData", "trackingParams", "clickTrackingParams", "error", "code", "status", "message",
        "contents", "content", "continuationContents", "continuationItems", "onResponseReceivedActions", "onResponseReceivedEndpoints", "onResponseReceivedCommands",
        "actions", "videoDetails", "queueDatas", "tabs", "header", "footer", "items", "options", "menu", "data",
        "title", "subtitle", "secondSubtitle", "text", "label", "simpleText", "runs", "secondaryText",
        "browseId", "videoId", "videoIds", "playlistId", "playlistSetVideoId", "query", "input", "index",
        "isAudioOnly", "enablePersistentPlaylistPanel", "tunerSettingValue", "continuation", "continuations", "token",
        "nextContinuationData", "nextRadioContinuationData", "reloadContinuationData", "isSelected", "selected",
        "formData", "selectedValues", "opaqueToken", "selectionFormValue", "formItemEntityKey", "newCheckedState",
        "frameworkUpdates", "entityBatchUpdate", "mutations", "payload", "musicFormBooleanChoice",
        "pageType", "musicVideoType", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig",
        "thumbnail", "thumbnails", "image", "sources", "url", "width", "height", "icon", "iconType", "badges",
        "flexColumns", "fixedColumns", "playlistItemData", "overlay", "shelfId", "counterpart", "isShortcut",
        "newElement", "type", "componentType", "model", "onTap", "onLongPress", "commands", "command", "acceptButton",
        "feedbackToken", "feedbackTokens", "dismissalToken", "accessToken", "accountId",
        "browseEndpoint", "browseSectionListReloadEndpoint", "searchEndpoint", "watchEndpoint", "watchPlaylistEndpoint",
        "navigationEndpoint", "navigationCommand", "playNavigationEndpoint", "startPlaybackCommand", "innertubeCommand",
        "serviceEndpoint", "defaultServiceEndpoint", "toggledServiceEndpoint", "submitEndpoint", "feedbackEndpoint",
        "getTranscriptEndpoint", "continuationEndpoint", "continuationCommand", "commandExecutorCommand", "serialCommand",
        "selectedCommand", "onDeselectedCommand", "musicLibraryPersistLaunchNavigationCommand", "musicCheckboxFormItemMutatedCommand",
        "musicBrowseFormBinderCommand", "reloadContinuationItemsCommand", "appendContinuationItemsAction",
        "singleColumnBrowseResultsRenderer", "twoColumnBrowseResultsRenderer", "singleColumnMusicWatchNextResultsRenderer",
        "tabbedSearchResultsRenderer", "twoColumnSearchResultsRenderer", "tabRenderer", "tabbedRenderer",
        "watchNextTabbedResultsRenderer", "sectionListRenderer", "itemSectionRenderer", "gridRenderer", "gridHeaderRenderer",
        "musicShelfRenderer", "musicPlaylistShelfRenderer", "musicCardShelfRenderer", "musicCardShelfHeaderBasicRenderer",
        "musicCarouselShelfRenderer", "musicCarouselShelfBasicHeaderRenderer", "musicImmersiveCarouselShelfRenderer",
        "musicDescriptionShelfRenderer", "musicTwoRowItemRenderer", "musicResponsiveListItemRenderer", "musicMultiRowListItemRenderer",
        "musicResponsiveListItemFlexColumnRenderer", "musicResponsiveListItemFixedColumnRenderer", "musicResponsiveHeaderRenderer",
        "musicDetailHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer", "musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer",
        "musicQueueRenderer", "playlistPanelRenderer", "playlistPanelVideoRenderer", "playlistPanelVideoWrapperRenderer",
        "chipCloudRenderer", "chipCloudChipRenderer", "feedFilterChipBarRenderer", "musicSortFilterButtonRenderer",
        "musicMultiSelectMenuRenderer", "musicMultiSelectMenuItemRenderer", "musicNavigationButtonRenderer",
        "menuRenderer", "menuNavigationItemRenderer", "menuServiceItemRenderer", "toggleMenuServiceItemRenderer",
        "musicMenuTitleRenderer", "buttonRenderer", "toggleButtonRenderer", "musicPlayButtonRenderer", "likeButtonRenderer",
        "musicThumbnailRenderer", "musicItemThumbnailOverlayRenderer", "musicInlineBadgeRenderer", "metadataBadgeRenderer",
        "continuationItemRenderer", "counterpartRenderer", "dismissableDialogContentSectionRenderer",
        "tastebuilderRenderer", "tastebuilderItemRenderer", "messageRenderer", "notificationTextRenderer",
        "elementRenderer", "musicSpeedDialShelfModel", "musicGridItemCarouselModel", "musicListItemCarouselModel",
        "musicQuickPicksModel", "timedLyricsModel", "searchSuggestionsSectionRenderer", "searchSuggestionRenderer",
        "historySuggestionRenderer", "transcriptRenderer", "transcriptSearchPanelRenderer", "transcriptSegmentListRenderer",
        "transcriptSegmentRenderer", "transcriptSectionHeaderRenderer", "engagementPanelSectionListRenderer",
    ]

    private static let publicBrowseIDs: Set<String> = [
        "FEmusic_home", "FEmusic_explore", "FEmusic_charts", "FEmusic_moods_and_genres", "FEmusic_moods_and_genres_category",
        "FEmusic_new_releases", "FEmusic_podcasts", "FEmusic_radio_builder",
        "FEmusic_liked_playlists", "FEmusic_liked_albums", "FEmusic_liked_videos", "FEmusic_history",
        "FEmusic_library_landing", "FEmusic_library_artists", "FEmusic_library_corpus_artists", "FEmusic_library_corpus_track_artists",
        "FEmusic_library_songs", "FEmusic_library_non_music_audio_list", "FEmusic_library_non_music_audio_channels_list",
        "FEmusic_library_user_profile_channels_list", "FEmusic_tastebuilder", "FEmusic_listening_review",
        "FEmusic_recently_played", "FEmusic_offline", "FEmusic_library_privately_owned_landing", "FEmusic_library_privately_owned_tracks",
        "FEmusic_library_privately_owned_albums", "FEmusic_library_privately_owned_releases", "FEmusic_library_privately_owned_artists",
        "FEsubscriptions", "FElibrary", "FEhistory", "FEplaylist_aggregation",
        "FEwhat_to_watch", "FEgaming_destination", "FEnews_destination", "FEsports_destination",
        "FElive_destination", "FEfashion_destination", "FElearning_destination",
    ]

    private static let safePageTypes: Set<String> = [
        "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK", "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST",
        "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_PLAYLIST",
        "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE", "MUSIC_PAGE_TYPE_TRACK_CREDITS", "MUSIC_PAGE_TYPE_TRACK_RELATED",
        "MUSIC_VIDEO_TYPE_ATV", "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC", "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC",
        "MUSIC_VIDEO_TYPE_PODCAST_EPISODE",
    ]

    private static let uiLabelRenderers: Set<String> = [
        "chipCloudChipRenderer", "tabRenderer", "menuNavigationItemRenderer", "menuServiceItemRenderer",
        "toggleMenuServiceItemRenderer", "musicMultiSelectMenuItemRenderer", "musicSortFilterButtonRenderer",
        "musicCarouselShelfBasicHeaderRenderer", "musicCardShelfHeaderBasicRenderer", "dismissableDialogContentSectionRenderer",
    ]

    private static let safeLabels: Set<String> = [
        "All", "Albums", "Artists", "Songs", "Videos", "Playlists", "Podcasts", "Episodes", "Profiles", "Channels",
        "Featured playlists", "Community playlists", "Uploads", "Your library", "Downloads",
        "Recently added", "Recently saved", "Recently played", "A to Z", "Z to A", "Popular", "Newest first",
        "Speed dial", "Speed Dial", "Listen again", "Quick picks",
        "Workout", "Focus", "Relax", "Commute", "Energize", "Sleep", "Party", "Romance", "Feel good", "Sad",
        "Discover", "Familiar", "New releases", "Deep cuts", "Upbeat", "Downbeat", "Chill",
        "Song credits", "View song credits", "Performed by", "Written by", "Produced by", "Music metadata provided by",
        "Lyrics", "Related", "Up next", "Start radio", "Create a radio", "Tune your music",
        "You might also like", "Recommended playlists", "Similar artists", "About the artist", "Other versions",
        "More from the artist", "From the album", "Featured on", "Music videos", "Recommended music videos",
        "Not interested", "Don't recommend channel", "Remove from history", "Pin to Listen again", "Unpin from Listen again",
        "Artist variety", "Song selection", "Low", "Medium", "High", "Blend", "Familiarity", "Popularity",
        "United States", "United Kingdom", "Turkey", "Türkiye", "Japan", "Global", "Top songs", "Top music videos",
    ]

    init(response: [String: Any], request: DiscoveryRequest) {
        let context = response["responseContext"] as? [String: Any]
        let webContext = context?["mainAppWebResponseContext"] as? [String: Any]
        let services = context?["serviceTrackingParams"] as? [[String: Any]] ?? []
        let loginFlags = services.flatMap { $0["params"] as? [[String: Any]] ?? [] }
            .filter { ["logged_in", "yt_li"].contains($0["key"] as? String ?? "") }
            .map { $0["value"] as? String ?? "" }
        let inferredLoggedOut: Bool? = switch Set(loginFlags) {
        case ["0"]: true
        case ["1"]: false
        default: nil
        }
        self.serverLoggedOut = (webContext?["loggedOut"] as? Bool) ?? inferredLoggedOut
        self.hasAPIError = response["error"] != nil
        self.apiErrorSummary = Self.describeAPIError(response["error"] as? [String: Any])
        self.hasContent = ["contents", "continuationContents", "onResponseReceivedActions", "onResponseReceivedEndpoints", "onResponseReceivedCommands", "actions", "videoDetails", "queueDatas"]
            .contains { key in
                if let object = response[key] as? [String: Any] {
                    return !object.isEmpty
                }
                if let array = response[key] as? [Any] {
                    return !array.isEmpty
                }
                return false
            }
        self.collectChartCountries(response, request: request)
        self.walk(response, path: "$", source: "root", label: nil, request: request, depth: 0)
        self.navigation = self.navigation.enumerated().sorted {
            $0.element.priority == $1.element.priority
                ? $0.offset < $1.offset
                : $0.element.priority < $1.element.priority
        }.map(\.element)
    }

    static func schemaKey(_ key: String) -> String {
        self.safeSchemaKeys.contains(key) ? key : "<key>"
    }

    /// Only fixed error categories may leave the response. Server messages can
    /// echo credentials or account data, including on failed requests.
    private static func describeAPIError(_ error: [String: Any]?) -> String? {
        guard let error else { return nil }
        let statuses: Set = [
            "INVALID_ARGUMENT", "UNAUTHENTICATED", "PERMISSION_DENIED", "NOT_FOUND",
            "FAILED_PRECONDITION", "RESOURCE_EXHAUSTED", "INTERNAL", "UNAVAILABLE",
        ]
        let status = error["status"] as? String ?? ""
        let messages: [String: String] = [
            "Request contains an invalid argument.": "invalid argument",
            "API key not valid. Please pass a valid API key.": "invalid API key",
            "Request had invalid authentication credentials.": "invalid authentication",
            "Login Required": "login required",
        ]
        let category = (error["message"] as? String).flatMap { messages[$0] } ?? "message hidden"
        return (statuses.contains(status) ? status : "unrecognized status") + "; " + category
    }

    static func browseFamily(_ value: String) -> String {
        if self.publicBrowseIDs.contains(value) {
            return value
        }
        for family in ["FEmusic_", "MPLA", "MPTC", "MPTR", "MPLY", "MPRE", "MPSP", "VL", "UC"] where value.hasPrefix(family) {
            return family + "…"
        }
        return "<browse-id>"
    }

    private static func knownLabel(in dictionary: [String: Any]) -> String? {
        for key in ["title", "text", "label"] {
            if let value = dictionary[key] as? String, safeLabels.contains(value) {
                return value
            }
            if let text = dictionary[key] as? [String: Any] {
                let value: String? = (text["simpleText"] as? String)
                    ?? (text["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
                if let value, Self.safeLabels.contains(value) {
                    return value
                }
            }
        }
        return nil
    }

    private mutating func append(
        endpoint: String, body: [String: Any], source: String, label: String?
    ) {
        guard let request = try? DiscoveryRequest(endpoint: endpoint, body: body) else { return }
        guard self.navigation.count < 2000 else {
            self.truncated = true
            return
        }
        if self.identities.insert(request.identity).inserted {
            self.navigation.append(DiscoveryNavigation(request: request, source: source, label: label))
        }
    }

    private mutating func collectNavigation(
        _ dictionary: [String: Any], source: String, label: String?, request: DiscoveryRequest
    ) {
        self.collectTranscript(dictionary)
        self.collectBrowseSelection(dictionary, source: source, label: label, request: request)
        // Never execute service endpoints, form submissions, or command batches.
        // Only these navigation payloads are projected onto known read-only fields.
        for key in ["browseEndpoint", "browseSectionListReloadEndpoint", "searchEndpoint", "watchEndpoint", "watchPlaylistEndpoint"] {
            guard let payload = dictionary[key] as? [String: Any], payload["formData"] == nil else { continue }
            let endpoint = key == "searchEndpoint" ? "search" : (key.hasPrefix("watch") ? "next" : "browse")
            let fields = DiscoveryRequest.allowedFields[endpoint] ?? []
            var body = payload.filter { fields.contains($0.key) }
            if endpoint == "next", request.endpoint == "next" {
                for contextKey in ["isAudioOnly", "enablePersistentPlaylistPanel", "tunerSettingValue"] where body[contextKey] == nil {
                    body[contextKey] = request.body[contextKey]
                }
            }
            self.append(endpoint: endpoint, body: body, source: source, label: label)
        }
        for key in ["nextContinuationData", "nextRadioContinuationData", "reloadContinuationData", "continuationCommand"] {
            guard let payload = dictionary[key] as? [String: Any],
                  let continuation = (payload["continuation"] ?? payload["token"]) as? String
            else { continue }
            // Retain the seed's context, especially video/playlist IDs for next.
            var body = request.body
            body["continuation"] = continuation
            self.append(endpoint: request.endpoint, body: body, source: key, label: label)
        }
    }

    /// Signed-in Library selections bundle a browse read with persistence or
    /// checkbox commands. Extract only the direct read from these UI wrappers.
    private mutating func collectBrowseSelection(
        _ dictionary: [String: Any], source: String, label: String?, request: DiscoveryRequest
    ) {
        guard request.endpoint == "browse" else { return }
        let selection: [String: Any]?
        switch source {
        case "chipCloudChipRenderer":
            selection = dictionary["navigationEndpoint"] as? [String: Any]
        case "musicMultiSelectMenuItemRenderer":
            selection = dictionary["selectedCommand"] as? [String: Any]
        default:
            return
        }
        guard let batch = selection?["commandExecutorCommand"] as? [String: Any],
              let commands = batch["commands"] as? [[String: Any]]
        else { return }
        for command in commands.prefix(2000) {
            if let browse = command["browseEndpoint"] as? [String: Any], browse["formData"] == nil {
                let fields = DiscoveryRequest.allowedFields["browse"] ?? []
                self.append(endpoint: "browse", body: browse.filter { fields.contains($0.key) }, source: source, label: label)
            }
            if let reload = command["browseSectionListReloadEndpoint"] as? [String: Any], reload["formData"] == nil,
               let continuation = reload["continuation"] as? [String: Any],
               let data = continuation["reloadContinuationData"] as? [String: Any],
               let value = data["continuation"] as? String
            {
                var body = request.body
                body["continuation"] = value
                self.append(endpoint: "browse", body: body, source: source, label: label)
            }
        }
        if commands.count > 2000 {
            self.truncated = true
        }
    }

    private mutating func collectTranscript(_ dictionary: [String: Any]) {
        guard let payload = dictionary["getTranscriptEndpoint"] as? [String: Any],
              let params = payload["params"] as? String
        else { return }
        // Extract only the read-only request from any surrounding UI command
        // batch. No other command in that batch is executed.
        self.append(endpoint: "get_transcript", body: ["params": params], source: "getTranscriptEndpoint", label: nil)
    }

    private mutating func collectChartCountries(_ response: [String: Any], request: DiscoveryRequest) {
        guard request.endpoint == "browse", request.body["browseId"] as? String == "FEmusic_charts",
              let updates = response["frameworkUpdates"] as? [String: Any],
              let batch = updates["entityBatchUpdate"] as? [String: Any],
              let mutations = batch["mutations"] as? [[String: Any]]
        else { return }
        var countries: Set<String> = []
        for mutation in mutations {
            guard let payload = mutation["payload"] as? [String: Any],
                  let choice = payload["musicFormBooleanChoice"] as? [String: Any],
                  let country = choice["opaqueToken"] as? String,
                  DiscoveryRequest.isCountryCode(country)
            else { continue }
            if choice["selected"] as? Bool == true, !self.selectedChartCountries.contains(country) {
                self.selectedChartCountries.append(country)
            }
            guard countries.insert(country).inserted else { continue }
            self.append(
                endpoint: "browse",
                body: ["browseId": "FEmusic_charts", "formData": ["selectedValues": [country]]],
                source: "musicFormBooleanChoice", label: "Charts country " + country
            )
        }
        self.chartCountryCount = countries.count
    }

    private mutating func walk(
        _ value: Any, path: String, source: String, label: String?, request: DiscoveryRequest, depth: Int
    ) {
        guard depth <= 70, self.visitedNodes < 100_000 else {
            self.truncated = true
            return
        }
        self.visitedNodes += 1
        if let dictionary = value as? [String: Any] {
            self.collectNavigation(dictionary, source: source, label: label, request: request)
            for key in dictionary.keys.sorted() {
                guard let nested = dictionary[key] else { continue }
                let safeKey = Self.schemaKey(key)
                let nestedPath = path + "." + safeKey
                if self.schema.count < 1500 {
                    self.schema.insert(nestedPath + ": " + Self.valueKind(nested))
                } else {
                    self.schemaTruncated = true
                }
                var nestedSource = source
                var nestedLabel = label
                if key.hasSuffix("Renderer") || key.hasSuffix("ViewModel") || (key.hasPrefix("music") && key.hasSuffix("Model")) {
                    self.renderers[safeKey, default: 0] += 1
                    // Labels belong to UI metadata on this renderer only. A new
                    // content renderer must not inherit its parent's heading.
                    nestedLabel = nil
                    if let renderer = nested as? [String: Any] {
                        self.rendererFields[safeKey, default: []].formUnion(renderer.keys.map(Self.schemaKey))
                        if Self.uiLabelRenderers.contains(key), let ownLabel = Self.knownLabel(in: renderer) {
                            nestedLabel = ownLabel
                            self.labels[ownLabel, default: 0] += 1
                        }
                    }
                    nestedSource = safeKey
                }
                if key.hasSuffix("Endpoint") || key.hasSuffix("Command") {
                    self.observedCommands[safeKey, default: 0] += 1
                }
                if key == "counterpart" || key == "counterpartRenderer" {
                    self.counterpartCount += 1
                }
                if key == "musicSpeedDialShelfModel",
                   let model = nested as? [String: Any],
                   let data = model["data"] as? [String: Any],
                   let items = data["items"] as? [[String: Any]]
                {
                    self.speedDialItemCount += items.count
                    self.speedDialShortcutCount += items.count(where: { $0["isShortcut"] as? Bool == true })
                }
                if key == "musicCarouselShelfRenderer", let shelf = nested as? [String: Any] {
                    let header = shelf["header"] as? [String: Any]
                    let basicHeader = header?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any] ?? [:]
                    let title = Self.knownLabel(in: basicHeader) ?? "<label>"
                    let count = (shelf["contents"] as? [Any])?.count ?? 0
                    self.homeShelves.append("label=\(title); items=\(count)")
                }
                if key == "dismissableDialogContentSectionRenderer" {
                    self.creditSectionCount += 1
                    if let section = nested as? [String: Any],
                       let subtitle = section["subtitle"] as? [String: Any],
                       let runs = subtitle["runs"] as? [[String: Any]],
                       runs.contains(where: { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
                    {
                        self.populatedCreditSectionCount += 1
                    }
                }
                if key == "chipCloudChipRenderer", let chip = nested as? [String: Any],
                   chip["isSelected"] as? Bool == true
                {
                    self.selectedChips.insert(Self.knownLabel(in: chip) ?? "<label>")
                }
                if key == "musicSortFilterButtonRenderer", let button = nested as? [String: Any] {
                    self.sortMenuTitles.insert(Self.knownLabel(in: button) ?? "<label>")
                }
                if ["pageType", "musicVideoType"].contains(key), let type = nested as? String,
                   Self.safePageTypes.contains(type)
                {
                    self.pageTypes[type, default: 0] += 1
                }
                // Browse selections are extracted at their owning UI renderer.
                // Other batch and service commands stay schema-only, except
                // explicit transcript reads.
                if ["serviceEndpoint", "defaultServiceEndpoint", "toggledServiceEndpoint", "commandExecutorCommand", "formData", "submitEndpoint", "acceptButton", "onDeselectedCommand"].contains(key) {
                    self.walkSchemaOnly(nested, path: nestedPath, depth: depth + 1)
                } else {
                    self.walk(nested, path: nestedPath, source: nestedSource, label: nestedLabel, request: request, depth: depth + 1)
                }
            }
        } else if let array = value as? [Any] {
            for nested in array.prefix(2000) {
                self.walk(nested, path: path + "[]", source: source, label: label, request: request, depth: depth + 1)
            }
            if array.count > 2000 {
                self.truncated = true
            }
        }
    }

    private mutating func walkSchemaOnly(_ value: Any, path: String, depth: Int) {
        guard depth <= 70, self.visitedNodes < 100_000 else {
            self.truncated = true
            return
        }
        self.visitedNodes += 1
        if let dictionary = value as? [String: Any] {
            self.collectTranscript(dictionary)
            for key in dictionary.keys.sorted() {
                guard let nested = dictionary[key] else { continue }
                let safeKey = Self.schemaKey(key)
                let nestedPath = path + "." + safeKey
                if self.schema.count < 1500 {
                    self.schema.insert(nestedPath + ": " + Self.valueKind(nested))
                } else {
                    self.schemaTruncated = true
                }
                if key.hasSuffix("Endpoint") || key.hasSuffix("Command") {
                    self.observedCommands[safeKey, default: 0] += 1
                }
                self.walkSchemaOnly(nested, path: nestedPath, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for nested in array.prefix(2000) {
                self.walkSchemaOnly(nested, path: path + "[]", depth: depth + 1)
            }
            if array.count > 2000 {
                self.truncated = true
            }
        }
    }

    private static func valueKind(_ value: Any) -> String {
        if value is [String: Any] {
            return "object"
        }
        if value is [Any] {
            return "array"
        }
        if value is String {
            return "string"
        }
        if value is NSNull {
            return "null"
        }
        return "scalar"
    }

    func rendered(limit: Int = 40, verbose: Bool = false) -> String {
        var lines = [
            "Server session: " + (self.serverLoggedOut.map { $0 ? "guest" : "signed-in" } ?? "unconfirmed"),
            "Response: " + (self.hasAPIError ? "API error" : (self.hasContent ? "content envelope present, inspect counts below" : "no content envelope")),
        ]
        if let apiErrorSummary = self.apiErrorSummary {
            lines.append("API error category: " + apiErrorSummary)
        }
        lines.append("Renderers and models:")
        for key in self.renderers.keys.sorted() {
            let fields = verbose ? " fields=[" + (self.rendererFields[key] ?? []).sorted().joined(separator: ", ") + "]" : ""
            lines.append("  \(key): \(self.renderers[key, default: 0])\(fields)")
        }
        for (title, values) in [("Recognized UI labels", self.labels), ("Content types", self.pageTypes), ("Observed command kinds", self.observedCommands)] where !values.isEmpty {
            lines.append(title + ":")
            for key in values.keys.sorted() {
                lines.append("  \(key): \(values[key, default: 0])")
            }
        }
        lines.append("Counterpart fields: \(self.counterpartCount); credit sections: \(self.creditSectionCount)")
        lines.append("Speed dial models: \(self.renderers["musicSpeedDialShelfModel", default: 0]); items: \(self.speedDialItemCount); shortcuts: \(self.speedDialShortcutCount)")
        if !self.homeShelves.isEmpty {
            lines.append("Web carousel shelves:")
            lines.append(contentsOf: self.homeShelves.map { "  " + $0 })
        }
        if self.creditSectionCount > 0 {
            lines.append("Credit sections containing text: \(self.populatedCreditSectionCount)")
        }
        if self.chartCountryCount > 0 {
            lines.append("Chart country choices: \(self.chartCountryCount)")
        }
        if !self.selectedChartCountries.isEmpty {
            lines.append("Selected chart countries: " + self.selectedChartCountries.joined(separator: ", "))
        }
        if !self.selectedChips.isEmpty {
            lines.append("Selected chips: " + self.selectedChips.sorted().joined(separator: ", "))
        }
        if !self.sortMenuTitles.isEmpty {
            lines.append("Sort menu titles: " + self.sortMenuTitles.sorted().joined(separator: ", "))
        }
        lines.append("Read-only navigation (\(self.navigation.count)):")
        for (index, entry) in self.navigation.prefix(limit).enumerated() {
            lines.append("  [\(index)] \(entry.summary)")
        }
        if self.navigation.count > limit {
            lines.append("  Use --limit \(min(self.navigation.count, 500)) to show more entries.")
        }
        if self.truncated {
            lines.append("Audit limits reached; counts and navigation may be incomplete.")
        }
        if verbose {
            lines.append("Schema (all scalar values hidden):")
            lines.append(contentsOf: self.schema.sorted().map { "  " + $0 })
            if self.schemaTruncated {
                lines.append("Schema output capped at 1500 paths; navigation traversal continues independently.")
            }
        }
        return lines.joined(separator: "\n")
    }
}

func discoveryOutputOverwritesInput(
    _ outputFile: String, bodyFile: String?, mobileTokenFile: String?, cookieBackupFile: URL?,
    standardInput: Int32 = STDIN_FILENO
) -> Bool {
    let inputFiles = [mobileTokenFile, bodyFile == "-" ? nil : bodyFile, cookieBackupFile?.path].compactMap(\.self)
    return inputFiles.contains { pathsReferToSameFile($0, outputFile) }
        || (bodyFile == "-" && fileDescriptorRefersToFile(standardInput, path: outputFile))
}

func discoverAPI(
    endpoint: String, bodyJSON: String, followIndices: [Int], limit: Int,
    verbose: Bool, outputFile: String?, mobileClient: MusicMobileRequestProfile.Client? = nil,
    mobileWebKey: Bool = false,
    mobileCookieOnly: Bool = false, mobileTokenFile: String? = nil, bodyFile: String? = nil
) async -> Bool {
    var reports: [String] = []
    var succeeded = true
    func record(_ report: String) {
        print(report)
        reports.append(report)
    }
    let cookieFile = selectedCookieBackupFile()
    if let outputFile, discoveryOutputOverwritesInput(
        outputFile, bodyFile: bodyFile, mobileTokenFile: mobileTokenFile, cookieBackupFile: cookieFile
    ) {
        record("The discovery report destination must differ from the cookie archive, --body-file, and --mobile-token-file, including redirected stdin.")
        return false
    }
    do {
        guard let data = bodyJSON.data(using: .utf8),
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw DiscoveryError.unsupportedRequest }
        var request = try DiscoveryRequest(endpoint: endpoint, body: body)
        let mobileAccessToken = try mobileTokenFile.map { try loadMobileAccessToken(from: $0) }
        // Freeze the cookie identity for the whole chain, including web configuration
        // reads. An empty snapshot keeps a guest run from acquiring cookies later.
        let cookies = mobileAccessToken == nil ? loadCookiesFromAppBackup(from: cookieFile) ?? [] : []
        let cookieHeader = buildCookieHeader(from: cookies)
        let mobileCookieHeader = mobileCookieOnly ? cookieHeader : nil
        let authenticated = getSAPISID(from: cookies) != nil && cookieHeader != nil
        let authentication = mobileAccessToken != nil
            ? "mobile OAuth supplied on every hop"
            : (authenticated || mobileCookieHeader != nil ? "web cookies supplied on every hop" : "guest")
        record("Read-only discovery. Response values, account IDs, and tokens stay hidden.")
        record("Client: \(mobileClient?.rawValue ?? activeClientName); authentication: \(authentication)")
        if let mobileClient {
            let profile = MusicMobileRequestProfile(client: mobileClient, version: clientVersionWasForced ? cachedClientVersion : nil)
            record("Mobile profile version: \(profile.version); source: \(clientVersionWasForced ? "override" : "configured default")")
            record("Mobile web API key: \(mobileWebKey ? "resolved from web configuration" : "omitted")")
            let authorization = mobileAccessToken != nil ? "Bearer" : (authenticated && !mobileCookieOnly ? "SAPISIDHASH" : "omitted")
            record("Mobile authorization header: \(authorization)")
        }
        if mobileClient != nil, authenticated || mobileCookieHeader != nil {
            record("Mobile web-cookie authentication must be confirmed by the server session, not credential presence.")
        }
        record("Captured: " + ISO8601DateFormatter().string(from: Date()))

        for step in 0 ... followIndices.count {
            let wire = try await makeWireRequest(
                endpoint: request.endpoint, body: request.body, authenticated: authenticated,
                cookieSnapshot: cookies, mobileClient: mobileClient,
                mobileWebKey: mobileWebKey, mobileCookieOnly: mobileCookieOnly,
                mobileAccessToken: mobileAccessToken, mobileCookieHeader: mobileCookieHeader
            )
            guard let response = try? JSONSerialization.jsonObject(with: wire.data) as? [String: Any] else {
                record("Step \(step): \(request.summary)\nHTTP \(wire.statusCode); response is not a JSON object. Use wire-action to inspect its format.")
                succeeded = false
                break
            }
            let audit = DiscoveryAudit(response: response, request: request)
            let report = "Step \(step): \(request.summary)\nHTTP \(wire.statusCode); bytes=\(wire.data.count)\n" + audit.rendered(limit: limit, verbose: verbose)
            record(report)
            guard (200 ... 299).contains(wire.statusCode), !audit.hasAPIError else {
                succeeded = false
                break
            }
            if step < followIndices.count {
                let index = followIndices[step]
                guard audit.navigation.indices.contains(index) else {
                    record("Selected navigation index is absent in this response. Re-run discover to inspect current entries.")
                    succeeded = false
                    break
                }
                let entry = audit.navigation[index]
                record("Following [\(index)] \(entry.summary)")
                request = entry.request
            }
        }
    } catch DiscoveryError.invalidMobileToken {
        record("Invalid mobile access-token file. Use a raw token of 1-8192 bytes in a mode-0600 regular file owned by you, without a symlink or extended ACL.")
        succeeded = false
    } catch DiscoveryError.unsupportedRequest {
        record("Unsupported discovery request. See discover help for allowed endpoints and fields; only the chart country form is accepted.")
        succeeded = false
    } catch {
        // URLSession errors can embed a URL containing the API key. Never print
        // the underlying error or arbitrary server-provided error messages here.
        record("Discovery failed while reading the request or contacting YouTube. Sensitive error details are hidden.")
        succeeded = false
    }
    if let outputFile {
        do {
            try writePrivateOutput(Data((reports.joined(separator: "\n\n") + "\n").utf8), to: outputFile)
            print("Saved a redacted discovery report with owner-only permissions.")
        } catch {
            print("Could not save the discovery report with owner-only permissions.")
            succeeded = false
        }
    }
    return succeeded
}
