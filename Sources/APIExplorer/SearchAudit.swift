import Foundation

// MARK: - SearchFilterProbe

struct SearchFilterProbe: Hashable {
    let label: String
    let query: String
    let params: String
}

let kasetSearchFilterLabels: Set<String> = [
    "Albums", "Artists", "Community playlists", "Episodes", "Featured playlists", "Playlists",
    "Podcasts", "Profiles", "Songs", "Videos",
]

// MARK: - SearchAuditContext

enum SearchAuditContext {
    case automatic
    case firstPage
    case continuation
}

func terminalSafe(_ value: String) -> String {
    var output = ""
    output.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
        if CharacterSet.controlCharacters.contains(scalar) {
            output += String(format: "\\u{%04X}", scalar.value)
        } else {
            output.unicodeScalars.append(scalar)
        }
    }
    return output
}

private func collectRenderers(
    named key: String,
    in value: Any,
    results: inout [[String: Any]]
) {
    if let dictionary = value as? [String: Any] {
        if let renderer = dictionary[key] as? [String: Any] {
            results.append(renderer)
        }

        for nestedKey in dictionary.keys.sorted() {
            if let nestedValue = dictionary[nestedKey] {
                collectRenderers(named: key, in: nestedValue, results: &results)
            }
        }
    } else if let array = value as? [Any] {
        for item in array {
            collectRenderers(named: key, in: item, results: &results)
        }
    }
}

private func renderers(named key: String, in value: Any) -> [[String: Any]] {
    var results: [[String: Any]] = []
    collectRenderers(named: key, in: value, results: &results)
    return results
}

func searchFilterProbes(from data: [String: Any]) -> [SearchFilterProbe] {
    let chips = renderers(named: "chipCloudChipRenderer", in: data)
    var probes: [SearchFilterProbe] = []
    var seen: Set<SearchFilterProbe> = []

    for chip in chips {
        guard let rawLabel = joinedRunsText(chip["text"] as? [String: Any]),
              let navigationEndpoint = chip["navigationEndpoint"] as? [String: Any],
              let searchEndpoint = navigationEndpoint["searchEndpoint"] as? [String: Any],
              let query = searchEndpoint["query"] as? String,
              let params = searchEndpoint["params"] as? String
        else {
            continue
        }

        let probe = SearchFilterProbe(label: terminalSafe(rawLabel), query: query, params: params)
        if seen.insert(probe).inserted {
            probes.append(probe)
        }
    }

    return probes
}

private func firstRun(in text: Any?) -> [String: Any]? {
    guard let text = text as? [String: Any],
          let runs = text["runs"] as? [[String: Any]]
    else {
        return nil
    }
    return runs.first
}

