#!/usr/bin/env swift
//
//  main.swift
//  Standalone API Explorer for YouTube Music and YouTube
//
//  A unified tool for exploring public and authenticated YouTube Music and regular YouTube API endpoints.
//  Reads cookies from the Kaset app's debug cookie export for authenticated requests.
//
//  Usage:
//    swift run api-explorer [command] [options]
//
//  Commands:
//    browse <browseId> [params]    - Explore a browse endpoint
//    action <endpoint> <body>      - Explore an action endpoint (body as JSON)
//    continuation <token> [ep]     - Explore a continuation (ep: browse or next)
//    analyze-file <path>           - Safely summarize a saved JSON response
//    list                          - List all known endpoints
//    auth                          - Check authentication status
//    help                          - Show this help message
//
//  Options:
//    -v, --verbose                 - Show full raw JSON response (not truncated)
//    -o, --output <file>           - Save raw JSON response to a file
//    --youtube, --yt               - Target regular YouTube (www.youtube.com, WEB client)
//                                    instead of YouTube Music
//    --no-auth, --guest            - Force unauthenticated requests even if Kaset cookies exist
//
//  Examples:
//    swift run api-explorer browse FEmusic_home
//    swift run api-explorer browse FEmusic_charts
//    swift run api-explorer browse FEmusic_liked_playlists   # Requires auth
//    swift run api-explorer action search '{"query":"never gonna give you up"}'
//    swift run api-explorer continuation <token> next        # Mix queue continuation
//    swift run api-explorer auth
//    swift run api-explorer list
//

import CommonCrypto
import Dispatch
import Foundation

// MARK: - Configuration

let apiKeyEnvironmentVariable = "KASET_YTMUSIC_API_KEY"
let webClientURL = URL(string: "https://music.youtube.com")!
nonisolated(unsafe) var cachedAPIKey: String?
let clientVersion = "1.20231204.01.00"
let baseURL = "https://music.youtube.com/youtubei/v1"
let origin = "https://music.youtube.com"

/// When true, the explorer targets regular YouTube (www.youtube.com, WEB client)
/// instead of YouTube Music (music.youtube.com, WEB_REMIX client). Set via --youtube.
nonisolated(unsafe) var youtubeMode = false
nonisolated(unsafe) var cachedClientVersion: String?
nonisolated(unsafe) var forceUnauthenticatedRequests = false

// Active request configuration. Defaults to YouTube Music (the constants
// above); --youtube switches everything to regular YouTube.
nonisolated(unsafe) var activeAPIHost = "music.youtube.com"
nonisolated(unsafe) var activeWebClientURL = webClientURL
nonisolated(unsafe) var activeClientName = "WEB_REMIX"
nonisolated(unsafe) var activeFallbackClientVersion = clientVersion
nonisolated(unsafe) var activeBaseURL = baseURL
nonisolated(unsafe) var activeOrigin = origin

/// Switches all request configuration to regular YouTube (WEB client).
func activateYouTubeMode() {
    youtubeMode = true
    activeAPIHost = "www.youtube.com"
    activeWebClientURL = URL(string: "https://www.youtube.com")!
    activeClientName = "WEB"
    activeFallbackClientVersion = "2.20250101.00.00"
    activeBaseURL = "https://www.youtube.com/youtubei/v1"
    activeOrigin = "https://www.youtube.com"
}

/// Global auth user index (0 = primary account, 1+ = brand accounts)
nonisolated(unsafe) var globalAuthUserIndex = 0

/// Global brand account ID (21-digit number from myaccount.google.com/brandaccounts)
nonisolated(unsafe) var globalBrandAccountId: String?

// MARK: - Cookie Management

/// Reads cookies from Kaset app's backup file in Application Support.
/// This allows the standalone tool to make authenticated API requests.
func loadCookiesFromAppBackup() -> [HTTPCookie]? {
    guard !forceUnauthenticatedRequests else {
        return nil
    }

    guard let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first
    else {
        return nil
    }

    let cookieFile =
        appSupport
            .appendingPathComponent("Kaset", isDirectory: true)
            .appendingPathComponent("cookies.dat")

    guard FileManager.default.fileExists(atPath: cookieFile.path) else {
        return nil
    }

    guard let data = try? Data(contentsOf: cookieFile) else {
        print("⚠️ Cookie file exists but failed to read: \(cookieFile.path)")
        return nil
    }

    guard let cookieDataArray = try? NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [NSArray.self, NSData.self],
        from: data
    ) as? [Data]
    else {
        print(
            "⚠️ Cookie file exists but failed to unarchive. File may be corrupted or use a different format."
        )
        print("   Path: \(cookieFile.path)")
        print("   Size: \(data.count) bytes")
        return nil
    }

    let cookies = cookieDataArray.compactMap { cookieData -> HTTPCookie? in
        guard let stringProperties = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSString.self, NSDate.self, NSNumber.self],
            from: cookieData
        ) as? [String: Any]
        else {
            return nil
        }

        var convertedProperties: [HTTPCookiePropertyKey: Any] = [:]
        for (key, value) in stringProperties {
            convertedProperties[HTTPCookiePropertyKey(key)] = value
        }
        return HTTPCookie(properties: convertedProperties)
    }

    return cookies.isEmpty ? nil : cookies
}

/// Filters cookies to those that match the active API host
/// (music.youtube.com or www.youtube.com depending on --youtube).
/// Cookies with domain `.youtube.com` match either host via subdomain matching.
func filterCookiesForAPIHost(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
    let host = activeAPIHost
    return cookies.filter { cookie in
        let domain = cookie.domain.lowercased()
        // Cookies with leading dot match subdomains (e.g., ".youtube.com" matches "music.youtube.com")
        if domain.hasPrefix(".") {
            let withoutDot = String(domain.dropFirst())
            return host.hasSuffix(withoutDot) || withoutDot == host
        }
        // Exact match or subdomain
        return domain == host || host.hasSuffix("." + domain)
    }
}

/// Gets the SAPISID value from cookies for authentication.
/// Prefers .youtube.com domain cookies over .google.com for youtube.com requests.
func getSAPISID(from cookies: [HTTPCookie]) -> String? {
    // Filter to youtube.com domain cookies first (better match for the API host)
    let ytCookies = filterCookiesForAPIHost(cookies)
    let secureCookie = ytCookies.first { $0.name == "__Secure-3PAPISID" }
    let fallbackCookie = ytCookies.first { $0.name == "SAPISID" }
    return (secureCookie ?? fallbackCookie)?.value
}

/// Builds a cookie header string using HTTPCookie's built-in method.
/// This ensures proper cookie formatting that matches what browsers send.
func buildCookieHeader(from cookies: [HTTPCookie]) -> String? {
    // Filter to only cookies that match the active API host
    let matchingCookies = filterCookiesForAPIHost(cookies)
    guard !matchingCookies.isEmpty else { return nil }

    // Use HTTPCookie's built-in method for proper formatting
    let headerFields = HTTPCookie.requestHeaderFields(with: matchingCookies)
    return headerFields["Cookie"]
}

/// Computes SAPISIDHASH for YouTube API authentication.
func computeSAPISIDHASH(sapisid: String) -> String {
    let timestamp = Int(Date().timeIntervalSince1970)
    let input = "\(timestamp) \(sapisid) \(activeOrigin)"

    let data = Data(input.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    data.withUnsafeBytes { buffer in
        _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &hash)
    }
    let hashHex = hash.map { String(format: "%02x", $0) }.joined()

    return "\(timestamp)_\(hashHex)"
}

// MARK: - API Key Resolution

func resolveAPIKey() async throws -> String {
    if let cachedAPIKey {
        return cachedAPIKey
    }

    if let override = ProcessInfo.processInfo.environment[apiKeyEnvironmentVariable],
       !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedAPIKey = trimmed
        return trimmed
    }

    var request = URLRequest(url: activeWebClientURL)
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )
    let (data, response) = try await URLSession.shared.data(for: request)
    if let httpResponse = response as? HTTPURLResponse,
       !(200 ... 399).contains(httpResponse.statusCode)
    {
        throw NSError(
            domain: "APIExplorer",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Could not load YouTube Music web client configuration"]
        )
    }

    guard let html = String(data: data, encoding: .utf8),
          let key = extractInnertubeAPIKey(from: html)
    else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Could not resolve YouTube Music API configuration"]
        )
    }

    // Opportunistically capture the live client version so requests
    // match what the web client currently sends.
    if let version = extractInnertubeClientVersion(from: html) {
        cachedClientVersion = version
    }

    cachedAPIKey = key
    return key
}

func extractInnertubeAPIKey(from html: String) -> String? {
    extractConfigValue(named: "INNERTUBE_API_KEY", from: html)
}

func extractInnertubeClientVersion(from html: String) -> String? {
    extractConfigValue(named: "INNERTUBE_CLIENT_VERSION", from: html)
        ?? extractConfigValue(named: "INNERTUBE_CONTEXT_CLIENT_VERSION", from: html)
}

func extractConfigValue(named name: String, from html: String) -> String? {
    let pattern = "\"\(name)\"\\s*:\\s*\"([^\"]+)\""
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
              in: html,
              range: NSRange(html.startIndex ..< html.endIndex, in: html)
          ),
          let range = Range(match.range(at: 1), in: html)
    else {
        return nil
    }
    return String(html[range])
}

// MARK: - Request Builder

func buildContext(brandAccountId: String? = nil) -> [String: Any] {
    var userDict: [String: Any] = [
        "lockedSafetyMode": false,
    ]

    // Add brand account ID if specified.
    // Diagnostic decoupling: set KASET_PROBE_NO_OBOU=1 to omit the body
    // `onBehalfOfUser` field so brand identity can be probed via the
    // `X-Goog-PageId` header ALONE (matching yt-dlp's header-only wire format),
    // isolating whether body-identity is what playback endpoints reject.
    if let brandId = brandAccountId ?? globalBrandAccountId,
       ProcessInfo.processInfo.environment["KASET_PROBE_NO_OBOU"] != "1"
    {
        userDict["onBehalfOfUser"] = brandId
    }

    return [
        "client": [
            "clientName": activeClientName,
            "clientVersion": cachedClientVersion ?? activeFallbackClientVersion,
            "hl": "en",
            "gl": "US",
            "browserName": "Safari",
            "browserVersion": "17.0",
            "osName": "Macintosh",
            "osVersion": "10_15_7",
            "platform": "DESKTOP",
        ],
        "user": userDict,
    ]
}

