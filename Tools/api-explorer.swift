#!/usr/bin/env swift
//
//  api-explorer.swift
//  Standalone API Explorer for YouTube Music
//
//  A unified tool for exploring both public and authenticated YouTube Music API endpoints.
//  Reads cookies from the Kaset app's debug cookie export for authenticated requests.
//
//  Usage:
//    chmod +x Tools/api-explorer.swift
//    ./Tools/api-explorer.swift [command] [options]
//
//  Commands:
//    browse <browseId> [params]    - Explore a browse endpoint
//    action <endpoint> <body>      - Explore an action endpoint (body as JSON)
//    continuation <token> [ep]     - Explore a continuation (ep: browse or next)
//    list                          - List all known endpoints
//    auth                          - Check authentication status
//    help                          - Show this help message
//
//  Options:
//    -v, --verbose                 - Show full raw JSON response (not truncated)
//    -o, --output <file>           - Save raw JSON response to a file
//
//  Examples:
//    ./Tools/api-explorer.swift browse FEmusic_home
//    ./Tools/api-explorer.swift browse FEmusic_charts
//    ./Tools/api-explorer.swift browse FEmusic_liked_playlists   # Requires auth
//    ./Tools/api-explorer.swift action search '{"query":"never gonna give you up"}'
//    ./Tools/api-explorer.swift continuation <token> next        # Mix queue continuation
//    ./Tools/api-explorer.swift auth
//    ./Tools/api-explorer.swift list
//

import CommonCrypto
import Dispatch
import Foundation

// MARK: - Configuration

let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
let clientVersion = "1.20231204.01.00"
let baseURL = "https://music.youtube.com/youtubei/v1"
let origin = "https://music.youtube.com"

/// Global auth user index (0 = primary account, 1+ = brand accounts)
var globalAuthUserIndex = 0

/// Global brand account ID (21-digit number from myaccount.google.com/brandaccounts)
var globalBrandAccountId: String?

// MARK: - Cookie Management

