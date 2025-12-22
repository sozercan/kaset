#!/usr/bin/env swift
//
//  api-explorer.swift
//  Standalone API Explorer for YouTube Music
//
//  A unified tool for exploring both public and authenticated YouTube Music API endpoints.
//  Reads cookies from the Kaset app's backup file for authenticated requests.
//
//  Usage:
//    chmod +x Tools/api-explorer.swift
//    ./Tools/api-explorer.swift [command] [options]
//
//  Commands:
//    browse <browseId> [params]    - Explore a browse endpoint
//    action <endpoint> <body>      - Explore an action endpoint (body as JSON)
//    list                          - List all known endpoints
//    auth                          - Check authentication status
//    help                          - Show this help message
//
//  Examples:
//    ./Tools/api-explorer.swift browse FEmusic_home
//    ./Tools/api-explorer.swift browse FEmusic_charts
//    ./Tools/api-explorer.swift browse FEmusic_liked_playlists   # Requires auth
//    ./Tools/api-explorer.swift action search '{"query":"never gonna give you up"}'
//    ./Tools/api-explorer.swift auth
//    ./Tools/api-explorer.swift list
//

import Foundation
import Dispatch
import CommonCrypto

// MARK: - Configuration

let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
let clientVersion = "1.20231204.01.00"
let baseURL = "https://music.youtube.com/youtubei/v1"
let origin = "https://music.youtube.com"

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
    
    guard let data = try? Data(contentsOf: cookieFile),
          let cookieDataArray = try? NSKeyedUnarchiver.unarchivedObject(
              ofClasses: [NSArray.self, NSData.self],
              from: data
          ) as? [Data] else {
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

/// Gets the SAPISID value from cookies for authentication.
func getSAPISID(from cookies: [HTTPCookie]) -> String? {
    // Try secure cookie first, then fallback
    let secureCookie = cookies.first { $0.name == "__Secure-3PAPISID" }
    let fallbackCookie = cookies.first { $0.name == "SAPISID" }
    return (secureCookie ?? fallbackCookie)?.value
}

/// Builds a cookie header string from an array of cookies.
func buildCookieHeader(from cookies: [HTTPCookie]) -> String {
    cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
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

func buildContext() -> [String: Any] {
    [
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
        "user": [
            "lockedSafetyMode": false,
        ],
    ]
}

func buildHeaders(authenticated: Bool = false) -> [String: String] {
    var headers: [String: String] = [
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Origin": origin,
        "Referer": "\(origin)/",
    ]
    
    if authenticated, let cookies = loadCookiesFromAppBackup() {
        if let sapisid = getSAPISID(from: cookies) {
            let sapisidhash = computeSAPISIDHASH(sapisid: sapisid)
            headers["Cookie"] = buildCookieHeader(from: cookies)
            headers["Authorization"] = "SAPISIDHASH \(sapisidhash)"
            headers["X-Goog-AuthUser"] = "0"
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
           let tabs = singleColumn["tabs"] as? [[String: Any]] {
            output += "\n📑 Found \(tabs.count) tab(s)\n"
            
            for (index, tab) in tabs.enumerated() {
                if let tabRenderer = tab["tabRenderer"] as? [String: Any],
                   let title = tabRenderer["title"] as? String {
                    output += "  Tab \(index): \"\(title)\"\n"
                    
                    if let content = tabRenderer["content"] as? [String: Any],
                       let sectionList = content["sectionListRenderer"] as? [String: Any],
                       let sections = sectionList["contents"] as? [[String: Any]] {
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
                                           let text = runs.first?["text"] as? String {
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
    "FEmusic_recently_played",
    "FEmusic_offline",
    "FEmusic_library_privately_owned_landing",
    "FEmusic_library_privately_owned_tracks",
    "FEmusic_library_privately_owned_albums",
    "FEmusic_library_privately_owned_artists",
])

func exploreBrowse(_ browseId: String, params: String? = nil, verbose: Bool = false) async {
    let needsAuth = authRequiredEndpoints.contains(browseId)
    let authIcon = needsAuth ? "🔐" : "🌐"
    
    print("\(authIcon) Exploring browse endpoint: \(browseId)")
    if let params = params {
        print("   Params: \(params)")
    }
    if needsAuth {
        let hasAuth = loadCookiesFromAppBackup() != nil
        print("   Auth required: \(hasAuth ? "✅ cookies available" : "❌ no cookies found")")
    }
    print()
    
    var body: [String: Any] = ["browseId": browseId]
    if let params = params {
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
               let prettyString = String(data: prettyData, encoding: .utf8) {
                if prettyString.count > 5000 {
                    print(String(prettyString.prefix(5000)))
                    print("\n... (truncated, \(prettyString.count) total characters)")
                } else {
                    print(prettyString)
                }
            }
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

/// Known action endpoints that require authentication
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
    "notification/get_notification_menu",
    "stats/watchtime",
])

func exploreAction(_ endpoint: String, bodyJson: String, verbose: Bool = false) async {
    let needsAuth = authRequiredActions.contains(endpoint)
    let authIcon = needsAuth ? "🔐" : "🌐"
    
    print("\(authIcon) Exploring action endpoint: \(endpoint)")
    if needsAuth {
        let hasAuth = loadCookiesFromAppBackup() != nil
        print("   Auth required: \(hasAuth ? "✅ cookies available" : "❌ no cookies found")")
    }
    print()
    
    guard let bodyData = bodyJson.data(using: .utf8),
          let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
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
               let prettyString = String(data: prettyData, encoding: .utf8) {
                if prettyString.count > 5000 {
                    print(String(prettyString.prefix(5000)))
                    print("\n... (truncated, \(prettyString.count) total characters)")
                } else {
                    print(prettyString)
                }
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
    
    print("✅ Found \(cookies.count) cookies in app backup\n")
    
    // Check for key auth cookies
    let authCookieNames = ["SAPISID", "__Secure-3PAPISID", "SID", "HSID", "SSID", "APISID", "__Secure-1PAPISID"]
    
    print("Auth cookies:")
    for name in authCookieNames {
        if let cookie = cookies.first(where: { $0.name == name }) {
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

func listEndpoints() {
    print("""
    📚 Known Browse Endpoints
    =========================
    
    🌐 Public (No Auth Required):
    
    FEmusic_home              - Home feed with recommendations
    FEmusic_explore           - Explore page (new releases, charts)
    FEmusic_charts            - Top songs, albums, trending
    FEmusic_moods_and_genres  - Browse by mood or genre
    FEmusic_new_releases      - Recently released music
    FEmusic_podcasts          - Podcast discovery
    
    🔐 Authenticated (Requires Sign-in):
    
    FEmusic_liked_playlists   - User's saved/created playlists
    FEmusic_liked_videos      - Liked songs
    FEmusic_history           - Listening history
    FEmusic_library_landing   - Library overview
    FEmusic_library_albums    - Saved albums (needs params)
    FEmusic_library_artists   - Followed artists (needs params)
    FEmusic_library_songs     - All library songs (needs params)
    FEmusic_recently_played   - Recent content
    
    📡 Action Endpoints
    ===================
    
    🌐 Public:
    
    search                    - Search for content
                               Body: {"query": "search term"}
    
    music/get_search_suggestions - Autocomplete suggestions
                               Body: {"input": "partial query"}
    
    player                    - Video details, streaming formats
                               Body: {"videoId": "VIDEO_ID"}
    
    next                      - Track info, lyrics, related
                               Body: {"videoId": "VIDEO_ID"}
    
    music/get_queue           - Queue data
                               Body: {"videoIds": ["ID1", "ID2"]}
    
    🔐 Authenticated:
    
    like/like                 - Like a song
                               Body: {"target": {"videoId": "VIDEO_ID"}}
    
    feedback                  - Add/remove from library
                               Body: {"feedbackTokens": ["TOKEN"]}
    
    playlist/create           - Create a playlist
                               Body: {"title": "Playlist Name"}
    
    📌 Common Params (for library endpoints)
    ========================================
    
    ggMGKgQIARAA  - Recently Added
    ggMGKgQIAhAA  - Recently Played
    ggMGKgQIAxAA  - Alphabetical A-Z
    ggMGKgQIBBAA  - Alphabetical Z-A
    ggMCCAE       - Default Sort
    
    💡 Tips
    =======
    
    - Run './api-explorer.swift auth' to check authentication status
    - Sign in to Kaset app to enable authenticated endpoints
    - Use -v flag for verbose output with raw JSON
    
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
      list                           List all known endpoints
      auth                           Check authentication status
      help                           Show this help message
    
    Options:
      -v, --verbose                  Show detailed/raw response
    
    Examples:
      # Explore public endpoints
      ./api-explorer.swift browse FEmusic_home
      ./api-explorer.swift browse FEmusic_charts
      ./api-explorer.swift browse FEmusic_moods_and_genres -v
    
      # Explore authenticated endpoints (requires Kaset sign-in)
      ./api-explorer.swift browse FEmusic_liked_playlists
      ./api-explorer.swift browse FEmusic_history
    
      # Action endpoints
      ./api-explorer.swift action search '{"query":"never gonna give you up"}'
      ./api-explorer.swift action player '{"videoId":"dQw4w9WgXcQ"}'
    
      # Check auth status
      ./api-explorer.swift auth
    
    Authentication:
      For authenticated endpoints, sign in to the Kaset app first.
      The tool reads cookies from ~/Library/Application Support/Kaset/cookies.dat
    
    """)
}

// MARK: - Main Entry Point

func runMain() async {
    let args = CommandLine.arguments.dropFirst()
    let verbose = args.contains("-v") || args.contains("--verbose")
    let filteredArgs = args.filter { $0 != "-v" && $0 != "--verbose" }
    
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
        let browseId = filteredArgs[filteredArgs.index(after: filteredArgs.startIndex)]
        let params: String? = filteredArgs.count >= 3 ? 
            filteredArgs[filteredArgs.index(filteredArgs.startIndex, offsetBy: 2)] : nil
        await exploreBrowse(browseId, params: params, verbose: verbose)
        
    case "action":
        guard filteredArgs.count >= 3 else {
            print("❌ Usage: action <endpoint> <body-json>")
            print("   Example: action search '{\"query\":\"hello\"}'")
            return
        }
        let endpoint = filteredArgs[filteredArgs.index(after: filteredArgs.startIndex)]
        let bodyJson = filteredArgs[filteredArgs.index(filteredArgs.startIndex, offsetBy: 2)]
        await exploreAction(endpoint, bodyJson: bodyJson, verbose: verbose)
        
    case "list":
        listEndpoints()
        
    case "auth":
        checkAuthStatus()
        
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