func buildHeaders(authenticated: Bool = false, authUserIndex: Int? = nil) -> [String: String] {
    var headers: [String: String] = [
        "Content-Type": "application/json",
        "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Origin": activeOrigin,
        "Referer": "\(activeOrigin)/",
    ]

    if authenticated, let cookies = loadCookiesFromAppBackup() {
        if let sapisid = getSAPISID(from: cookies),
           let cookieHeader = buildCookieHeader(from: cookies)
        {
            let sapisidhash = computeSAPISIDHASH(sapisid: sapisid)
            headers["Cookie"] = cookieHeader
            headers["Authorization"] = "SAPISIDHASH \(sapisidhash)"
            headers["X-Goog-AuthUser"] = "\(authUserIndex ?? globalAuthUserIndex)"
            headers["X-Origin"] = activeOrigin
            // Brand/delegated channel selection on the wire: real-world clients
            // (yt-dlp, YouTube.js, playlet) send the brand pageId as an
            // `X-Goog-PageId` header in addition to `context.user.onBehalfOfUser`.
            // Some endpoints (notably `player`) reject body-only brand identity, so
            // expose the header here to probe brand attribution accurately.
            if let brandId = globalBrandAccountId {
                headers["X-Goog-PageId"] = brandId
            }
        }
    }

    return headers
}

// MARK: - API Request

func makeRequest(endpoint: String, body: [String: Any], authenticated: Bool = false) async throws
    -> (data: [String: Any], statusCode: Int)
{
    let apiKey = try await resolveAPIKey()
    var components = URLComponents(string: "\(activeBaseURL)/\(endpoint)")
    components?.queryItems = [
        URLQueryItem(name: "key", value: apiKey),
        URLQueryItem(name: "prettyPrint", value: "false"),
    ]
    guard let url = components?.url else {
        throw NSError(
            domain: "APIExplorer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]
        )
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    for (key, value) in buildHeaders(authenticated: authenticated) {
        request.setValue(value, forHTTPHeaderField: key)
    }

    var fullBody = body
    fullBody["context"] = buildContext()
    request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(
            domain: "APIExplorer", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
        )
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(
            domain: "APIExplorer", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"]
        )
    }

    return (json, httpResponse.statusCode)
}

// MARK: - Response Analysis

private func joinedRunsText(_ data: [String: Any]?) -> String? {
    guard let data,
          let runs = data["runs"] as? [[String: Any]]
    else {
        return nil
    }

    let text = runs.compactMap { $0["text"] as? String }.joined()
    return text.isEmpty ? nil : text
}

private func findFirstRenderer(named key: String, in value: Any) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
        if let renderer = dictionary[key] as? [String: Any] {
            return renderer
        }

        for nestedValue in dictionary.values {
            if let renderer = findFirstRenderer(named: key, in: nestedValue) {
                return renderer
            }
        }
    } else if let array = value as? [Any] {
        for item in array {
            if let renderer = findFirstRenderer(named: key, in: item) {
                return renderer
            }
        }
    }

    return nil
}

private func extractPlaylistTrackCount(from text: String) -> Int? {
    guard let regex = try? NSRegularExpression(
        pattern: #"([\d,]+)\s+(?:songs?|tracks?)"#,
        options: .caseInsensitive
    ),
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let countRange = Range(match.range(at: 1), in: text)
    else {
        return nil
    }

    return Int(text[countRange].replacingOccurrences(of: ",", with: ""))
}

private func playlistBrowseSummary(_ data: [String: Any]) -> String? {
    guard let shelfRenderer = findFirstRenderer(named: "musicPlaylistShelfRenderer", in: data)
    else {
        return nil
    }

    let shelfContents = shelfRenderer["contents"] as? [[String: Any]] ?? []
    let initialTrackCount = shelfContents.reduce(into: 0) { partialResult, item in
        if item["musicResponsiveListItemRenderer"] != nil {
            partialResult += 1
        }
    }
    let hasContinuation =
        ((shelfRenderer["continuations"] as? [[String: Any]])?.isEmpty == false)
            || (shelfContents.last?["continuationItemRenderer"] != nil)

    let responsiveHeader = findFirstRenderer(named: "musicResponsiveHeaderRenderer", in: data)
    let detailHeader = findFirstRenderer(named: "musicDetailHeaderRenderer", in: data)
    let title =
        joinedRunsText(responsiveHeader?["title"] as? [String: Any])
            ?? joinedRunsText(detailHeader?["title"] as? [String: Any])
    let author: String? = {
        guard let facepile = responsiveHeader?["facepile"] as? [String: Any],
              let avatarStackViewModel = facepile["avatarStackViewModel"] as? [String: Any],
              let text = avatarStackViewModel["text"] as? [String: Any],
              let content = text["content"] as? String,
              !content.isEmpty
        else {
            return nil
        }

        return content
    }()
    let totalTrackCount =
        joinedRunsText(responsiveHeader?["secondSubtitle"] as? [String: Any]).flatMap(
            extractPlaylistTrackCount(from:)
        )
        ?? joinedRunsText(detailHeader?["secondSubtitle"] as? [String: Any]).flatMap(
            extractPlaylistTrackCount(from:)
        )

    var output = "\n🎵 Playlist summary:\n"
    if let title {
        output += "  • Title: \(title)\n"
    }
    if let author {
        output += "  • Author: \(author)\n"
    }
    if let totalTrackCount {
        output += "  • Reported total tracks: \(totalTrackCount.formatted())\n"
    }
    output += "  • Initial track rows: \(initialTrackCount)\n"
    output += "  • Has continuation: \(hasContinuation ? "yes" : "no")\n"

    return output
}

/// Recursively counts renderer/viewModel dictionary keys in a response.
/// Invaluable for mapping which renderers a YouTube surface currently serves
/// (e.g. legacy `videoRenderer` vs. the newer `lockupViewModel`).
private func countRenderers(in value: Any, counts: inout [String: Int]) {
    if let dictionary = value as? [String: Any] {
        for (key, nestedValue) in dictionary {
            if key.hasSuffix("Renderer") || key.hasSuffix("ViewModel") {
                counts[key, default: 0] += 1
            }
            countRenderers(in: nestedValue, counts: &counts)
        }
    } else if let array = value as? [Any] {
        for item in array {
            countRenderers(in: item, counts: &counts)
        }
    }
}

func rendererHistogram(_ data: [String: Any], limit: Int = 25) -> String {
    var counts: [String: Int] = [:]
    countRenderers(in: data, counts: &counts)
    guard !counts.isEmpty else { return "" }

    let sorted = counts.sorted { lhs, rhs in
        lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
    }

    var output = "\n📊 Renderer histogram (top \(min(limit, sorted.count)) of \(sorted.count)):\n"
    for (key, count) in sorted.prefix(limit) {
        output += "  \(String(format: "%4d", count))× \(key)\n"
    }
    return output
}

// MARK: - PlaylistSetVideoIdSourceCounts

private struct PlaylistSetVideoIdSourceCounts {
    var playlistItemData = 0
    var playlistEditEndpoint = 0
}

private func countPlaylistSetVideoIdSources(in value: Any, counts: inout PlaylistSetVideoIdSourceCounts) {
    if let dictionary = value as? [String: Any] {
        if let playlistItemData = dictionary["playlistItemData"] as? [String: Any],
           let setVideoId = playlistItemData["playlistSetVideoId"] as? String,
           !setVideoId.isEmpty
        {
            counts.playlistItemData += 1
        }

        if let editEndpoint = dictionary["playlistEditEndpoint"] as? [String: Any],
           let actions = editEndpoint["actions"] as? [[String: Any]]
        {
            counts.playlistEditEndpoint += actions.count { action in
                action["action"] as? String == "ACTION_REMOVE_VIDEO"
                    && (action["setVideoId"] as? String)?.isEmpty == false
            }
        }

        for nestedValue in dictionary.values {
            countPlaylistSetVideoIdSources(in: nestedValue, counts: &counts)
        }
    } else if let array = value as? [Any] {
        for item in array {
            countPlaylistSetVideoIdSources(in: item, counts: &counts)
        }
    }
}

private func playlistSetVideoIdSourceSummary(_ data: [String: Any]) -> String {
    var counts = PlaylistSetVideoIdSourceCounts()
    countPlaylistSetVideoIdSources(in: data, counts: &counts)
    guard counts.playlistItemData > 0 || counts.playlistEditEndpoint > 0 else { return "" }

    return """

    🧩 Playlist occurrence ID sources:
      • playlistItemData.playlistSetVideoId: \(counts.playlistItemData)
      • playlistEditEndpoint ACTION_REMOVE_VIDEO setVideoId: \(counts.playlistEditEndpoint)
    """
}

// MARK: - ChapterProbeItem

private struct ChapterProbeItem: Hashable {
    let videoId: String?
    let title: String
    let startMillis: Int?
    let endMillis: Int?
    let timeText: String?
    let hasThumbnail: Bool
}

private func textValue(from value: Any?) -> String? {
    if let string = value as? String {
        return string.isEmpty ? nil : string
    }

    guard let dictionary = value as? [String: Any] else {
        return nil
    }

    if let simpleText = dictionary["simpleText"] as? String, !simpleText.isEmpty {
        return simpleText
    }

    if let content = dictionary["content"] as? String, !content.isEmpty {
        return content
    }

    if let runs = dictionary["runs"] as? [[String: Any]] {
        let text = runs.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    return nil
}

private func intValue(from value: Any?) -> Int? {
    switch value {
    case let int as Int:
        int
    case let double as Double:
        Int(double)
    case let number as NSNumber:
        Int(number.int64Value)
    case let string as String:
        Int(string)
    default:
        nil
    }
}

private func formatMillis(_ millis: Int?) -> String {
    guard let millis else { return "?:??" }

    let totalSeconds = max(0, millis / 1000)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

private func findRepeatChapterCommand(in value: Any?) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
        if let command = dictionary["repeatChapterCommand"] as? [String: Any] {
            return command
        }

        for nestedValue in dictionary.values {
            if let command = findRepeatChapterCommand(in: nestedValue) {
                return command
            }
        }
    } else if let array = value as? [Any] {
        for item in array {
            if let command = findRepeatChapterCommand(in: item) {
                return command
            }
        }
    }

    return nil
}

private func watchEndpoint(from renderer: [String: Any]) -> [String: Any]? {
    guard let onTap = renderer["onTap"] as? [String: Any],
          let watchEndpoint = onTap["watchEndpoint"] as? [String: Any]
    else {
        return nil
    }

    return watchEndpoint
}

private func chapterProbeItem(fromChapterRenderer renderer: [String: Any]) -> ChapterProbeItem? {
    guard let title = textValue(from: renderer["title"]) else {
        return nil
    }

    return ChapterProbeItem(
        videoId: nil,
        title: title,
        startMillis: intValue(from: renderer["timeRangeStartMillis"]),
        endMillis: nil,
        timeText: nil,
        hasThumbnail: renderer["thumbnail"] != nil
    )
}