private func firstFlexColumnRun(in renderer: [String: Any], index: Int) -> [String: Any]? {
    guard let flexColumns = renderer["flexColumns"] as? [[String: Any]],
          flexColumns.indices.contains(index),
          let columnRenderer = flexColumns[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
    else {
        return nil
    }
    return firstRun(in: columnRenderer["text"])
}

private func searchRowTitle(_ renderer: [String: Any]) -> String {
    terminalSafe((firstFlexColumnRun(in: renderer, index: 0)?["text"] as? String) ?? "Untitled")
}

private func searchRowContentType(_ renderer: [String: Any]) -> String {
    guard let run = firstFlexColumnRun(in: renderer, index: 1),
          let rawCandidate = run["text"] as? String
    else {
        return "Unlabeled"
    }
    let candidate = terminalSafe(rawCandidate)

    let knownTypes: Set = [
        "Album", "Artist", "Audiobook", "Episode", "Playlist", "Podcast", "Profile", "Song", "Video",
    ]
    if candidate == "Single" || candidate == "EP" {
        return "Album"
    }
    if knownTypes.contains(candidate) {
        return candidate
    }
    if run["navigationEndpoint"] != nil {
        return "Unlabeled"
    }
    return "Unknown(\(candidate))"
}

private func watchVideoId(in endpoint: [String: Any]?) -> String? {
    guard let endpoint,
          let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
          let videoId = watchEndpoint["videoId"] as? String,
          !videoId.isEmpty
    else {
        return nil
    }
    return videoId
}

private func musicVideoType(in endpoint: [String: Any]?) -> String? {
    guard let endpoint,
          let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
          let configs = watchEndpoint["watchEndpointMusicSupportedConfigs"] as? [String: Any],
          let musicConfig = configs["watchEndpointMusicConfig"] as? [String: Any]
    else {
        return nil
    }
    return (musicConfig["musicVideoType"] as? String).map(terminalSafe)
}

private func browseEndpoint(in endpoint: [String: Any]?) -> [String: Any]? {
    endpoint?["browseEndpoint"] as? [String: Any]
}

private func innertubeEndpoint(in value: Any?) -> [String: Any]? {
    guard let dictionary = value as? [String: Any] else { return nil }
    if let command = dictionary["innertubeCommand"] as? [String: Any] {
        return command
    }
    return dictionary
}

private func playNavigationEndpoint(in overlay: Any?) -> [String: Any]? {
    guard let overlay = overlay as? [String: Any],
          let thumbnailOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
          let content = thumbnailOverlay["content"] as? [String: Any],
          let playButton = content["musicPlayButtonRenderer"] as? [String: Any]
    else {
        return nil
    }
    return playButton["playNavigationEndpoint"] as? [String: Any]
}

private func pageType(in browseEndpoint: [String: Any]?) -> String? {
    guard let browseEndpoint,
          let configs = browseEndpoint["browseEndpointContextSupportedConfigs"] as? [String: Any],
          let musicConfig = configs["browseEndpointContextMusicConfig"] as? [String: Any]
    else {
        return nil
    }
    return (musicConfig["pageType"] as? String).map(terminalSafe)
}

private func searchRowVideoSources(_ renderer: [String: Any]) -> [(label: String, videoId: String)] {
    var sources: [(label: String, videoId: String)] = []

    if let playlistItemData = renderer["playlistItemData"] as? [String: Any],
       let videoId = playlistItemData["videoId"] as? String,
       !videoId.isEmpty
    {
        sources.append(("playlistItemData", videoId))
    }

    if let videoId = watchVideoId(in: renderer["navigationEndpoint"] as? [String: Any]) {
        sources.append(("rowNavigation", videoId))
    }

    if let titleRun = firstFlexColumnRun(in: renderer, index: 0),
       let videoId = watchVideoId(in: titleRun["navigationEndpoint"] as? [String: Any])
    {
        sources.append(("titleRun", videoId))
    }

    if let overlay = renderer["overlay"] as? [String: Any],
       let thumbnailOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
       let content = thumbnailOverlay["content"] as? [String: Any],
       let playButton = content["musicPlayButtonRenderer"] as? [String: Any],
       let videoId = watchVideoId(in: playButton["playNavigationEndpoint"] as? [String: Any])
    {
        sources.append(("overlay", videoId))
    }

    return sources
}

private func searchRowBrowseSources(_ renderer: [String: Any]) -> [(label: String, endpoint: [String: Any])] {
    var sources: [(label: String, endpoint: [String: Any])] = []

    if let endpoint = browseEndpoint(in: renderer["navigationEndpoint"] as? [String: Any]) {
        sources.append(("rowNavigation", endpoint))
    }

    if let titleRun = firstFlexColumnRun(in: renderer, index: 0),
       let endpoint = browseEndpoint(in: titleRun["navigationEndpoint"] as? [String: Any])
    {
        sources.append(("titleRun", endpoint))
    }

    return sources
}

private func searchRowMusicVideoTypes(_ renderer: [String: Any]) -> [String] {
    var types: [String] = []

    if let type = musicVideoType(in: renderer["navigationEndpoint"] as? [String: Any]) {
        types.append(type)
    }

    if let titleRun = firstFlexColumnRun(in: renderer, index: 0),
       let type = musicVideoType(in: titleRun["navigationEndpoint"] as? [String: Any])
    {
        types.append(type)
    }

    if let overlay = renderer["overlay"] as? [String: Any],
       let thumbnailOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
       let content = thumbnailOverlay["content"] as? [String: Any],
       let playButton = content["musicPlayButtonRenderer"] as? [String: Any],
       let type = musicVideoType(in: playButton["playNavigationEndpoint"] as? [String: Any])
    {
        types.append(type)
    }

    return Array(Set(types)).sorted()
}

private func searchCardEndpointSources(
    _ card: [String: Any]
) -> [(label: String, endpoint: [String: Any])] {
    var sources: [(label: String, endpoint: [String: Any])] = []

    if let titleRun = firstRun(in: card["title"]),
       let endpoint = innertubeEndpoint(in: titleRun["navigationEndpoint"])
    {
        sources.append(("titleRun", endpoint))
    }
    if let endpoint = innertubeEndpoint(in: card["navigationEndpoint"]) {
        sources.append(("cardNavigation", endpoint))
    }
    if let endpoint = innertubeEndpoint(in: card["onTap"]) {
        sources.append(("onTap", endpoint))
    }
    if let endpoint = playNavigationEndpoint(in: card["thumbnailOverlay"]) {
        sources.append(("thumbnailOverlay", endpoint))
    }
    if let endpoint = playNavigationEndpoint(in: card["overlay"]) {
        sources.append(("overlay", endpoint))
    }

    return sources
}

private func searchCardVideoSources(
    _ card: [String: Any]
) -> [(label: String, endpoint: [String: Any])] {
    searchCardEndpointSources(card).filter { watchVideoId(in: $0.endpoint) != nil }
}

private func searchCardBrowseSources(
    _ card: [String: Any]
) -> [(label: String, endpoint: [String: Any])] {
    searchCardEndpointSources(card).filter { browseEndpoint(in: $0.endpoint) != nil }
}

private func continuationCount(in renderer: [String: Any]) -> Int {
    (renderer["continuations"] as? [[String: Any]])?.count ?? 0
}

func firstSearchContinuationValue(in data: [String: Any]) -> String? {
    let continuationRenderers =
        renderers(named: "musicShelfRenderer", in: data)
            + renderers(named: "musicShelfContinuation", in: data)
            + renderers(named: "sectionListRenderer", in: data)

    for renderer in continuationRenderers {
        guard let continuations = renderer["continuations"] as? [[String: Any]] else {
            continue
        }
        for continuation in continuations {
            for dataKey in ["nextContinuationData", "reloadContinuationData"] {
                if let continuationData = continuation[dataKey] as? [String: Any],
                   let continuationValue = continuationData["continuation"] as? String,
                   !continuationValue.isEmpty
                {
                    return continuationValue
                }
            }
        }
    }

    for item in renderers(named: "continuationItemRenderer", in: data) {
        guard let endpoint = item["continuationEndpoint"] as? [String: Any],
              let command = endpoint["continuationCommand"] as? [String: Any],
              let continuationValue = command["token"] as? String,
              !continuationValue.isEmpty
        else {
            continue
        }
        return continuationValue
    }

    return nil
}

func searchContinuationActionGroups(
    in data: [String: Any]
) -> [(envelope: String, command: String, items: [[String: Any]])] {
    var groups: [(envelope: String, command: String, items: [[String: Any]])] = []
    for envelopeKey in [
        "onResponseReceivedCommands",
        "onResponseReceivedActions",
        "onResponseReceivedEndpoints",
    ] {
        guard let actions = data[envelopeKey] as? [[String: Any]] else { continue }
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
                groups.append((envelopeKey, commandKey, items))
            }
        }
    }
    return groups
}