/// Reads cookies from Kaset app's backup file in Application Support.
/// This allows the standalone tool to make authenticated API requests.
func loadCookiesFromAppBackup() -> [HTTPCookie]? {
    guard let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else {
        return nil
    }

    let cookieFile = appSupport
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
    ) as? [Data] else {
        print("⚠️ Cookie file exists but failed to unarchive. File may be corrupted or use a different format.")
        print("   Path: \(cookieFile.path)")
        print("   Size: \(data.count) bytes")
        return nil
    }

    let cookies = cookieDataArray.compactMap { cookieData -> HTTPCookie? in
        guard let stringProperties = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSString.self, NSDate.self, NSNumber.self],
            from: cookieData
        ) as? [String: Any] else {
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

/// Filters cookies to those that match the music.youtube.com domain.
/// Cookies with domain `.youtube.com` match `music.youtube.com` (subdomain matching).
func filterCookiesForMusicYouTube(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
    cookies.filter { cookie in
        let domain = cookie.domain.lowercased()
        // Cookies with leading dot match subdomains (e.g., ".youtube.com" matches "music.youtube.com")
        if domain.hasPrefix(".") {
            let withoutDot = String(domain.dropFirst())
            return "music.youtube.com".hasSuffix(withoutDot) || withoutDot == "music.youtube.com"
        }
        // Exact match or subdomain
        return domain == "music.youtube.com" || "music.youtube.com".hasSuffix("." + domain)
    }
}

/// Gets the SAPISID value from cookies for authentication.
/// Prefers .youtube.com domain cookies over .google.com for music.youtube.com requests.
func getSAPISID(from cookies: [HTTPCookie]) -> String? {
    // Filter to youtube.com domain cookies first (better match for music.youtube.com)
    let ytCookies = filterCookiesForMusicYouTube(cookies)
    let secureCookie = ytCookies.first { $0.name == "__Secure-3PAPISID" }
    let fallbackCookie = ytCookies.first { $0.name == "SAPISID" }
    return (secureCookie ?? fallbackCookie)?.value
}

/// Builds a cookie header string using HTTPCookie's built-in method.
/// This ensures proper cookie formatting that matches what browsers send.
func buildCookieHeader(from cookies: [HTTPCookie]) -> String? {
    // Filter to only cookies that match music.youtube.com
    let matchingCookies = filterCookiesForMusicYouTube(cookies)
    guard !matchingCookies.isEmpty else { return nil }

    // Use HTTPCookie's built-in method for proper formatting
    let headerFields = HTTPCookie.requestHeaderFields(with: matchingCookies)
    return headerFields["Cookie"]
}

/// Computes SAPISIDHASH for YouTube API authentication.
func computeSAPISIDHASH(sapisid: String) -> String {
    let timestamp = Int(Date().timeIntervalSince1970)
    let input = "\(timestamp) \(sapisid) \(origin)"

    let data = Data(input.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    data.withUnsafeBytes { buffer in
        _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &hash)
    }
    let hashHex = hash.map { String(format: "%02x", $0) }.joined()

    return "\(timestamp)_\(hashHex)"
}

// MARK: - Request Builder

func buildContext(brandAccountId: String? = nil) -> [String: Any] {
    var userDict: [String: Any] = [
        "lockedSafetyMode": false,
    ]

    // Add brand account ID if specified
    if let brandId = brandAccountId ?? globalBrandAccountId {
        userDict["onBehalfOfUser"] = brandId
    }

    return [
        "client": [
            "clientName": "WEB_REMIX",
            "clientVersion": clientVersion,
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
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Origin": origin,
        "Referer": "\(origin)/",
    ]

    if authenticated, let cookies = loadCookiesFromAppBackup() {
        if let sapisid = getSAPISID(from: cookies),
           let cookieHeader = buildCookieHeader(from: cookies)
        {
            let sapisidhash = computeSAPISIDHASH(sapisid: sapisid)
            headers["Cookie"] = cookieHeader
            headers["Authorization"] = "SAPISIDHASH \(sapisidhash)"
            headers["X-Goog-AuthUser"] = "\(authUserIndex ?? globalAuthUserIndex)"
            headers["X-Origin"] = origin
        }
    }

    return headers
}

// MARK: - API Request

func makeRequest(endpoint: String, body: [String: Any], authenticated: Bool = false) async throws -> (data: [String: Any], statusCode: Int) {
    let urlString = "\(baseURL)/\(endpoint)?key=\(apiKey)&prettyPrint=false"
    guard let url = URL(string: urlString) else {
        throw NSError(domain: "APIExplorer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
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
        throw NSError(domain: "APIExplorer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "APIExplorer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
    }

    return (json, httpResponse.statusCode)
}

// MARK: - Response Analysis

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
    "FEmusic_library_songs",
    "FEmusic_library_non_music_audio_list",
    "FEmusic_recently_played",
    "FEmusic_offline",
    "FEmusic_library_privately_owned_landing",
    "FEmusic_library_privately_owned_tracks",
    "FEmusic_library_privately_owned_albums",
    "FEmusic_library_privately_owned_artists",
])

/// Checks if a browseId requires authentication.
/// This includes known endpoints plus playlist IDs that start with VL (which benefit from auth for premium content).
func needsAuthentication(_ browseId: String) -> Bool {
    if authRequiredEndpoints.contains(browseId) {
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

func exploreBrowse(_ browseId: String, params: String? = nil, verbose: Bool = false, outputFile: String? = nil) async {
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
        let (data, statusCode) = try await makeRequest(endpoint: "browse", body: body, authenticated: needsAuth)

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
            if let prettyData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
               let prettyString = String(data: prettyData, encoding: .utf8)
            {
                print(prettyString)
            }
        }

        if let outputFile {
            if let prettyData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
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

func exploreAction(_ endpoint: String, bodyJson: String, verbose: Bool = false, outputFile: String? = nil) async {
    let needsAuth = authRequiredActions.contains(endpoint)
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
        let (data, statusCode) = try await makeRequest(endpoint: endpoint, body: body, authenticated: needsAuth)

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
            if let prettyData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
               let prettyString = String(data: prettyData, encoding: .utf8)
            {
                print(prettyString)
            }
        }

        if let outputFile {
            if let prettyData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
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
func exploreContinuation(_ token: String, endpoint: String = "browse", verbose: Bool = false, outputFile: String? = nil) async {
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
        let (data, statusCode) = try await makeRequest(endpoint: endpoint, body: body, authenticated: true)

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
                                if item["playlistPanelVideoRenderer"] != nil ||
                                    item["playlistPanelVideoWrapperRenderer"] != nil
                                {
                                    songCount += 1
                                }
                            }
                            print("   └─ Songs in continuation: \(songCount)")
                        }
                    }
                    if let continuations = renderer["continuations"] as? [[String: Any]] {
                        print("   └─ \(key) has 'continuations' array (\(continuations.count) tokens)")
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
            if let prettyData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
               let prettyString = String(data: prettyData, encoding: .utf8)
            {
                print(prettyString)
            }
        }

        if let outputFile {
            if let prettyData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
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

    let matchingCookies = filterCookiesForMusicYouTube(cookies)
    print("✅ Found \(cookies.count) cookies in app backup")
    print("✅ \(matchingCookies.count) cookies match music.youtube.com domain\n")

    // Check for key auth cookies (in youtube.com domain)
    let authCookieNames = ["SAPISID", "__Secure-3PAPISID", "SID", "HSID", "SSID", "APISID", "__Secure-1PAPISID"]

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
    if let sapisid = getSAPISID(from: cookies) {
        print("✅ Can compute SAPISIDHASH for authenticated requests")
        print("   SAPISID value: \(sapisid.prefix(8))... (truncated)")
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
        print("   Example: ./api-explorer.swift browse FEmusic_liked_playlists --authuser 1")
    }
}

/// Fetches account info for a specific authuser index
private func fetchAccountInfo(authUserIndex: Int, verbose: Bool) async -> (name: String, handle: String?)? {
    let url = URL(string: "\(baseURL)/account/account_menu?key=\(apiKey)")!
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
              let activeAccountHeaderRenderer = header["activeAccountHeaderRenderer"] as? [String: Any]
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
              let accountSectionListRenderer = firstSection["accountSectionListRenderer"] as? [String: Any],
              let contents = accountSectionListRenderer["contents"] as? [[String: Any]],
              let firstContent = contents.first,
              let accountItemSectionRenderer = firstContent["accountItemSectionRenderer"] as? [String: Any],
              let accountItems = accountItemSectionRenderer["contents"] as? [[String: Any]]
        else {
            print("❌ Failed to parse accounts list response")
            if verbose {
                print("\nResponse structure:")
                if let prettyData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
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
           let googleAccountHeaderRenderer = header["googleAccountHeaderRenderer"] as? [String: Any],
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
               let selectActiveIdentityEndpoint = serviceEndpoint["selectActiveIdentityEndpoint"] as? [String: Any],
               let supportedTokens = selectActiveIdentityEndpoint["supportedTokens"] as? [[String: Any]]
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
                accounts.append((name: accountName, handle: handle, brandId: brandId, isSelected: isSelected))
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
        print("   Example: ./api-explorer.swift browse FEmusic_liked_playlists --brand <ID>")
        print()
        print("   This sets context.user.onBehalfOfUser in the request body,")
        print("   which is required for brand account access.")

    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

func listEndpoints() {
    print("""
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
    FEmusic_library_artists       Followed artists (requires params*)
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

    Example: ./api-explorer.swift browse FEmusic_library_albums ggMGKgQIARAA

    ═══════════════════════════════════════════════════════════════════════════════
    💡 USAGE TIPS
    ═══════════════════════════════════════════════════════════════════════════════

    Check auth status:     ./api-explorer.swift auth
    Explore with verbose:  ./api-explorer.swift browse FEmusic_charts -v
    Dynamic browse ID:     ./api-explorer.swift browse VLPLrAXtmErZgOeiKm4sgNOknGvNjby9efdf
    Action with body:      ./api-explorer.swift action player '{"videoId":"dQw4w9WgXcQ"}'

    * Library endpoints return HTTP 400 without both auth AND params

    """)
}

func showHelp() {
    print("""
    YouTube Music API Explorer
    ==========================

    A standalone tool for exploring YouTube Music API endpoints.
    Supports both public and authenticated endpoints (reads cookies from Kaset app).

    Usage:
      ./api-explorer.swift <command> [options]

    Commands:
      browse <browseId> [params]     Explore a browse endpoint
      action <endpoint> <body>       Explore an action endpoint (body as JSON)
      continuation <token> [ep]      Explore a continuation (ep: 'browse' or 'next')
      list                           List all known endpoints
      auth                           Check authentication status
      accounts                       Discover available accounts (via authuser)
      brandaccounts                  List all brand accounts with their IDs
      help                           Show this help message

    Options:
      -v, --verbose                  Show full raw JSON response (not truncated)
      -o, --output <file>            Save raw JSON response to a file
      --authuser N                   Use Google account at index N (for multi-account)
      --brand <ID>                   Use brand account ID (21-digit number)

    Examples:
      # Explore public endpoints
      ./api-explorer.swift browse FEmusic_home
      ./api-explorer.swift browse FEmusic_charts
      ./api-explorer.swift browse FEmusic_moods_and_genres -v

      # Explore authenticated endpoints (requires Kaset sign-in)
      ./api-explorer.swift browse FEmusic_liked_playlists
      ./api-explorer.swift browse FEmusic_history

      # Discover brand accounts and use them
      ./api-explorer.swift brandaccounts                            # List brand accounts with IDs
      ./api-explorer.swift browse FEmusic_liked_playlists --brand <ID>  # Use brand account

      # Action endpoints
      ./api-explorer.swift action search '{"query":"never gonna give you up"}'
      ./api-explorer.swift action player '{"videoId":"dQw4w9WgXcQ"}'
      ./api-explorer.swift action next '{"playlistId":"RDEM...","videoId":"abc123"}'

      # Continuation (for pagination / infinite mix)
      ./api-explorer.swift continuation <token>           # browse endpoint (default)
      ./api-explorer.swift continuation <token> next      # next endpoint (for mix queues)

      # Check auth status
      ./api-explorer.swift auth

        Authentication:
            For authenticated endpoints, sign in to the Kaset app first.
            Debug builds export auth cookies to:
                ~/Library/Application Support/Kaset/cookies.dat

    """)
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

    // Filter out option flags and their values
    var filteredArgs: [String] = []
    var skipNext = false
    for arg in args {
        if skipNext {
            skipNext = false
            continue
        }
        if arg == "-v" || arg == "--verbose" {
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
        await exploreContinuation(token, endpoint: endpoint, verbose: verbose, outputFile: outputFile)

    case "list":
        listEndpoints()

    case "auth":
        checkAuthStatus()

    case "accounts":
        await discoverAccounts(verbose: verbose)

    case "brandaccounts":
        await discoverBrandAccounts(verbose: verbose)

    case "help", "-h", "--help":
        showHelp()

    default:
        print("❌ Unknown command: \(command)")
        print("   Run './api-explorer.swift help' for usage")
    }
}

// Run the async main
let semaphore = DispatchSemaphore(value: 0)
Task {
    await runMain()
    semaphore.signal()
}

semaphore.wait()