private func chapterProbeItem(fromMacroMarkerRenderer renderer: [String: Any]) -> ChapterProbeItem? {
    guard let title = textValue(from: renderer["title"]) else {
        return nil
    }

    let repeatCommand = findRepeatChapterCommand(in: renderer["repeatButton"])
    let endpoint = watchEndpoint(from: renderer)
    let startMillis = intValue(from: repeatCommand?["startTimeMs"])
        ?? intValue(from: endpoint?["startTimeSeconds"]).map { $0 * 1000 }

    return ChapterProbeItem(
        videoId: endpoint?["videoId"] as? String,
        title: title,
        startMillis: startMillis,
        endMillis: intValue(from: repeatCommand?["endTimeMs"]),
        timeText: textValue(from: renderer["timeDescription"]),
        hasThumbnail: renderer["thumbnail"] != nil
    )
}

private func collectChapterProbeItems(
    in value: Any,
    chapterRenderers: inout [ChapterProbeItem],
    macroMarkerItems: inout [ChapterProbeItem]
) {
    if let dictionary = value as? [String: Any] {
        if let renderer = dictionary["chapterRenderer"] as? [String: Any],
           let item = chapterProbeItem(fromChapterRenderer: renderer)
        {
            chapterRenderers.append(item)
        }

        if let renderer = dictionary["macroMarkersListItemRenderer"] as? [String: Any],
           let item = chapterProbeItem(fromMacroMarkerRenderer: renderer)
        {
            macroMarkerItems.append(item)
        }

        for nestedValue in dictionary.values {
            collectChapterProbeItems(
                in: nestedValue,
                chapterRenderers: &chapterRenderers,
                macroMarkerItems: &macroMarkerItems
            )
        }
    } else if let array = value as? [Any] {
        for item in array {
            collectChapterProbeItems(
                in: item,
                chapterRenderers: &chapterRenderers,
                macroMarkerItems: &macroMarkerItems
            )
        }
    }
}

private func deduplicatedChapterItems(_ items: [ChapterProbeItem]) -> [ChapterProbeItem] {
    var seen: Set<String> = []
    var result: [ChapterProbeItem] = []

    for item in items {
        let key = "\(item.videoId ?? "")|\(item.startMillis ?? -1)|\(item.title)"
        guard seen.insert(key).inserted else { continue }
        result.append(item)
    }

    return result.sorted { lhs, rhs in
        switch (lhs.startMillis, rhs.startMillis) {
        case let (left?, right?):
            if left != right {
                return left < right
            }
            return lhs.title < rhs.title
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return lhs.title < rhs.title
        }
    }
}

private func chapterProbeSummary(_ data: [String: Any], limit: Int = 8) -> String {
    var chapterRenderers: [ChapterProbeItem] = []
    var macroMarkerItems: [ChapterProbeItem] = []
    collectChapterProbeItems(
        in: data,
        chapterRenderers: &chapterRenderers,
        macroMarkerItems: &macroMarkerItems
    )

    let uniqueChapterRenderers = deduplicatedChapterItems(chapterRenderers)
    let uniqueMacroMarkerItems = deduplicatedChapterItems(macroMarkerItems)
    guard !uniqueChapterRenderers.isEmpty || !uniqueMacroMarkerItems.isEmpty else {
        return ""
    }

    var output = "\n🎬 Chapter markers:\n"
    if !uniqueChapterRenderers.isEmpty {
        output += "  • playerOverlays chapterRenderer: \(uniqueChapterRenderers.count) unique chapter(s)"
        if chapterRenderers.count != uniqueChapterRenderers.count {
            output += " (\(chapterRenderers.count) raw)"
        }
        output += "\n"
        output += "    Path: playerOverlays…multiMarkersPlayerBarRenderer.markersMap[].value.chapters[]\n"
    }

    if !uniqueMacroMarkerItems.isEmpty {
        output += "  • macroMarkersListItemRenderer: \(uniqueMacroMarkerItems.count) unique chapter(s)"
        if macroMarkerItems.count != uniqueMacroMarkerItems.count {
            output += " (\(macroMarkerItems.count) raw; often duplicated in chapters panel + structured description/search preview)"
        }
        output += "\n"
    }

    let preferredItems = uniqueChapterRenderers.isEmpty ? uniqueMacroMarkerItems : uniqueChapterRenderers
    let multipleVideoIds = Set(preferredItems.compactMap(\.videoId)).count > 1
    for (index, item) in preferredItems.prefix(limit).enumerated() {
        let start = item.timeText ?? formatMillis(item.startMillis)
        let endSuffix = item.endMillis.map { "–\(formatMillis($0))" } ?? ""
        let thumbnailSuffix = item.hasThumbnail ? " · thumbnail" : ""
        let videoSuffix = multipleVideoIds ? " · videoId \(item.videoId ?? "unknown")" : ""
        output += "    \(index + 1). \(start)\(endSuffix) — \(item.title)\(thumbnailSuffix)\(videoSuffix)\n"
    }
    if preferredItems.count > limit {
        output += "    … and \(preferredItems.count - limit) more\n"
    }

    return output
}

// MARK: - LibraryFeedbackProbeItem

private struct LibraryFeedbackProbeItem: Hashable {
    enum Kind: String {
        case single
        case toggle
    }

    let kind: Kind
    let iconType: String
    let hasPrimaryToken: Bool
    let hasToggledToken: Bool
    let tokensAreDistinct: Bool?
}

private func firstFeedbackToken(in value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
        if let token = dictionary["feedbackToken"] as? String, !token.isEmpty {
            return token
        }
        for nestedValue in dictionary.values {
            if let token = firstFeedbackToken(in: nestedValue) {
                return token
            }
        }
    } else if let array = value as? [Any] {
        for item in array {
            if let token = firstFeedbackToken(in: item) {
                return token
            }
        }
    }
    return nil
}

private func isLibraryFeedbackIcon(_ iconType: String) -> Bool {
    iconType.contains("LIBRARY") || iconType.contains("BOOKMARK")
}

private func collectLibraryFeedbackProbeItems(
    in value: Any,
    items: inout [LibraryFeedbackProbeItem]
) {
    if let dictionary = value as? [String: Any] {
        if let renderer = dictionary["menuServiceItemRenderer"] as? [String: Any] {
            let token = firstFeedbackToken(in: renderer["serviceEndpoint"] as Any)
            if token != nil {
                let icon = renderer["icon"] as? [String: Any]
                let iconType = icon?["iconType"] as? String ?? "unknown"
                if isLibraryFeedbackIcon(iconType) {
                    items.append(LibraryFeedbackProbeItem(
                        kind: .single,
                        iconType: iconType,
                        hasPrimaryToken: true,
                        hasToggledToken: false,
                        tokensAreDistinct: nil
                    ))
                }
            }
        }

        if let renderer = dictionary["toggleMenuServiceItemRenderer"] as? [String: Any] {
            let defaultToken = firstFeedbackToken(in: renderer["defaultServiceEndpoint"] as Any)
            let toggledToken = firstFeedbackToken(in: renderer["toggledServiceEndpoint"] as Any)
            guard defaultToken != nil || toggledToken != nil else {
                for nestedValue in dictionary.values {
                    collectLibraryFeedbackProbeItems(in: nestedValue, items: &items)
                }
                return
            }
            let icon = renderer["defaultIcon"] as? [String: Any]
            let iconType = icon?["iconType"] as? String ?? "unknown"
            if isLibraryFeedbackIcon(iconType) {
                let tokensAreDistinct: Bool? = if let defaultToken, let toggledToken {
                    defaultToken != toggledToken
                } else {
                    nil
                }
                items.append(LibraryFeedbackProbeItem(
                    kind: .toggle,
                    iconType: iconType,
                    hasPrimaryToken: defaultToken != nil,
                    hasToggledToken: toggledToken != nil,
                    tokensAreDistinct: tokensAreDistinct
                ))
            }
        }

        for nestedValue in dictionary.values {
            collectLibraryFeedbackProbeItems(in: nestedValue, items: &items)
        }
    } else if let array = value as? [Any] {
        for item in array {
            collectLibraryFeedbackProbeItems(in: item, items: &items)
        }
    }
}

private func libraryFeedbackProbeSummary(_ data: [String: Any]) -> String {
    var items: [LibraryFeedbackProbeItem] = []
    collectLibraryFeedbackProbeItems(in: data, items: &items)
    guard !items.isEmpty else { return "" }

    let grouped = Dictionary(grouping: items, by: \.self)
    var output = "\n📚 Library feedback actions (token values redacted):\n"
    for item in grouped.keys.sorted(by: {
        ($0.kind.rawValue, $0.iconType) < ($1.kind.rawValue, $1.iconType)
    }) {
        let count = grouped[item]?.count ?? 0
        switch item.kind {
        case .single:
            output += "  • single icon=\(item.iconType) token=\(item.hasPrimaryToken ? "present" : "missing") count=\(count)\n"
        case .toggle:
            let distinct = item.tokensAreDistinct.map { $0 ? "yes" : "no" } ?? "unknown"
            output += "  • toggle defaultIcon=\(item.iconType) defaultToken=\(item.hasPrimaryToken ? "present" : "missing") toggledToken=\(item.hasToggledToken ? "present" : "missing") distinct=\(distinct) count=\(count)\n"
        }
    }
    return output
}

func analyzeResponse(_ data: [String: Any], verbose: Bool = false) -> String {
    var output = ""

    // Top-level keys
    let keys = Array(data.keys).sorted()
    output += "📋 Top-level keys (\(keys.count)): \(keys.joined(separator: ", "))\n"

    // Check for error
    if let error = data["error"] as? [String: Any] {
        let code = error["code"] ?? "unknown"
        let message = error["message"] ?? "Unknown error"
        output += "❌ Error: \(code) - \(message)\n"
        return output
    }

    // Navigate to contents if present
    if let contents = data["contents"] as? [String: Any] {
        output += "\n📦 Contents structure:\n"
        for (key, value) in contents.sorted(by: { $0.key < $1.key }) {
            if let dict = value as? [String: Any] {
                output += "  • \(key): {\(dict.keys.sorted().joined(separator: ", "))}\n"
            } else if let array = value as? [Any] {
                output += "  • \(key): [\(array.count) items]\n"
            } else {
                output += "  • \(key): \(type(of: value))\n"
            }
        }

        // Try to find sections
        if let singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
           let tabs = singleColumn["tabs"] as? [[String: Any]]
        {
            output += "\n📑 Found \(tabs.count) tab(s)\n"

            for (index, tab) in tabs.enumerated() {
                if let tabRenderer = tab["tabRenderer"] as? [String: Any],
                   let title = tabRenderer["title"] as? String
                {
                    output += "  Tab \(index): \"\(title)\"\n"

                    if let content = tabRenderer["content"] as? [String: Any],
                       let sectionList = content["sectionListRenderer"] as? [String: Any],
                       let sections = sectionList["contents"] as? [[String: Any]]
                    {
                        output += "    Sections: \(sections.count)\n"

                        for (sIndex, section) in sections.prefix(10).enumerated() {
                            let sectionType = section.keys.first ?? "unknown"
                            output += "    [\(sIndex)] \(sectionType)\n"

                            if verbose, let renderer = section[sectionType] as? [String: Any] {
                                // Try to get title
                                if let header = renderer["header"] as? [String: Any] {
                                    for (_, hValue) in header {
                                        if let hDict = hValue as? [String: Any],
                                           let title = hDict["title"] as? [String: Any],
                                           let runs = title["runs"] as? [[String: Any]],
                                           let text = runs.first?["text"] as? String
                                        {
                                            output += "        Title: \"\(text)\"\n"
                                        }
                                    }
                                }
                            }
                        }

                        if sections.count > 10 {
                            output += "    ... and \(sections.count - 10) more sections\n"
                        }
                    }
                }
            }
        }
    }

    // Check for header
    if let header = data["header"] as? [String: Any] {
        output += "\n🏷️ Header keys: \(header.keys.sorted().joined(separator: ", "))\n"
    }

    if let playlistSummary = playlistBrowseSummary(data) {
        output += playlistSummary
    }

    output += playlistSetVideoIdSourceSummary(data)

    output += chapterProbeSummary(data)

    output += libraryFeedbackProbeSummary(data)

    output += rendererHistogram(data)

    return output
}