private func hasMusicSearchContinuationEnvelope(_ data: [String: Any]) -> Bool {
    if let continuationContents = data["continuationContents"] as? [String: Any],
       continuationContents["musicShelfContinuation"] is [String: Any]
    {
        return true
    }
    return !searchContinuationActionGroups(in: data).isEmpty
}

private func formattedCounts(_ counts: [String: Int]) -> String {
    guard !counts.isEmpty else { return "none" }
    return counts.sorted { lhs, rhs in
        lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
    }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
}

// MARK: - CurrentSearchParserCoverage

private struct CurrentSearchParserCoverage {
    var parsedTypes: [String: Int] = [:]
    var ignoredSections: [String: Int] = [:]
    var droppedCards = 0
    var droppedRows = 0
    var rootStructureSupported = true
}

private func currentContentKind(fromLabel label: String) -> String? {
    switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "song": "song"
    case "video": "video"
    case "album", "single", "ep": "album"
    case "audiobook": "audiobook"
    case "artist": "artist"
    case "profile": "profile"
    case "playlist": "playlist"
    case "podcast": "podcastShow"
    case "episode", "podcast episode": "podcastEpisode"
    default: nil
    }
}

private func currentContentKind(in renderer: [String: Any]) -> String? {
    var textContainers: [[String: Any]] = []

    if let flexColumns = renderer["flexColumns"] as? [[String: Any]],
       flexColumns.indices.contains(1),
       let column = flexColumns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
       let text = column["text"] as? [String: Any]
    {
        textContainers.append(text)
    }

    for key in ["subtitle", "secondSubtitle"] {
        if let text = renderer[key] as? [String: Any] {
            textContainers.append(text)
        }
    }

    for container in textContainers {
        guard let runs = container["runs"] as? [[String: Any]] else { continue }
        for run in runs {
            guard let text = run["text"] as? String else { continue }
            let components = text
                .components(separatedBy: "•")
                .flatMap { $0.components(separatedBy: "·") }
            for component in components {
                if let kind = currentContentKind(fromLabel: component) {
                    return kind
                }
            }
        }
    }

    return nil
}

private func currentTitleRun(in renderer: [String: Any]) -> [String: Any]? {
    firstFlexColumnRun(in: renderer, index: 0) ?? firstRun(in: renderer["title"])
}

private func appendCurrentEndpoint(_ value: Any?, to endpoints: inout [[String: Any]]) {
    guard let endpoint = innertubeEndpoint(in: value) else { return }
    endpoints.append(endpoint)
}

private func currentEndpointCandidates(from renderer: [String: Any]) -> [[String: Any]] {
    var endpoints: [[String: Any]] = []
    appendCurrentEndpoint(renderer["navigationEndpoint"], to: &endpoints)
    appendCurrentEndpoint(currentTitleRun(in: renderer)?["navigationEndpoint"], to: &endpoints)
    appendCurrentEndpoint(renderer["onTap"], to: &endpoints)
    appendCurrentEndpoint(playNavigationEndpoint(in: renderer["thumbnailOverlay"]), to: &endpoints)
    appendCurrentEndpoint(playNavigationEndpoint(in: renderer["overlay"]), to: &endpoints)
    return endpoints
}

private func currentBrowseDisposition(
    _ browse: [String: Any],
    contentKind: String?
) -> String? {
    guard let browseId = browse["browseId"] as? String else { return nil }
    let type = pageType(in: browse)

    switch type {
    case "MUSIC_PAGE_TYPE_ALBUM":
        return "album"
    case "MUSIC_PAGE_TYPE_AUDIOBOOK":
        return "audiobook"
    case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
        return "artist"
    case "MUSIC_PAGE_TYPE_USER_CHANNEL":
        return "profile"
    case "MUSIC_PAGE_TYPE_PLAYLIST":
        return "playlist"
    case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE":
        return "podcastShow"
    default:
        break
    }

    if browseId.hasPrefix("MPSPP") {
        return "podcastShow"
    }
    if browseId.hasPrefix("MPED") || contentKind == "podcastEpisode" {
        return "podcastEpisode"
    }
    if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
        return contentKind == "audiobook" ? "audiobook" : "album"
    }
    if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
        return "playlist"
    }
    if browseId.hasPrefix("UC") || browseId.hasPrefix("MPLAUC") {
        return contentKind == "profile" ? "profile" : "artist"
    }
    return nil
}

private func currentItemDisposition(_ renderer: [String: Any]) -> String? {
    let contentKind = currentContentKind(in: renderer)
    let endpoints = currentEndpointCandidates(from: renderer)
    var hasPodcastEpisodeBrowseDestination = false

    for endpoint in endpoints {
        guard let browse = browseEndpoint(in: endpoint),
              let disposition = currentBrowseDisposition(browse, contentKind: contentKind)
        else {
            continue
        }

        if disposition == "podcastEpisode" {
            hasPodcastEpisodeBrowseDestination = true
            continue
        }
        return disposition
    }

    let playlistVideoId = (renderer["playlistItemData"] as? [String: Any])?["videoId"] as? String
    let hasPlayableDestination = playlistVideoId?.isEmpty == false
        || endpoints.contains { watchVideoId(in: $0) != nil }
    guard hasPlayableDestination else { return nil }

    let videoTypes = Set(endpoints.compactMap { musicVideoType(in: $0) })
    if hasPodcastEpisodeBrowseDestination
        || contentKind == "podcastEpisode"
        || videoTypes.contains("MUSIC_VIDEO_TYPE_PODCAST_EPISODE")
    {
        return "podcastEpisode"
    }

    if contentKind == "video"
        || !videoTypes.isDisjoint(with: [
            "MUSIC_VIDEO_TYPE_OMV",
            "MUSIC_VIDEO_TYPE_UGC",
            "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC",
        ])
    {
        return "video"
    }
    return "song"
}

private func recordCurrentSearchContainer(
    _ container: [String: Any],
    coverage: inout CurrentSearchParserCoverage
) {
    if let card = container["musicCardShelfRenderer"] as? [String: Any] {
        if let disposition = currentItemDisposition(card) {
            coverage.parsedTypes[disposition, default: 0] += 1
        } else {
            coverage.droppedCards += 1
        }
        for content in card["contents"] as? [[String: Any]] ?? [] {
            recordCurrentSearchContainer(content, coverage: &coverage)
        }
        return
    }

    if let shelf = container["musicShelfRenderer"] as? [String: Any] {
        for content in shelf["contents"] as? [[String: Any]] ?? [] {
            recordCurrentSearchContainer(content, coverage: &coverage)
        }
        return
    }

    if let itemSection = container["itemSectionRenderer"] as? [String: Any] {
        for content in itemSection["contents"] as? [[String: Any]] ?? [] {
            recordCurrentSearchContainer(content, coverage: &coverage)
        }
        return
    }

    for rendererKey in [
        "musicResponsiveListItemRenderer",
        "musicTwoRowItemRenderer",
        "musicMultiRowListItemRenderer",
    ] {
        guard let renderer = container[rendererKey] as? [String: Any] else { continue }
        if let disposition = currentItemDisposition(renderer) {
            coverage.parsedTypes[disposition, default: 0] += 1
        } else {
            coverage.droppedRows += 1
        }
        return
    }

    if container["continuationItemRenderer"] != nil {
        return
    }

    let nestedResultCount = renderers(named: "musicResponsiveListItemRenderer", in: container).count
        + renderers(named: "musicTwoRowItemRenderer", in: container).count
        + renderers(named: "musicMultiRowListItemRenderer", in: container).count
        + renderers(named: "musicCardShelfRenderer", in: container).count
    guard nestedResultCount > 0 else { return }

    let sectionType = terminalSafe(container.keys.min() ?? "unknown")
    coverage.ignoredSections[sectionType, default: 0] += 1
    coverage.droppedRows += nestedResultCount
}

private func currentSearchParserCoverage(_ data: [String: Any]) -> CurrentSearchParserCoverage? {
    var coverage = CurrentSearchParserCoverage()
    var recognizedContinuation = false

    if let continuationContents = data["continuationContents"] as? [String: Any],
       let shelf = continuationContents["musicShelfContinuation"] as? [String: Any]
    {
        recognizedContinuation = true
        for content in shelf["contents"] as? [[String: Any]] ?? [] {
            recordCurrentSearchContainer(content, coverage: &coverage)
        }
    }

    let actionGroups = searchContinuationActionGroups(in: data)
    if !actionGroups.isEmpty {
        recognizedContinuation = true
        for group in actionGroups {
            for content in group.items {
                recordCurrentSearchContainer(content, coverage: &coverage)
            }
        }
    }

    if recognizedContinuation {
        return coverage
    }

    guard let contents = data["contents"] as? [String: Any] else { return nil }

    var sectionLists: [[String: Any]] = []
    if let directSectionList = contents["sectionListRenderer"] as? [String: Any] {
        sectionLists.append(directSectionList)
    }
    if let tabbed = contents["tabbedSearchResultsRenderer"] as? [String: Any],
       let tabs = tabbed["tabs"] as? [[String: Any]]
    {
        for tab in tabs {
            guard let tabRenderer = tab["tabRenderer"] as? [String: Any],
                  let content = tabRenderer["content"] as? [String: Any],
                  let sectionList = content["sectionListRenderer"] as? [String: Any]
            else {
                continue
            }
            sectionLists.append(sectionList)
        }
    }

    guard !sectionLists.isEmpty else {
        coverage.rootStructureSupported = false
        return coverage
    }

    for sectionList in sectionLists {
        for content in sectionList["contents"] as? [[String: Any]] ?? [] {
            recordCurrentSearchContainer(content, coverage: &coverage)
        }
    }
    return coverage
}