// MARK: - Commands

/// Known endpoints that require authentication
let authRequiredEndpoints = Set([
    "FEmusic_liked_playlists",
    "FEmusic_liked_videos",
    "FEmusic_history",
    "FEmusic_library_landing",
    "FEmusic_library_albums",
    "FEmusic_library_artists",
    "FEmusic_library_corpus_artists",
    "FEmusic_library_corpus_track_artists",
    "FEmusic_library_songs",
    "FEmusic_library_non_music_audio_list",
    "FEmusic_recently_played",
    "FEmusic_offline",
    "FEmusic_library_privately_owned_landing",
    "FEmusic_library_privately_owned_tracks",
    "FEmusic_library_privately_owned_albums",
    "FEmusic_library_privately_owned_artists",
])

/// Known YouTube (www.youtube.com, WEB client) browse endpoints that require authentication.
let youtubeAuthRequiredEndpoints = Set([
    "FEsubscriptions",
    "FElibrary",
    "FEhistory",
    "FEplaylist_aggregation",
])

/// Checks if a browseId requires authentication.
/// This includes known endpoints plus dynamic browseId prefixes that are sign-in backed.
func needsAuthentication(_ browseId: String) -> Bool {
    if youtubeMode {
        if youtubeAuthRequiredEndpoints.contains(browseId) || browseId == "VLWL"
            || browseId == "VLLL"
        {
            return true
        }
        // Personalized surfaces (home feed, etc.) return richer data signed in,
        // so use auth whenever cookies are available.
        return loadCookiesFromAppBackup() != nil
    }
    if authRequiredEndpoints.contains(browseId) {
        return true
    }
    // Library artists (MPLAUC...) come from signed-in library responses
    // and return 401 when browsed directly without auth.
    if browseId.hasPrefix("MPLAUC") {
        return true
    }
    // Playlists (VL...) benefit from authentication for personalized content
    if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
        return loadCookiesFromAppBackup() != nil // Use auth if available
    }
    // Podcast shows (MPSPP...) require authentication for episode data
    if browseId.hasPrefix("MPSPP") {
        return true
    }
    return false
}