// MARK: - BoundedSearchAuditRenderers

private struct BoundedSearchAuditRenderers {
    var itemSections: [[String: Any]] = []
    var cardShelves: [[String: Any]] = []
    var musicShelves: [[String: Any]] = []
    var shelfContinuations: [[String: Any]] = []
    var rows: [[String: Any]] = []
    var twoRowItems: [[String: Any]] = []
    var multiRowItems: [[String: Any]] = []
    var messageCount = 0
}

private func appendBoundedSearchAuditContainer(
    _ container: [String: Any],
    to renderers: inout BoundedSearchAuditRenderers
) {
    if let card = container["musicCardShelfRenderer"] as? [String: Any] {
        renderers.cardShelves.append(card)
        for content in card["contents"] as? [[String: Any]] ?? [] {
            appendBoundedSearchAuditContainer(content, to: &renderers)
        }
        return
    }

    if let shelf = container["musicShelfRenderer"] as? [String: Any] {
        renderers.musicShelves.append(shelf)
        for content in shelf["contents"] as? [[String: Any]] ?? [] {
            appendBoundedSearchAuditContainer(content, to: &renderers)
        }
        return
    }

    if let itemSection = container["itemSectionRenderer"] as? [String: Any] {
        renderers.itemSections.append(itemSection)
        for content in itemSection["contents"] as? [[String: Any]] ?? [] {
            appendBoundedSearchAuditContainer(content, to: &renderers)
        }
        return
    }

    if let row = container["musicResponsiveListItemRenderer"] as? [String: Any] {
        renderers.rows.append(row)
        return
    }
    if let item = container["musicTwoRowItemRenderer"] as? [String: Any] {
        renderers.twoRowItems.append(item)
        return
    }
    if let item = container["musicMultiRowListItemRenderer"] as? [String: Any] {
        renderers.multiRowItems.append(item)
        return
    }
    if container["musicMessageRenderer"] != nil || container["messageRenderer"] != nil {
        renderers.messageCount += 1
    }
}

private func boundedSearchAuditRenderers(in data: [String: Any]) -> BoundedSearchAuditRenderers {
    var renderers = BoundedSearchAuditRenderers()

    if let continuationContents = data["continuationContents"] as? [String: Any],
       let shelf = continuationContents["musicShelfContinuation"] as? [String: Any]
    {
        renderers.shelfContinuations.append(shelf)
        for content in shelf["contents"] as? [[String: Any]] ?? [] {
            appendBoundedSearchAuditContainer(content, to: &renderers)
        }
    }

    for group in searchContinuationActionGroups(in: data) {
        for content in group.items {
            appendBoundedSearchAuditContainer(content, to: &renderers)
        }
    }

    guard let contents = data["contents"] as? [String: Any] else {
        return renderers
    }

    var sectionLists: [[String: Any]] = []
    if let directSectionList = contents["sectionListRenderer"] as? [String: Any] {
        sectionLists.append(directSectionList)
    }
    if let tabbed = contents["tabbedSearchResultsRenderer"] as? [String: Any],
       let tabs = tabbed["tabs"] as? [[String: Any]]
    {
        for tab in tabs {
            guard let tabRenderer = tab["tabRenderer"] as? [String: Any],
                  let content = tabRenderer["content"] as? [String: Any],
                  let sectionList = content["sectionListRenderer"] as? [String: Any]
            else {
                continue
            }
            sectionLists.append(sectionList)
        }
    }

    for sectionList in sectionLists {
        for content in sectionList["contents"] as? [[String: Any]] ?? [] {
            appendBoundedSearchAuditContainer(content, to: &renderers)
        }
    }
    return renderers
}

private func boundedContainerContainsResult(_ container: [String: Any]) -> Bool {
    if container["musicCardShelfRenderer"] != nil
        || container["musicShelfRenderer"] != nil
        || container["musicResponsiveListItemRenderer"] != nil
        || container["musicTwoRowItemRenderer"] != nil
        || container["musicMultiRowListItemRenderer"] != nil
    {
        return true
    }
    guard let section = container["itemSectionRenderer"] as? [String: Any] else {
        return false
    }
    return (section["contents"] as? [[String: Any]] ?? []).contains(where: boundedContainerContainsResult)
}