func exploreBrowse(
    _ browseId: String, params: String? = nil, verbose: Bool = false, outputFile: String? = nil
) async {
    let needsAuth = needsAuthentication(browseId)
    let authIcon = needsAuth ? "🔐" : "🌐"

    print("\(authIcon) Exploring browse endpoint: \(browseId)")
    if let params {
        print("   Params: \(params)")
    }
    if needsAuth {
        let hasAuth = loadCookiesFromAppBackup() != nil
        print("   Auth required: \(hasAuth ? "✅ cookies available" : "❌ no cookies found")")
    }
    print()

    var body: [String: Any] = ["browseId": browseId]
    if let params {
        body["params"] = params
    }

    do {
        let (data, statusCode) = try await makeRequest(
            endpoint: "browse", body: body, authenticated: needsAuth
        )

        if statusCode == 401 || statusCode == 403 {
            print("❌ HTTP \(statusCode) - Authentication required")
            print("   Run the Kaset app and sign in, then try again.")
            return
        }

        print("✅ HTTP \(statusCode)")
        print()
        print(analyzeResponse(data, verbose: verbose))

        if verbose {
            print("\n📄 Raw response (pretty-printed):")
            if let prettyData = try? JSONSerialization.data(
                withJSONObject: data, options: .prettyPrinted
            ),
                let prettyString = String(data: prettyData, encoding: .utf8)
            {
                print(prettyString)
            }
        }

        if let outputFile {
            if let prettyData = try? JSONSerialization.data(
                withJSONObject: data, options: .prettyPrinted
            ) {
                let url = URL(fileURLWithPath: outputFile)
                try prettyData.write(to: url)
                print("\n💾 Saved to: \(outputFile)")
            }
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

/// Known action endpoints that require authentication
/// Known action endpoints that require authentication.
/// Note: music/get_queue works without auth but returns richer data with auth.
let authRequiredActions = Set([
    "like/like",
    "like/dislike",
    "like/removelike",
    "feedback",
    "subscription/subscribe",
    "subscription/unsubscribe",
    "playlist/get_add_to_playlist",
    "browse/edit_playlist",
    "playlist/create",
    "playlist/delete",
    "account/account_menu",
    "account/accounts_list",
    "notification/get_notification_menu",
    "stats/watchtime",
    "next",
])

func exploreAction(
    _ endpoint: String, bodyJson: String, verbose: Bool = false, outputFile: String? = nil
) async {
    // In YouTube mode, personalized actions (guide, next, search) return richer
    // data signed in, so use auth whenever cookies are available.
    let needsAuth = authRequiredActions.contains(endpoint)
        || (youtubeMode && loadCookiesFromAppBackup() != nil)
    let authIcon = needsAuth ? "🔐" : "🌐"

    print("\(authIcon) Exploring action endpoint: \(endpoint)")
    if needsAuth {
        let hasAuth = loadCookiesFromAppBackup() != nil
        print("   Auth required: \(hasAuth ? "✅ cookies available" : "❌ no cookies found")")
    }
    print()

    guard let bodyData = bodyJson.data(using: .utf8),
          let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    else {
        print("❌ Invalid JSON body: \(bodyJson)")
        return
    }

    do {
        let (data, statusCode) = try await makeRequest(
            endpoint: endpoint, body: body, authenticated: needsAuth
        )

        if statusCode == 401 || statusCode == 403 {
            print("❌ HTTP \(statusCode) - Authentication required")
            print("   Run the Kaset app and sign in, then try again.")
            return
        }

        print("✅ HTTP \(statusCode)")
        print()
        print(analyzeResponse(data, verbose: verbose))

        if verbose {
            print("\n📄 Raw response (pretty-printed):")
            if let prettyData = try? JSONSerialization.data(
                withJSONObject: data, options: .prettyPrinted
            ),
                let prettyString = String(data: prettyData, encoding: .utf8)
            {
                print(prettyString)
            }
        }

        if let outputFile {
            if let prettyData = try? JSONSerialization.data(
                withJSONObject: data, options: .prettyPrinted
            ) {
                let url = URL(fileURLWithPath: outputFile)
                try prettyData.write(to: url)
                print("\n💾 Saved to: \(outputFile)")
            }
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

/// Explores a continuation request to fetch more items.
/// - Parameters:
///   - token: The continuation token
///   - endpoint: The endpoint to use ("browse" for home/library, "next" for mix queues)
func exploreContinuation(
    _ token: String, endpoint: String = "browse", verbose: Bool = false, outputFile: String? = nil
) async {
    print("🔄 Exploring continuation request")
    print("   Token: \(token.prefix(50))...")
    print("   Endpoint: \(endpoint)")
    print()

    var body: [String: Any] = ["continuation": token]

    // For "next" endpoint continuations (mix queues), add required parameters
    if endpoint == "next" {
        body["enablePersistentPlaylistPanel"] = true
        body["isAudioOnly"] = true
    }

    do {
        // Always authenticate for continuations
        let (data, statusCode) = try await makeRequest(
            endpoint: endpoint, body: body, authenticated: true
        )

        if statusCode == 401 || statusCode == 403 {
            print("❌ HTTP \(statusCode) - Authentication required")
            return
        }

        print("✅ HTTP \(statusCode)")
        print()
        print(analyzeResponse(data, verbose: verbose))

        // Analyze continuation-specific structure
        print("\n📊 Continuation Analysis:")
        if let continuationContents = data["continuationContents"] as? [String: Any] {
            print("   Found continuationContents with keys: \(Array(continuationContents.keys))")
            for (key, value) in continuationContents {
                if let renderer = value as? [String: Any] {
                    if let contents = renderer["contents"] as? [[String: Any]] {
                        print("   └─ \(key): \(contents.count) items")

                        // For playlistPanelContinuation (mix queues), show song count
                        if key == "playlistPanelContinuation" {
                            var songCount = 0
                            for item in contents {
                                if item["playlistPanelVideoRenderer"] != nil
                                    || item["playlistPanelVideoWrapperRenderer"] != nil
                                {
                                    songCount += 1
                                }
                            }
                            print("   └─ Songs in continuation: \(songCount)")
                        }
                    }
                    if let continuations = renderer["continuations"] as? [[String: Any]] {
                        print(
                            "   └─ \(key) has 'continuations' array (\(continuations.count) tokens)"
                        )
                        // Check for nextRadioContinuationData (mix queue specific)
                        if let firstCont = continuations.first,
                           firstCont["nextRadioContinuationData"] != nil
                        {
                            print("   └─ Has nextRadioContinuationData (more mix songs available)")
                        }
                    }
                }
            }
        } else if let actions = data["onResponseReceivedActions"] as? [[String: Any]] {
            print("   Found onResponseReceivedActions (2025 format)")
            for (idx, action) in actions.enumerated() {
                print("   └─ Action \(idx) keys: \(Array(action.keys))")
                if let appendAction = action["appendContinuationItemsAction"] as? [String: Any],
                   let items = appendAction["continuationItems"] as? [[String: Any]]
                {
                    print("      └─ continuationItems: \(items.count) items")
                }
            }
        } else {
            print("   ⚠️ No recognized continuation format found")
            print("   Top-level keys: \(Array(data.keys))")
        }

        if verbose {
            print("\n📄 Raw response (pretty-printed):")
            if let prettyData = try? JSONSerialization.data(
                withJSONObject: data, options: .prettyPrinted
            ),
                let prettyString = String(data: prettyData, encoding: .utf8)
            {
                print(prettyString)
            }
        }

        if let outputFile {
            if let prettyData = try? JSONSerialization.data(
                withJSONObject: data, options: .prettyPrinted
            ) {
                let url = URL(fileURLWithPath: outputFile)
                try prettyData.write(to: url)
                print("\n💾 Saved to: \(outputFile)")
            }
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

func checkAuthStatus() {
    print("🔐 Authentication Status")
    print("========================\n")

    guard let cookies = loadCookiesFromAppBackup() else {
        print("❌ No cookies found")
        print()
        print("To enable authenticated API access:")
        print("  1. Run the Kaset app")
        print("  2. Sign in to YouTube Music")
        print("  3. The app will save cookies to ~/Library/Application Support/Kaset/")
        print("  4. Run this tool again")
        return
    }

    let matchingCookies = filterCookiesForAPIHost(cookies)
    print("✅ Found \(cookies.count) cookies in app backup")
    print("✅ \(matchingCookies.count) cookies match \(activeAPIHost) domain\n")

    // Check for key auth cookies (in youtube.com domain)
    let authCookieNames = [
        "SAPISID", "__Secure-3PAPISID", "SID", "HSID", "SSID", "APISID", "__Secure-1PAPISID",
    ]

    print("Auth cookies (youtube.com domain):")
    for name in authCookieNames {
        if let cookie = matchingCookies.first(where: { $0.name == name }) {
            var status = "✅"
            var expiry = ""

            if let date = cookie.expiresDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                expiry = formatter.string(from: date)

                if date < Date() {
                    status = "⚠️ EXPIRED"
                }
            } else if cookie.isSessionOnly {
                expiry = "session-only"
            }

            print("  \(status) \(name): expires \(expiry)")
        } else {
            print("  ❌ \(name): not found")
        }
    }

    print()

    // Check if we can compute SAPISIDHASH
    if getSAPISID(from: cookies) != nil {
        print("✅ Can compute SAPISIDHASH for authenticated requests")
    } else {
        print("❌ Cannot compute SAPISIDHASH - missing SAPISID cookie")
    }
}

// MARK: - Account Discovery

/// Discovers all available accounts (primary + brand accounts) by probing authuser indices
func discoverAccounts(verbose: Bool) async {
    print("🔍 Discovering Accounts")
    print("=======================\n")

    guard loadCookiesFromAppBackup() != nil else {
        print("❌ No cookies found. Please sign in to Kaset first.")
        return
    }

    var accounts: [(index: Int, name: String, handle: String?)] = []
    let maxAttempts = 10 // Probe up to 10 accounts

    for index in 0 ..< maxAttempts {
        if verbose {
            print("  Probing authuser=\(index)...")
        }

        if let accountInfo = await fetchAccountInfo(authUserIndex: index, verbose: verbose) {
            accounts.append((index: index, name: accountInfo.name, handle: accountInfo.handle))
            if verbose {
                print("    ✅ Found: \(accountInfo.name)")
            }
        } else {
            // No more accounts at this index
            if verbose {
                print("    ❌ No account at index \(index)")
            }
            // If we found at least one account, stop after first failure
            // Brand accounts are typically consecutive starting from 0
            if !accounts.isEmpty {
                break
            }
        }
    }

    print()
    if accounts.isEmpty {
        print("❌ No accounts found. Make sure you're signed in.")
    } else {
        print("📋 Found \(accounts.count) account(s):\n")
        for account in accounts {
            let handleStr = account.handle.map { " (\($0))" } ?? ""
            let typeStr = account.index == 0 ? " [Primary]" : " [Brand Account]"
            print("  \(account.index): \(account.name)\(handleStr)\(typeStr)")
        }
        print()
        print("💡 Use --authuser N to make requests as a specific account")
        print("   Example: swift run api-explorer browse FEmusic_liked_playlists --authuser 1")
    }
}

/// Fetches account info for a specific authuser index
private func fetchAccountInfo(authUserIndex: Int, verbose: Bool) async -> (
    name: String, handle: String?
)? {
    guard let apiKey = try? await resolveAPIKey() else {
        return nil
    }
    var components = URLComponents(string: "\(activeBaseURL)/account/account_menu")
    components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
    guard let url = components?.url else {
        return nil
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    let headers = buildHeaders(authenticated: true, authUserIndex: authUserIndex)
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }

    let body: [String: Any] = [
        "context": [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20241127.01.00",
            ],
        ],
    ]

    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        // 401/403 means no account at this index
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            if verbose {
                print("    HTTP \(httpResponse.statusCode)")
            }
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Check if we got an error response
        if json["error"] != nil {
            return nil
        }

        // Extract account name from response
        // Path: actions[0].openPopupAction.popup.multiPageMenuRenderer.header.activeAccountHeaderRenderer.accountName.runs[0].text
        guard let actions = json["actions"] as? [[String: Any]],
              let firstAction = actions.first,
              let openPopupAction = firstAction["openPopupAction"] as? [String: Any],
              let popup = openPopupAction["popup"] as? [String: Any],
              let multiPageMenuRenderer = popup["multiPageMenuRenderer"] as? [String: Any],
              let header = multiPageMenuRenderer["header"] as? [String: Any],
              let activeAccountHeaderRenderer = header["activeAccountHeaderRenderer"]
              as? [String: Any]
        else {
            return nil
        }

        // Extract account name
        var accountName: String?
        if let accountNameObj = activeAccountHeaderRenderer["accountName"] as? [String: Any],
           let runs = accountNameObj["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            accountName = text
        }

        guard let name = accountName, !name.isEmpty else {
            return nil
        }

        // Extract channel handle (optional)
        var channelHandle: String?
        if let channelHandleObj = activeAccountHeaderRenderer["channelHandle"] as? [String: Any],
           let runs = channelHandleObj["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            channelHandle = text
        }

        return (name: name, handle: channelHandle)

    } catch {
        if verbose {
            print("    Error: \(error.localizedDescription)")
        }
        return nil
    }
}

// MARK: - Brand Account Discovery

/// Read-only mechanism pre-check for issue #277 (brand history recording).
/// Follows the brand signin redirect on an EPHEMERAL `URLSession` seeded from
/// the app cookies (the on-disk `cookies.dat` is never modified), then reads the
/// landed page's `DATASYNC_ID`. A first-half that flips to `brandId` proves the
/// signin navigation re-points the session identity at the HTTP/cookie level.
/// Emits no `videostats` pings (no JS), so it cannot prove the history write —
/// that requires the live WebView (Stage 2). Mutates nothing in the app.
func probeSigninSwitch(brandId: String, authUserIndex: Int, nextURLString: String) async {
    print("🔀 signin session-switch pre-check (read-only, ephemeral session)")
    print("================================================================\n")

    guard let nextURL = URL(string: nextURLString) else {
        print("❌ Invalid next URL: [redacted]")
        return
    }
    guard isAllowedYtcfgProbeURL(nextURL) else {
        print("❌ signin probe next URL must be an HTTPS YouTube page (music.youtube.com or www.youtube.com).")
        return
    }
    guard let cookies = loadCookiesFromAppBackup(), !cookies.isEmpty else {
        print("❌ No app cookies found. Sign in to Kaset first.")
        return
    }

    // Build YouTube's own channel-switch endpoint: /signin?...&pageid=<brand>.
    var components = URLComponents(string: "\(activeOrigin)/signin")
    components?.queryItems = [
        URLQueryItem(name: "action_handle_signin", value: "true"),
        URLQueryItem(name: "pageid", value: brandId),
        URLQueryItem(name: "authuser", value: "\(authUserIndex)"),
        URLQueryItem(name: "feature", value: "playlist"),
        URLQueryItem(name: "next", value: nextURL.absoluteString),
    ]
    guard let signinURL = components?.url else {
        print("❌ Could not build signin URL")
        return
    }
    print("Switch endpoint: \(activeOrigin)/signin?...&pageid=\(brandId)&authuser=\(authUserIndex)")
    print("next: \((nextURL.host.map { $0 + nextURL.path }) ?? nextURL.path)\(nextURL.query != nil ? " [query redacted]" : "")\n")

    // Ephemeral session: cookies live only in memory for this probe and are
    // discarded on exit; the app's Keychain/cookies.dat are never written.
    let config = URLSessionConfiguration.ephemeral
    let store = HTTPCookieStorage()
    for cookie in cookies {
        store.setCookie(cookie)
    }
    config.httpCookieStorage = store
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    let session = URLSession(configuration: config)

    var request = URLRequest(url: signinURL)
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )

    do {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let landedURL = response.url?.absoluteString ?? "(unknown)"
        guard let html = String(data: data, encoding: .utf8) else {
            print("❌ HTTP \(status) — could not decode landed page")
            return
        }
        // Report only host+path of the landing URL (query may carry tokens).
        let landedHostPath = URL(string: landedURL).map { ($0.host ?? "") + $0.path } ?? landedURL
        print("✅ HTTP \(status), landed on \(landedHostPath), \(data.count) bytes\n")

        let dataSyncId = extractConfigValue(named: "DATASYNC_ID", from: html)
        guard let ds = dataSyncId else {
            print("DATASYNC_ID: (absent) — likely a consent/login interstitial, not a watch/home page.")
            print("→ INCONCLUSIVE. The live WebView (Stage 2) is the authority; URLSession can hit challenge pages a browser would not.")
            return
        }
        let firstHalf = ds.components(separatedBy: "||").first ?? ""
        let flipped = firstHalf == brandId
        print("DATASYNC_ID first half: \(firstHalf.isEmpty ? "(empty → primary)" : "<\(firstHalf.count) chars>")")
        if flipped {
            print("→ ✅ FLIPPED to brand: the signin navigation re-points session identity at the cookie level.")
            print("   (History WRITE still requires the live WebView's videostats pings — verify in Stage 2.)")
        } else {
            print("→ ❌ NOT flipped (still primary). Either URLSession hit an interstitial, or the switch needs the JS/browser context.")
            print("   This is INFORMATIVE, not disqualifying — Stage 2 (live WebView) is authoritative.")
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
        print("→ INCONCLUSIVE; defer to Stage 2 live-WebView test.")
    }
}

/// Most-faithful read-only variant of `probeSigninSwitch`: follows the EXACT
/// server-issued `accountSigninToken.signinUrl` (preserving every param), only
/// rewriting `next`. Ephemeral session; mutates nothing.
func probeSigninSwitchReal(nextURLString: String) async {
    print("🔀 signin session-switch pre-check — REAL server-issued URL (read-only)")
    print("======================================================================\n")

    guard let nextURL = URL(string: nextURLString) else {
        print("❌ Invalid next URL: [redacted]")
        return
    }
    guard isAllowedYtcfgProbeURL(nextURL) else {
        print("❌ signin probe next URL must be an HTTPS YouTube page (music.youtube.com or www.youtube.com).")
        return
    }
    guard let cookies = loadCookiesFromAppBackup(), !cookies.isEmpty else {
        print("❌ No app cookies found. Sign in to Kaset first.")
        return
    }

    // Fetch accounts_list and extract the brand's real signinUrl + pageId.
    var signinURLString: String?
    var brandId: String?
    do {
        let (data, status) = try await makeRequest(
            endpoint: "account/accounts_list", body: [:], authenticated: true
        )
        guard status == 200 else {
            print("❌ accounts_list HTTP \(status)")
            return
        }
        (signinURLString, brandId) = extractBrandSigninURL(from: data)
    } catch {
        print("❌ accounts_list error: \(error.localizedDescription)")
        return
    }

    guard var signin = signinURLString, let brand = brandId else {
        print("❌ No brand accountSigninToken.signinUrl found (single-account login?).")
        return
    }
    // Normalize protocol-relative URLs.
    if signin.hasPrefix("//") {
        signin = "https:" + signin
    } else if signin.hasPrefix("/") {
        signin = "https://www.youtube.com" + signin
    }

    // Rewrite only the `next` param.
    guard var comps = URLComponents(string: signin) else {
        print("❌ Could not parse signinUrl")
        return
    }
    var items = (comps.queryItems ?? []).filter { $0.name != "next" }
    items.append(URLQueryItem(name: "next", value: nextURL.absoluteString))
    comps.queryItems = items
    guard let finalURL = comps.url else {
        print("❌ Could not rebuild signin URL")
        return
    }
    print("Using server-issued /signin (params: \(items.map(\.name).sorted().joined(separator: ", ")))")
    print("brand pageId: \(brand)")
    print("next: \((nextURL.host.map { $0 + nextURL.path }) ?? nextURL.path)\(nextURL.query != nil ? " [query redacted]" : "")\n")

    let config = URLSessionConfiguration.ephemeral
    let store = HTTPCookieStorage()
    for cookie in cookies {
        store.setCookie(cookie)
    }
    config.httpCookieStorage = store
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    let session = URLSession(configuration: config)

    var request = URLRequest(url: finalURL)
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )

    do {
        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        let landed = response.url.map { ($0.host ?? "") + $0.path } ?? "(unknown)"
        guard let html = String(data: data, encoding: .utf8) else {
            print("❌ HTTP \(httpStatus) — could not decode landed page")
            return
        }
        print("✅ HTTP \(httpStatus), landed on \(landed), \(data.count) bytes\n")
        guard let ds = extractConfigValue(named: "DATASYNC_ID", from: html) else {
            print("DATASYNC_ID: (absent) — interstitial/challenge page. INCONCLUSIVE; Stage 2 (live WebView) is authoritative.")
            return
        }
        let firstHalf = ds.components(separatedBy: "||").first ?? ""
        if firstHalf == brand {
            print("DATASYNC_ID first half == brand pageId → ✅ FLIPPED at the cookie level.")
            print("   (History WRITE still requires the live WebView's videostats pings — Stage 2.)")
        } else {
            print("DATASYNC_ID first half: \(firstHalf.isEmpty ? "(empty → primary)" : "<\(firstHalf.count) chars>") → ❌ not flipped.")
            print("   INFORMATIVE, not disqualifying — URLSession can't run the JS the switch may rely on; Stage 2 decides.")
        }
    } catch {
        print("❌ Error: \(error.localizedDescription) — INCONCLUSIVE; defer to Stage 2.")
    }
}

/// Walks an accounts_list response for the first brand account's
/// `accountSigninToken.signinUrl` and `pageIdToken.pageId`. Read-only.
func extractBrandSigninURL(from data: [String: Any]) -> (String?, String?) {
    var foundSignin: String?
    var foundPageId: String?
    func walk(_ node: Any) {
        if let dict = node as? [String: Any] {
            if let tokens = (dict["selectActiveIdentityEndpoint"] as? [String: Any])?["supportedTokens"] as? [[String: Any]] {
                var sgn: String?
                var pid: String?
                for token in tokens {
                    if let signinToken = token["accountSigninToken"] as? [String: Any],
                       let url = signinToken["signinUrl"] as? String
                    {
                        sgn = url
                    }
                    if let pageToken = token["pageIdToken"] as? [String: Any],
                       let pageId = pageToken["pageId"] as? String
                    {
                        pid = pageId
                    }
                }
                // Only the brand entry has a pageIdToken; prefer that one.
                if let pid, let sgn, foundPageId == nil {
                    foundPageId = pid
                    foundSignin = sgn
                }
            }
            for value in dict.values {
                walk(value)
            }
        } else if let array = node as? [Any] {
            for value in array {
                walk(value)
            }
        }
    }
    walk(data)
    return (foundSignin, foundPageId)
}

/// Read-only identity probe. Fetches an HTTPS YouTube page (with the app's
/// cookies) and reports the session-identity markers embedded in its ytcfg:
/// `DATASYNC_ID` ("<delegatedSessionId>||<userSessionId>"), the derived
/// delegated session id, and `SESSION_INDEX`. Used to verify which account a
/// WebView session would record history to, without mutating anything.
func probeYtcfg(pageURLString: String?, verbose: Bool) async {
    let target = pageURLString ?? "\(activeOrigin)/"
    guard let url = URL(string: target) else {
        print("❌ Invalid URL: [redacted]")
        return
    }
    guard isAllowedYtcfgProbeURL(url) else {
        print("❌ ytcfg probe URL must be an HTTPS YouTube page (music.youtube.com or www.youtube.com).")
        return
    }

    print("🔬 ytcfg identity probe")
    print("=======================\n")
    // Print only host+path, never the query string: a probed /signin (or other
    // auth-bearing) URL can carry credential-bearing query items, and the repo's
    // no-secrets rule forbids writing those to terminal logs.
    let safeTarget = (url.host.map { $0 + url.path }) ?? url.path
    print("GET \(safeTarget)\(url.query != nil ? " [query redacted]" : "")")
    if let brandId = globalBrandAccountId {
        print("(brand override active: X-Goog-PageId / onBehalfOfUser = \(brandId))")
    }
    print("")

    let config = URLSessionConfiguration.ephemeral
    if let cookies = loadCookiesFromAppBackup(), !cookies.isEmpty {
        let store = HTTPCookieStorage()
        for cookie in cookies {
            store.setCookie(cookie)
        }
        config.httpCookieStorage = store
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
    } else {
        print("⚠️  No app cookies found — probing as a signed-out session.\n")
    }
    let session = URLSession(configuration: config)

    var request = URLRequest(url: url)
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )

    do {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let html = String(data: data, encoding: .utf8) else {
            print("❌ HTTP \(status) — could not decode page body")
            return
        }
        print("✅ HTTP \(status), \(data.count) bytes\n")

        let dataSyncId = extractConfigValue(named: "DATASYNC_ID", from: html)
        let delegated = extractConfigValue(named: "DELEGATED_SESSION_ID", from: html)
        let sessionIndex = extractConfigValue(named: "SESSION_INDEX", from: html)
        let loggedIn = extractConfigValue(named: "LOGGED_IN", from: html)

        func redact(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return "(absent/empty)" }
            // Report shape, not the raw token, to avoid leaking identity secrets.
            if let pipe = value.range(of: "||") {
                let first = String(value[value.startIndex ..< pipe.lowerBound])
                let second = String(value[pipe.upperBound...])
                let firstDesc = first.isEmpty ? "(empty)" : "<\(first.count) chars>"
                let secondDesc = second.isEmpty ? "(empty)" : "<\(second.count) chars>"
                return "\(firstDesc)||\(secondDesc)"
            }
            return "<\(value.count) chars>"
        }

        print("DATASYNC_ID:           \(redact(dataSyncId))")
        if let brandId = globalBrandAccountId, let ds = dataSyncId,
           let pipe = ds.range(of: "||")
        {
            let first = String(ds[ds.startIndex ..< pipe.lowerBound])
            let matches = first == brandId
            print("  → first half == requested brand pageId? \(matches ? "✅ YES (brand session)" : "❌ NO (still primary)")")
        }
        print("DELEGATED_SESSION_ID:  \(redact(delegated))")
        print("SESSION_INDEX:         \(sessionIndex ?? "(absent)")")
        print("LOGGED_IN:             \(loggedIn ?? "(absent)")")

        if verbose {
            for name in ["DATASYNC_ID", "DELEGATED_SESSION_ID", "SESSION_INDEX"] {
                if extractConfigValue(named: name, from: html) == nil {
                    print("  (note: \(name) not found in page ytcfg)")
                }
            }
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

func isAllowedYtcfgProbeURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased()
    else {
        return false
    }
    return host == "music.youtube.com" || host == "www.youtube.com"
}

/// Discovers all brand accounts using the account/accounts_list endpoint
func discoverBrandAccounts(verbose: Bool) async {
    print("🔍 Discovering Brand Accounts")
    print("=============================\n")

    guard loadCookiesFromAppBackup() != nil else {
        print("❌ No cookies found. Please sign in to Kaset first.")
        return
    }

    do {
        let (data, statusCode) = try await makeRequest(
            endpoint: "account/accounts_list",
            body: [:],
            authenticated: true
        )

        guard statusCode == 200 else {
            print("❌ HTTP \(statusCode) - Failed to fetch accounts list")
            return
        }

        // Parse accounts from response
        // Path: actions[0].getMultiPageMenuAction.menu.multiPageMenuRenderer.sections[0]
        //       .accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents[]
        guard let actions = data["actions"] as? [[String: Any]],
              let firstAction = actions.first,
              let getMultiPageMenuAction = firstAction["getMultiPageMenuAction"] as? [String: Any],
              let menu = getMultiPageMenuAction["menu"] as? [String: Any],
              let multiPageMenuRenderer = menu["multiPageMenuRenderer"] as? [String: Any],
              let sections = multiPageMenuRenderer["sections"] as? [[String: Any]],
              let firstSection = sections.first,
              let accountSectionListRenderer = firstSection["accountSectionListRenderer"]
              as? [String: Any],
              let contents = accountSectionListRenderer["contents"] as? [[String: Any]],
              let firstContent = contents.first,
              let accountItemSectionRenderer = firstContent["accountItemSectionRenderer"]
              as? [String: Any],
              let accountItems = accountItemSectionRenderer["contents"] as? [[String: Any]]
        else {
            print("❌ Failed to parse accounts list response")
            if verbose {
                print("\nResponse structure:")
                if let prettyData = try? JSONSerialization.data(
                    withJSONObject: data, options: .prettyPrinted
                ),
                    let prettyString = String(data: prettyData, encoding: .utf8)
                {
                    print(prettyString)
                }
            }
            return
        }

        // Also get the Google account header for the email
        var googleEmail: String?
        if let header = accountSectionListRenderer["header"] as? [String: Any],
           let googleAccountHeaderRenderer = header["googleAccountHeaderRenderer"]
           as? [String: Any],
           let email = googleAccountHeaderRenderer["email"] as? [String: Any],
           let runs = email["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            googleEmail = text
        }

        if let email = googleEmail {
            print("📧 Google Account: \(email)\n")
        }

        // Extract account info from each item
        var accounts: [(name: String, handle: String?, brandId: String?, isSelected: Bool)] = []

        for accountItem in accountItems {
            guard let item = accountItem["accountItem"] as? [String: Any] else {
                continue
            }

            // Extract account name
            var name: String?
            if let accountName = item["accountName"] as? [String: Any],
               let runs = accountName["runs"] as? [[String: Any]],
               let firstRun = runs.first,
               let text = firstRun["text"] as? String
            {
                name = text
            }

            // Extract channel handle
            var handle: String?
            if let channelHandle = item["channelHandle"] as? [String: Any],
               let runs = channelHandle["runs"] as? [[String: Any]],
               let firstRun = runs.first,
               let text = firstRun["text"] as? String
            {
                handle = text
            }

            // Extract brand account ID from pageIdToken
            var brandId: String?
            if let serviceEndpoint = item["serviceEndpoint"] as? [String: Any],
               let selectActiveIdentityEndpoint = serviceEndpoint["selectActiveIdentityEndpoint"]
               as? [String: Any],
               let supportedTokens = selectActiveIdentityEndpoint["supportedTokens"]
               as? [[String: Any]]
            {
                for token in supportedTokens {
                    if let pageIdToken = token["pageIdToken"] as? [String: Any],
                       let pageId = pageIdToken["pageId"] as? String
                    {
                        brandId = pageId
                        break
                    }
                }
            }

            // Check if selected
            let isSelected = item["isSelected"] as? Bool ?? false

            if let accountName = name {
                accounts.append(
                    (name: accountName, handle: handle, brandId: brandId, isSelected: isSelected)
                )
            }
        }

        if accounts.isEmpty {
            print("❌ No accounts found in response")
            return
        }

        print("📋 Found \(accounts.count) account(s):\n")

        for (index, account) in accounts.enumerated() {
            let handleStr = account.handle.map { " (\($0))" } ?? ""
            let selectedStr = account.isSelected ? " ← current" : ""
            let typeStr = account.brandId == nil ? " [Primary]" : " [Brand Account]"

            print("  \(index): \(account.name)\(handleStr)\(typeStr)\(selectedStr)")

            if let brandId = account.brandId {
                print("     Brand ID: \(brandId)")
            }
        }

        print()
        print("💡 To use a brand account, use the --brand flag with the Brand ID:")
        print("   Example: swift run api-explorer browse FEmusic_liked_playlists --brand <ID>")
        print()
        print("   This sets context.user.onBehalfOfUser in the request body,")
        print("   which is required for brand account access.")

    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

func listEndpoints() {
    print(
        """
        ╔══════════════════════════════════════════════════════════════════════════════╗
        ║                      YouTube Music API Endpoint Reference                     ║
        ╚══════════════════════════════════════════════════════════════════════════════╝

        ═══════════════════════════════════════════════════════════════════════════════
        📚 BROWSE ENDPOINTS (POST /browse with browseId)
        ═══════════════════════════════════════════════════════════════════════════════

        🌐 PUBLIC (No Auth Required)
        ───────────────────────────────────────────────────────────────────────────────
        FEmusic_home                  Home feed with personalized recommendations
        FEmusic_explore               Explore page (new releases, charts shortcuts)
        FEmusic_charts                Top songs, albums, trending by country/genre
        FEmusic_moods_and_genres      Browse by mood (Chill, Focus) or genre (Pop, Rock)
        FEmusic_new_releases          Recently released albums, singles, videos
        FEmusic_podcasts              Podcast discovery

        🔐 AUTHENTICATED (Requires Sign-in)
        ───────────────────────────────────────────────────────────────────────────────
        FEmusic_liked_playlists       User's saved/created playlists
        FEmusic_liked_videos          Liked songs (returns playlist format)
        FEmusic_history               Listening history (organized by time)
        FEmusic_library_landing       Library overview page
        FEmusic_library_albums        Saved albums (requires params*)
        FEmusic_library_artists       Rejected with HTTP 400 in current sessions
        FEmusic_library_corpus_artists Followed artists (returns public UC... pages)
        FEmusic_library_corpus_track_artists  Artists chip from Library (returns MPLAUC... pages)
        FEmusic_library_songs         All songs in library (requires params*)
        FEmusic_recently_played       Recently played content
        FEmusic_offline               Downloaded content (may not work on desktop)

        🔐 UPLOADS (User-Uploaded Content)
        ───────────────────────────────────────────────────────────────────────────────
        FEmusic_library_privately_owned_landing   Uploads landing page
        FEmusic_library_privately_owned_tracks    User-uploaded songs
        FEmusic_library_privately_owned_albums    User-uploaded albums
        FEmusic_library_privately_owned_artists   Artists from user uploads

        🌐 DYNAMIC BROWSE IDs (Pattern-based)
        ───────────────────────────────────────────────────────────────────────────────
        VL{playlistId}                Playlist detail (e.g., VLPLxyz...)
        UC{channelId}                 Artist/Channel detail (e.g., UCxyz...)
        MPLAUC{libraryArtistId}       Library artist detail (from Artists chip, requires auth)
        MPREb_{albumId}               Album detail
        MPLYt_{lyricsId}              Lyrics content
        FEmusic_moods_and_genres_category   Mood/Genre category (with params)

        ═══════════════════════════════════════════════════════════════════════════════
        📡 ACTION ENDPOINTS
        ═══════════════════════════════════════════════════════════════════════════════

        🌐 PUBLIC
        ───────────────────────────────────────────────────────────────────────────────
        search                        Search for content
                                      Body: {"query": "search term"}

        music/get_search_suggestions  Autocomplete suggestions
                                      Body: {"input": "partial query"}

        player                        Video metadata, streaming formats, thumbnails
                                      Body: {"videoId": "VIDEO_ID"}

        next                          Track info, lyrics ID, radio queue, feedback tokens
                                      Body: {"videoId": "VIDEO_ID"}

        music/get_queue               Queue data for videos or full playlist tracks
                                      Body: {"videoIds": ["ID1", "ID2"]}
                                        or: {"playlistId": "RDCLAK..."}  (returns ALL tracks)
                                      Note: Response uses playlistPanelVideoWrapperRenderer
                                            wrapper structure, not direct playlistPanelVideoRenderer

        guide                         Sidebar navigation structure
                                      Body: {}

        🔐 RATINGS (Requires Auth)
        ───────────────────────────────────────────────────────────────────────────────
        like/like                     Like a song/album/playlist
                                      Body: {"target": {"videoId": "VIDEO_ID"}}

        like/dislike                  Dislike a song
                                      Body: {"target": {"videoId": "VIDEO_ID"}}

        like/removelike               Remove like/dislike rating
                                      Body: {"target": {"videoId": "VIDEO_ID"}}

        🔐 LIBRARY MANAGEMENT (Requires Auth)
        ───────────────────────────────────────────────────────────────────────────────
        feedback                      Add/remove from library via feedback tokens
                                      Body: {"feedbackTokens": ["TOKEN"]}

        subscription/subscribe        Subscribe to an artist
                                      Body: {"channelIds": ["UC..."]}

        subscription/unsubscribe      Unsubscribe from an artist
                                      Body: {"channelIds": ["UC..."]}

        🔐 PLAYLIST MANAGEMENT (Requires Auth)
        ───────────────────────────────────────────────────────────────────────────────
        playlist/get_add_to_playlist  Get playlists for "Add to Playlist" menu
                                      Body: {"videoId": "VIDEO_ID"}

        playlist/create               Create a new playlist
                                      Body: {"title": "Name", "privacyStatus": "PRIVATE"}

        playlist/delete               Delete a playlist
                                      Body: {"playlistId": "PLxyz..."}

        browse/edit_playlist          Add/remove tracks from playlist
                                      Body: {"playlistId": "...", "actions": [...]}

        🔐 ACCOUNT (Requires Auth)
        ───────────────────────────────────────────────────────────────────────────────
        account/account_menu          Account settings and options
                                      Body: {}

        notification/get_notification_menu   User notifications
                                      Body: {}

        stats/watchtime               Listening statistics
                                      Body: {}

        ═══════════════════════════════════════════════════════════════════════════════
        📌 LIBRARY PARAMS (for library_albums, library_artists, library_songs)
        ═══════════════════════════════════════════════════════════════════════════════

        ggMGKgQIARAA    Recently Added
        ggMGKgQIAhAA    Recently Played
        ggMGKgQIAxAA    Alphabetical A-Z
        ggMGKgQIBBAA    Alphabetical Z-A
        ggMCCAE         Default Sort

        Example: swift run api-explorer browse FEmusic_library_albums ggMGKgQIARAA

        FEmusic_library_corpus_track_artists is the Library Artists chip endpoint.
        It requires sign-in for useful content but does not need sort params.
        Signed-in responses return MPLAUC... browseIds (MUSIC_PAGE_TYPE_LIBRARY_ARTIST).
        Browsing an MPLAUC... page directly also requires sign-in.

        ═══════════════════════════════════════════════════════════════════════════════
        ▶️ YOUTUBE MODE (--youtube: www.youtube.com, WEB client)
        ═══════════════════════════════════════════════════════════════════════════════

        🌐/🔐 BROWSE (auth used automatically when cookies are available)
        ───────────────────────────────────────────────────────────────────────────────
        FEwhat_to_watch               Home feed (personalized recommendations)
        FE{gaming,news,sports,live,fashion,learning}_destination
                                      Explore destination feeds
        FEsubscriptions               Subscriptions feed (requires auth)
        FElibrary                     Library overview (requires auth)
        FEhistory                     Watch history (requires auth)
        FEplaylist_aggregation        User playlists list (requires auth)
        VLWL                          Watch Later playlist (requires auth)
        VLLL                          Liked videos playlist (requires auth)
        VL{playlistId}                Playlist detail
        UC{channelId}                 Channel page (tab via params)

        📡 ACTIONS
        ───────────────────────────────────────────────────────────────────────────────
        search                        Body: {"query": "..."} (+"params" for filters)
        next                          Watch-next/related: Body: {"videoId": "..."}
        guide                         Sidebar incl. subscriptions list. Body: {}
        like/like, like/removelike    Body: {"target": {"videoId": "..."}}
        subscription/subscribe        Body: {"channelIds": ["UC..."]}
        subscription/unsubscribe      Body: {"channelIds": ["UC..."]}
        browse/edit_playlist          Watch Later add/remove via playlistId "WL"

        ═══════════════════════════════════════════════════════════════════════════════
        💡 USAGE TIPS
        ═══════════════════════════════════════════════════════════════════════════════

        Check auth status:     swift run api-explorer auth
        Explore with verbose:  swift run api-explorer browse FEmusic_charts -v
        Dynamic browse ID:     swift run api-explorer browse VLPLrAXtmErZgOeiKm4sgNOknGvNjby9efdf
        Action with body:      swift run api-explorer action player '{"videoId":"dQw4w9WgXcQ"}'

        * Param-based library endpoints above return HTTP 400 without both auth AND params

        """
    )
}

func showHelp() {
    print(
        """
        YouTube Music and YouTube API Explorer
        ======================================

        A standalone tool for exploring YouTube Music and regular YouTube API endpoints.
        Supports public and authenticated endpoints (reads cookies from Kaset app).

        Usage:
          swift run api-explorer <command> [options]

        Commands:
          browse <browseId> [params]     Explore a browse endpoint
          action <endpoint> <body>       Explore an action endpoint (body as JSON)
          continuation <token> [ep]      Explore a continuation (ep: 'browse' or 'next')
          analyze-file <path>            Safely summarize a saved JSON response
          list                           List all known endpoints
          auth                           Check authentication status
          accounts                       Discover available accounts (via authuser)
          brandaccounts                  List all brand accounts with their IDs
          ytcfg [url]                    Probe an HTTPS YouTube page's ytcfg identity
                                         (DATASYNC_ID/SESSION_INDEX)
          signin-probe <brandId> [N] [next]
                                         Read-only: follow a synthesized brand /signin and report
                                         whether the session identity flips (issue #277)
          signin-probe-real [next]       Read-only: follow the server-issued brand signin URL
          help                           Show this help message

        Options:
          -v, --verbose                  Show full raw JSON response (not truncated)
          -o, --output <file>            Save raw JSON response to a file
          --authuser N                   Use Google account at index N (for multi-account)
          --brand <ID>                   Use brand account ID (21-digit number)
          --youtube, --yt                Target regular YouTube (www.youtube.com, WEB client)
                                         instead of YouTube Music
          --no-auth, --guest             Force signed-out requests even if Kaset cookies exist

        YouTube mode examples:
          # Browse YouTube surfaces (auth used automatically when cookies exist)
          swift run api-explorer --youtube --guest browse FEwhat_to_watch     # Signed-out Home feed
          swift run api-explorer --youtube --guest browse FEgaming_destination # Signed-out Explore destination
          swift run api-explorer --youtube browse FEsubscriptions     # Subscriptions feed
          swift run api-explorer --youtube browse FEhistory           # Watch history
          swift run api-explorer --youtube browse VLWL                # Watch Later
          swift run api-explorer --youtube browse VLLL                # Liked videos
          swift run api-explorer --youtube --guest action search '{"query":"swift concurrency"}'
          swift run api-explorer --youtube action next '{"videoId":"dQw4w9WgXcQ"}'
          swift run api-explorer --youtube action guide '{}'          # Sidebar + subscriptions list

        Examples:
          # Explore public endpoints
          swift run api-explorer browse FEmusic_home
          swift run api-explorer browse FEmusic_charts
          swift run api-explorer browse FEmusic_moods_and_genres -v

          # Explore authenticated endpoints (requires Kaset sign-in)
          swift run api-explorer browse FEmusic_liked_playlists
          swift run api-explorer browse FEmusic_history
          swift run api-explorer browse FEmusic_library_corpus_track_artists

          # Discover brand accounts and use them
          swift run api-explorer brandaccounts                            # List brand accounts with IDs
          swift run api-explorer browse FEmusic_liked_playlists --brand <ID>  # Use brand account

          # Action endpoints
          swift run api-explorer action search '{"query":"never gonna give you up"}'
          swift run api-explorer action player '{"videoId":"dQw4w9WgXcQ"}'
          swift run api-explorer action next '{"playlistId":"RDEM...","videoId":"abc123"}'

          # Continuation (for pagination / infinite mix)
          swift run api-explorer continuation <token>           # browse endpoint (default)
          swift run api-explorer continuation <token> next      # next endpoint (for mix queues)

          # Safely inspect a saved response without printing raw token values
          swift run api-explorer analyze-file Tests/KasetTests/Fixtures/example.json

          # Check auth status
          swift run api-explorer auth

            Authentication:
                For authenticated endpoints, sign in to the Kaset app first.
                Debug builds export auth cookies to:
                    ~/Library/Application Support/Kaset/cookies.dat
                Use --guest/--no-auth to validate signed-out behavior without
                reading those cookies.

        """
    )
}

/// Analyzes a saved JSON response without printing raw values.
/// Useful for parser/fixture validation when live authenticated cookies are unavailable.
func analyzeSavedResponse(at path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        let data = try Data(contentsOf: url)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Saved response is not a JSON object")
            return
        }
        print("📄 Analyzing saved response: \(url.lastPathComponent)")
        print("   Raw JSON and token values remain hidden")
        print()
        print(analyzeResponse(response))
    } catch {
        print("❌ Failed to analyze saved response: \(error.localizedDescription)")
    }
}

// MARK: - Main Entry Point

func runMain() async {
    let args = Array(CommandLine.arguments.dropFirst())
    let verbose = args.contains("-v") || args.contains("--verbose")

    // Parse output file option
    var outputFile: String?
    for (index, arg) in args.enumerated() {
        if arg == "-o" || arg == "--output", index + 1 < args.count {
            outputFile = args[index + 1]
            break
        }
    }

    // Parse authuser option
    for (index, arg) in args.enumerated() {
        if arg == "--authuser", index + 1 < args.count {
            if let value = Int(args[index + 1]) {
                globalAuthUserIndex = value
            }
            break
        }
    }

    // Parse brand account option
    for (index, arg) in args.enumerated() {
        if arg == "--brand", index + 1 < args.count {
            globalBrandAccountId = args[index + 1]
            break
        }
    }

    // Parse YouTube mode option (target www.youtube.com / WEB client)
    if args.contains("--youtube") || args.contains("--yt") {
        activateYouTubeMode()
    }

    // Parse guest/no-auth option before filtering so cookie-backed auth checks
    // behave as if no Kaset debug cookie export exists. This is useful for
    // validating public signed-out API behavior on a developer machine that is
    // normally signed in.
    if args.contains("--no-auth") || args.contains("--guest") {
        forceUnauthenticatedRequests = true
    }

    // Filter out option flags and their values
    var filteredArgs: [String] = []
    var skipNext = false
    for arg in args {
        if skipNext {
            skipNext = false
            continue
        }
        if arg == "-v" || arg == "--verbose" || arg == "--youtube" || arg == "--yt"
            || arg == "--no-auth" || arg == "--guest"
        {
            continue
        }
        if arg == "-o" || arg == "--output" || arg == "--authuser" || arg == "--brand" {
            skipNext = true
            continue
        }
        filteredArgs.append(arg)
    }

    guard let command = filteredArgs.first else {
        showHelp()
        return
    }

    switch command {
    case "browse":
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: browse <browseId> [params]")
            return
        }
        let browseId = filteredArgs[1]
        let params: String? = filteredArgs.count >= 3 ? filteredArgs[2] : nil
        await exploreBrowse(browseId, params: params, verbose: verbose, outputFile: outputFile)

    case "action":
        guard filteredArgs.count >= 3 else {
            print("❌ Usage: action <endpoint> <body-json>")
            print("   Example: action search '{\"query\":\"hello\"}'")
            return
        }
        let endpoint = filteredArgs[1]
        let bodyJson = filteredArgs[2]
        await exploreAction(endpoint, bodyJson: bodyJson, verbose: verbose, outputFile: outputFile)

    case "continuation":
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: continuation <token> [endpoint]")
            print("   endpoint: 'browse' (default) for home/library, 'next' for mix queues")
            print("   Get the token from a browse response's continuationItemRenderer or")
            print("   from a next response's nextRadioContinuationData.continuation")
            return
        }
        let token = filteredArgs[1]
        let endpoint = filteredArgs.count >= 3 ? filteredArgs[2] : "browse"
        await exploreContinuation(
            token, endpoint: endpoint, verbose: verbose, outputFile: outputFile
        )

    case "analyze-file":
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: analyze-file <path>")
            return
        }
        analyzeSavedResponse(at: filteredArgs[1])

    case "list":
        listEndpoints()

    case "auth":
        checkAuthStatus()

    case "accounts":
        await discoverAccounts(verbose: verbose)

    case "brandaccounts":
        await discoverBrandAccounts(verbose: verbose)

    case "ytcfg":
        // Read-only identity probe: GET an authenticated page and report which
        // account the resulting session is acting as. DATASYNC_ID has the
        // canonical "<delegatedSessionId>||<userSessionId>" shape — a brand
        // session shows the brand pageId in the first half; primary shows an
        // empty second half. This is how we confirm whether a session-identity
        // switch (e.g. navigating signin?pageid=<brandId>) actually re-points
        // playback (and therefore history recording) to the brand.
        let pageArg: String? = filteredArgs.count >= 2 ? filteredArgs[1] : nil
        await probeYtcfg(pageURLString: pageArg, verbose: verbose)

    case "signin-probe":
        // Read-only mechanism pre-check for issue #277. Follows the brand
        // `/signin?...&pageid=<brandId>&authuser=<N>&next=<watchURL>` redirect
        // chain on an EPHEMERAL URLSession seeded from (never writing back) the
        // app cookies, then reads the landed page's ytcfg DATASYNC_ID. If the
        // first half flips to the brand pageId, the signin navigation re-points
        // the session identity at the HTTP/cookie level. This emits NO videostats
        // pings (no JS), so it cannot prove the history WRITE — only the identity
        // flip. It does NOT mutate the app's WebView session or cookies.dat.
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: signin-probe <brandId> [authuserIndex] [nextWatchURL]")
            return
        }
        let brandId = filteredArgs[1]
        let authIndex = filteredArgs.count >= 3 ? (Int(filteredArgs[2]) ?? 0) : 0
        let nextURL = filteredArgs.count >= 4 ? filteredArgs[3] : "\(activeOrigin)/"
        await probeSigninSwitch(brandId: brandId, authUserIndex: authIndex, nextURLString: nextURL)

    case "signin-probe-real":
        // Like `signin-probe`, but follows the EXACT server-issued
        // `accountSigninToken.signinUrl` from accounts_list (with all its
        // params: skip_identity_prompt, feature, action_handle_signin), rewriting
        // only `next`. This is the most faithful read-only reproduction of the
        // switch a browser would perform. Still ephemeral; mutates nothing.
        let realNext = filteredArgs.count >= 2 ? filteredArgs[1] : "\(activeOrigin)/"
        await probeSigninSwitchReal(nextURLString: realNext)

    case "help", "-h", "--help":
        showHelp()

    default:
        print("❌ Unknown command: \(command)")
        print("   Run 'swift run api-explorer help' for usage")
    }
}

/// Run the async main
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    await runMain()
    semaphore.signal()
}

semaphore.wait()