// MARK: - SearchAuditSnapshot

private struct SearchAuditSnapshot {
    let tabbedSearchCount: Int
    let itemSections: [[String: Any]]
    let cardShelves: [[String: Any]]
    let musicShelves: [[String: Any]]
    let shelfContinuations: [[String: Any]]
    let rows: [[String: Any]]
    let twoRowItems: [[String: Any]]
    let multiRowItems: [[String: Any]]
    let messageCount: Int
    let chips: [SearchFilterProbe]
    let hasMusicHeader: Bool
    let hasDirectSectionList: Bool
    let hasContinuationEnvelope: Bool

    init(data: [String: Any]) {
        let boundedRenderers = boundedSearchAuditRenderers(in: data)
        let contents = data["contents"] as? [String: Any]
        self.tabbedSearchCount = contents?["tabbedSearchResultsRenderer"] == nil ? 0 : 1
        self.itemSections = boundedRenderers.itemSections
        self.cardShelves = boundedRenderers.cardShelves
        self.musicShelves = boundedRenderers.musicShelves
        self.shelfContinuations = boundedRenderers.shelfContinuations
        self.rows = boundedRenderers.rows
        self.twoRowItems = boundedRenderers.twoRowItems
        self.multiRowItems = boundedRenderers.multiRowItems
        self.messageCount = boundedRenderers.messageCount
        self.chips = searchFilterProbes(from: data)
        self.hasMusicHeader = !renderers(named: "musicHeaderRenderer", in: data).isEmpty
        self.hasDirectSectionList = contents?["sectionListRenderer"] != nil
        self.hasContinuationEnvelope = hasMusicSearchContinuationEnvelope(data)
    }

    func isRecognized(in context: SearchAuditContext) -> Bool {
        switch context {
        case .automatic:
            self.tabbedSearchCount > 0
                || (self.hasDirectSectionList && self.hasMusicHeader && !self.chips.isEmpty)
        case .firstPage:
            self.tabbedSearchCount > 0 || self.hasDirectSectionList
        case .continuation:
            self.hasContinuationEnvelope
        }
    }

    var cardNestedItemCount: Int {
        self.cardShelves.reduce(0) { count, card in
            count + ((card["contents"] as? [[String: Any]])?.count ?? 0)
        }
    }

    var resultItemSectionCount: Int {
        self.itemSections.count { section in
            (section["contents"] as? [[String: Any]] ?? []).contains(where: boundedContainerContainsResult)
        }
    }
}

// MARK: - SearchRowAuditStats

private struct SearchRowAuditStats {
    var contentTypes: [String: Int] = [:]
    var videoSourceCounts: [String: Int] = [:]
    var musicVideoTypeCounts: [String: Int] = [:]
    var browseSourceCounts: [String: Int] = [:]
    var browsePageTypes: [String: Int] = [:]
    var unaddressableRows = 0
    var overlayOnlyRows = 0
}

private func makeSearchRowAuditStats(_ rows: [[String: Any]]) -> SearchRowAuditStats {
    var stats = SearchRowAuditStats()
    for row in rows {
        stats.contentTypes[searchRowContentType(row), default: 0] += 1
        let videoSources = searchRowVideoSources(row)
        let browseSources = searchRowBrowseSources(row)

        for source in videoSources {
            stats.videoSourceCounts[source.label, default: 0] += 1
        }
        for type in searchRowMusicVideoTypes(row) {
            stats.musicVideoTypeCounts[type, default: 0] += 1
        }
        for source in browseSources {
            stats.browseSourceCounts[source.label, default: 0] += 1
        }
        let rowPageTypes = Set(browseSources.map { pageType(in: $0.endpoint) ?? "unknown" })
        for type in rowPageTypes {
            stats.browsePageTypes[type, default: 0] += 1
        }

        if videoSources.isEmpty, browseSources.isEmpty {
            stats.unaddressableRows += 1
        }
        if videoSources.map(\.label) == ["overlay"] {
            stats.overlayOnlyRows += 1
        }
    }
    return stats
}

// MARK: - SearchCardAuditStats

private struct SearchCardAuditStats {
    var watchEndpoints = 0
    var browseEndpoints = 0
    var unknownEndpoints = 0
    var musicVideoTypeCounts: [String: Int] = [:]
    var videoSourceCounts: [String: Int] = [:]
    var browseSourceCounts: [String: Int] = [:]
}

private func makeSearchCardAuditStats(_ cards: [[String: Any]]) -> SearchCardAuditStats {
    var stats = SearchCardAuditStats()
    for card in cards {
        let videoSources = searchCardVideoSources(card)
        let browseSources = searchCardBrowseSources(card)

        if videoSources.isEmpty, browseSources.isEmpty {
            stats.unknownEndpoints += 1
            continue
        }
        if !videoSources.isEmpty {
            stats.watchEndpoints += 1
        }
        if !browseSources.isEmpty {
            stats.browseEndpoints += 1
        }
        for source in videoSources {
            stats.videoSourceCounts[source.label, default: 0] += 1
        }
        for source in browseSources {
            stats.browseSourceCounts[source.label, default: 0] += 1
        }
        for type in Set(videoSources.compactMap { musicVideoType(in: $0.endpoint) }) where !type.isEmpty {
            stats.musicVideoTypeCounts[type, default: 0] += 1
        }
    }
    return stats
}

// MARK: - SearchContinuationAuditStats

private struct SearchContinuationAuditStats {
    let sectionListContinuationCount: Int
    let shelfContinuationCount: Int
    let nextShelfContinuationCount: Int
    let continuationItems: Int
    let hasFollowableContinuation: Bool
}

private func makeSearchContinuationAuditStats(
    _ data: [String: Any],
    snapshot: SearchAuditSnapshot
) -> SearchContinuationAuditStats {
    let sectionLists = renderers(named: "sectionListRenderer", in: data)
    return SearchContinuationAuditStats(
        sectionListContinuationCount: sectionLists.reduce(0) { $0 + continuationCount(in: $1) },
        shelfContinuationCount: snapshot.musicShelves.reduce(0) { $0 + continuationCount(in: $1) },
        nextShelfContinuationCount: snapshot.shelfContinuations.reduce(0) { $0 + continuationCount(in: $1) },
        continuationItems: renderers(named: "continuationItemRenderer", in: data).count,
        hasFollowableContinuation: firstSearchContinuationValue(in: data) != nil
    )
}

private func formatSearchAuditOverview(
    data: [String: Any],
    snapshot: SearchAuditSnapshot,
    rows: SearchRowAuditStats,
    cards: SearchCardAuditStats,
    continuations: SearchContinuationAuditStats
) -> String {
    var output = "\n🔎 Search response audit:\n"
    output += "  • Layout: tabbed=\(snapshot.tabbedSearchCount), item sections=\(snapshot.itemSections.count), card shelves=\(snapshot.cardShelves.count), music shelves=\(snapshot.musicShelves.count), shelf continuations=\(snapshot.shelfContinuations.count)\n"
    if snapshot.cardNestedItemCount > 0 {
        output += "  • Nested top-card items: \(snapshot.cardNestedItemCount)\n"
    }
    if !snapshot.twoRowItems.isEmpty || !snapshot.multiRowItems.isEmpty {
        output += "  • Other search items: two-row=\(snapshot.twoRowItems.count), multi-row=\(snapshot.multiRowItems.count)\n"
    }
    if snapshot.messageCount > 0 {
        output += "  • Message renderers: \(snapshot.messageCount)\n"
    }
    output += "  • Responsive rows: \(snapshot.rows.count) (\(formattedCounts(rows.contentTypes)))\n"
    output += "  • Video ID paths: \(formattedCounts(rows.videoSourceCounts))\n"
    if !rows.musicVideoTypeCounts.isEmpty {
        output += "  • Row music video types: \(formattedCounts(rows.musicVideoTypeCounts))\n"
    }
    output += "  • Browse paths: \(formattedCounts(rows.browseSourceCounts))\n"
    if !rows.browsePageTypes.isEmpty {
        output += "  • Browse page types: \(formattedCounts(rows.browsePageTypes))\n"
    }
    output += "  • Top cards: watch=\(cards.watchEndpoints), browse=\(cards.browseEndpoints), unknown=\(cards.unknownEndpoints)\n"
    if !cards.videoSourceCounts.isEmpty {
        output += "  • Top-card video paths: \(formattedCounts(cards.videoSourceCounts))\n"
    }
    if !cards.browseSourceCounts.isEmpty {
        output += "  • Top-card browse paths: \(formattedCounts(cards.browseSourceCounts))\n"
    }
    if !cards.musicVideoTypeCounts.isEmpty {
        output += "  • Top-card music video types: \(formattedCounts(cards.musicVideoTypeCounts))\n"
    }
    output += "  • Continuations: section list=\(continuations.sectionListContinuationCount), music shelf=\(continuations.shelfContinuationCount), shelf continuation=\(continuations.nextShelfContinuationCount), continuation items=\(continuations.continuationItems), followable=\(continuations.hasFollowableContinuation ? "yes" : "no")\n"
    if !snapshot.chips.isEmpty {
        output += "  • Live filter chips: \(snapshot.chips.map(\.label).joined(separator: ", "))\n"
    }
    return output + formatCurrentMixedParserCoverage(data)
}

private func formatCurrentMixedParserCoverage(_ data: [String: Any]) -> String {
    guard let coverage = currentSearchParserCoverage(data) else { return "" }
    if !coverage.rootStructureSupported {
        return "  • Current Kaset parser reachability: unsupported response root\n"
    }
    let parsedCount = coverage.parsedTypes.values.reduce(0, +)
    var output = "  • Current Kaset parser reachability: supported=\(parsedCount) (\(formattedCounts(coverage.parsedTypes))), unhandled cards=\(coverage.droppedCards), unhandled result rows=\(coverage.droppedRows)\n"
    if !coverage.ignoredSections.isEmpty {
        output += "  • Current Kaset ignored sections: \(formattedCounts(coverage.ignoredSections))\n"
    }
    return output
}

private func searchAuditWarnings(
    snapshot: SearchAuditSnapshot,
    rows: SearchRowAuditStats,
    cards: SearchCardAuditStats,
    continuations: SearchContinuationAuditStats
) -> [String] {
    var warnings: [String] = []
    if snapshot.resultItemSectionCount > 0 {
        warnings.append("result rows are nested in \(snapshot.resultItemSectionCount) itemSectionRenderer wrapper(s)")
    }
    if cards.watchEndpoints > 0 {
        warnings.append("top cards use watchEndpoint")
    }
    if rows.overlayOnlyRows > 0 {
        warnings.append("\(rows.overlayOnlyRows) row(s) expose a video ID only through the overlay")
    }
    if continuations.shelfContinuationCount > 0, continuations.sectionListContinuationCount == 0 {
        warnings.append("first-page continuation token is stored on musicShelfRenderer")
    }
    if rows.unaddressableRows > 0 {
        warnings.append("\(rows.unaddressableRows) row(s) have no recognized watch or browse destination")
    }
    if !snapshot.twoRowItems.isEmpty || !snapshot.multiRowItems.isEmpty {
        warnings.append("search includes non-responsive item renderers that need separate parsing")
    }
    if snapshot.cardNestedItemCount > 0 {
        warnings.append("top cards contain \(snapshot.cardNestedItemCount) nested item(s)")
    }
    return warnings
}

private func formatSearchRowSamples(_ rows: [[String: Any]], limit: Int) -> String {
    guard limit > 0, !rows.isEmpty else { return "" }
    var output = "  • Sample rows:\n"
    for row in rows.prefix(limit) {
        let type = searchRowContentType(row)
        let title = searchRowTitle(row)
        let videoSources = searchRowVideoSources(row)
        let browseSources = searchRowBrowseSources(row)
        let destination = if !videoSources.isEmpty {
            "video via \(videoSources.map(\.label).joined(separator: "+"))"
        } else if let browseSource = browseSources.first {
            "browse via \(browseSource.label) (\(pageType(in: browseSource.endpoint) ?? "unknown"))"
        } else {
            "no destination"
        }
        output += "    - [\(type)] \(title) — \(destination)\n"
    }
    if rows.count > limit {
        output += "    - … and \(rows.count - limit) more\n"
    }
    return output
}

private func formatSearchCardSamples(_ cards: [[String: Any]], limit: Int) -> String {
    guard limit > 0, !cards.isEmpty else { return "" }
    var output = "  • Top-card samples:\n"
    for card in cards.prefix(limit) {
        let title = terminalSafe(joinedRunsText(card["title"] as? [String: Any]) ?? "Untitled")
        let subtitle = joinedRunsText(card["subtitle"] as? [String: Any]).map(terminalSafe)
        let videoSources = searchCardVideoSources(card)
        let browseSources = searchCardBrowseSources(card)
        let destination: String
        if !videoSources.isEmpty {
            let types = Set(videoSources.compactMap { musicVideoType(in: $0.endpoint) }).sorted()
            let typeSummary = types.isEmpty ? "unknown type" : types.joined(separator: "+")
            destination = "watch via \(videoSources.map(\.label).joined(separator: "+")) (\(typeSummary))"
        } else if let source = browseSources.first,
                  let browse = browseEndpoint(in: source.endpoint)
        {
            destination = "browse via \(source.label) (\(pageType(in: browse) ?? "unknown type"))"
        } else {
            destination = "no recognized destination"
        }
        output += "    - \(title) — \(destination)\(subtitle.map { " — \($0)" } ?? "")\n"
    }
    return output
}

func isSuccessfulAPIResponse(statusCode: Int, data: [String: Any]) -> Bool {
    (200 ... 299).contains(statusCode) && data["error"] == nil
}

func apiFailureDescription(statusCode: Int, data: [String: Any]) -> String {
    guard let error = data["error"] as? [String: Any] else {
        return "HTTP \(statusCode)"
    }
    let code = terminalSafe(error["code"].map(String.init(describing:)) ?? "unknown")
    let message = terminalSafe(error["message"] as? String ?? "Unknown API error")
    return "HTTP \(statusCode), API \(code): \(message)"
}

func searchResponseAuditSummary(
    _ data: [String: Any],
    sampleLimit: Int = 6,
    context: SearchAuditContext = .automatic
) -> String {
    let snapshot = SearchAuditSnapshot(data: data)
    guard snapshot.isRecognized(in: context) else { return "" }

    let rowStats = makeSearchRowAuditStats(snapshot.rows)
    let cardStats = makeSearchCardAuditStats(snapshot.cardShelves)
    let continuationStats = makeSearchContinuationAuditStats(data, snapshot: snapshot)
    var output = formatSearchAuditOverview(
        data: data,
        snapshot: snapshot,
        rows: rowStats,
        cards: cardStats,
        continuations: continuationStats
    )
    for warning in searchAuditWarnings(
        snapshot: snapshot,
        rows: rowStats,
        cards: cardStats,
        continuations: continuationStats
    ) {
        output += "  ⚠️ \(warning)\n"
    }
    output += formatSearchRowSamples(snapshot.rows, limit: sampleLimit)
    output += formatSearchCardSamples(snapshot.cardShelves, limit: sampleLimit)
    return output
}
