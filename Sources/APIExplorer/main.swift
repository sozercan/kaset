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
//    action <endpoint> <body>      - Explore a JSON action endpoint (body as JSON)
//    wire-action <endpoint> <body> - Safely inspect JSON, streaming, or opaque responses
//    ask-video-audit <videoId>     - Audit YouTube Ask Gemini / YouChat API surfaces
//    ask-video-parity <videoId>    - Compare read-only Ask request profiles
//    ask-video-live-test <videoId> - Replay server-issued summary/follow-up suggestions
//    ask-video-free-text-test <videoId>
//                                  - Guarded one-shot free-text validation
//    search-audit <query>          - Audit live YouTube Music search shapes and filters
//    continuation <token> [ep]     - Explore a continuation (ep: browse, search, or next)
//    analyze-file <path>           - Safely summarize a saved JSON response
//    list                          - List all known endpoints
//    auth                          - Check authentication status
//    help                          - Show this help message
//
//  Options:
//    -v, --verbose                 - Show raw JSON, or expanded search-audit samples
//    -o, --output <file>           - Save raw JSON response to a file
//    --client-version <version>    - Override the resolved InnerTube client version
//    --confirm-live-ai             - Required acknowledgement for live AI requests
//    --prompt-file <path|->         - Read a private free-text prompt from a mode-0600 file or stdin
//    --fresh-chats N               - Run 1-3 independent summary chats
//    --follow-up                   - Replay one server-issued follow-up suggestion
//    --youtube, --yt               - Target regular YouTube (www.youtube.com, WEB client)
//                                    instead of YouTube Music
//    --no-auth, --guest            - Force unauthenticated requests even if Kaset cookies exist
//
//  Examples:
//    swift run api-explorer browse FEmusic_home
//    swift run api-explorer browse FEmusic_charts
//    swift run api-explorer browse FEmusic_liked_playlists   # Requires auth
//    swift run api-explorer action search '{"query":"never gonna give you up"}'
//    swift run api-explorer ask-video-parity <VIDEO_ID>
//    swift run api-explorer ask-video-live-test <VIDEO_ID> --confirm-live-ai --follow-up
//    swift run api-explorer ask-video-free-text-test <VIDEO_ID> --confirm-live-ai --prompt-file -
//    swift run api-explorer continuation <token> next        # Mix queue continuation
//    swift run api-explorer auth
//    swift run api-explorer list
//

import CommonCrypto
import Darwin
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
nonisolated(unsafe) var clientVersionWasForced = false
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
nonisolated(unsafe) var authUserOptionWasSpecified = false

/// Global brand account ID (21-digit number from myaccount.google.com/brandaccounts)
nonisolated(unsafe) var globalBrandAccountId: String?

/// Language code sent as the InnerTube `hl` client parameter.
///
/// Overridable with `--hl` so response localization can be probed directly —
/// InnerTube accepts both Apple's script identifiers (`zh-Hans`/`zh-Hant`) and
/// common region aliases (`zh-CN`/`zh-TW`), so either form can be compared
/// against real responses.
nonisolated(unsafe) var globalHl = "en"

private func effectivePort(for url: URL) -> Int? {
    if let port = url.port {
        return port
    }
    switch url.scheme?.lowercased() {
    case "https": return 443
    case "http": return 80
    default: return nil
    }
}

// MARK: - BoundedResponseDataDelegate

private final class BoundedResponseDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let scheme: String?
    private let host: String?
    private let port: Int?
    private let maximumBytes: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var responseData = Data()
    private var isFinished = false
    private var cancellationRequested = false

    init(originURL: URL, maximumBytes: Int) {
        self.scheme = originURL.scheme?.lowercased()
        self.host = originURL.host?.lowercased()
        self.port = effectivePort(for: originURL)
        self.maximumBytes = maximumBytes
    }

    func load(
        configuration: URLSessionConfiguration,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.dataTask(with: request)

                self.lock.lock()
                if self.cancellationRequested {
                    self.isFinished = true
                    self.lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.session = session
                self.task = task
                self.lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == self.scheme,
              url.host?.lowercased() == self.host,
              effectivePort(for: url) == self.port
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let exceedsLimit = response.expectedContentLength > 0
            && response.expectedContentLength > Int64(self.maximumBytes)
        guard !exceedsLimit else {
            completionHandler(.cancel)
            self.finish(
                .failure(ResponseSizeLimitError(maximumBytes: self.maximumBytes)),
                cancelSession: true
            )
            return
        }

        self.lock.lock()
        if !self.isFinished {
            self.response = response
            if response.expectedContentLength > 0 {
                self.responseData.reserveCapacity(
                    min(Int(response.expectedContentLength), self.maximumBytes)
                )
            }
        }
        self.lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive data: Data
    ) {
        var exceedsLimit = false
        self.lock.lock()
        if !self.isFinished {
            if data.count > self.maximumBytes - self.responseData.count {
                exceedsLimit = true
            } else {
                self.responseData.append(data)
            }
        }
        self.lock.unlock()

        if exceedsLimit {
            self.finish(
                .failure(ResponseSizeLimitError(maximumBytes: self.maximumBytes)),
                cancelSession: true
            )
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            self.finish(.failure(error), cancelSession: true)
            return
        }

        self.lock.lock()
        let response = self.response
        let data = self.responseData
        self.lock.unlock()

        guard let response else {
            self.finish(
                .failure(NSError(
                    domain: "APIExplorer",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Response completed without metadata"]
                )),
                cancelSession: true
            )
            return
        }
        self.finish(.success((data, response)), cancelSession: false)
    }

    private func cancel() {
        self.lock.lock()
        self.cancellationRequested = true
        let shouldFinish = self.continuation != nil && !self.isFinished
        self.lock.unlock()
        if shouldFinish {
            self.finish(.failure(CancellationError()), cancelSession: true)
        }
    }

    private func finish(
        _ result: Result<(Data, URLResponse), any Error>,
        cancelSession: Bool
    ) {
        self.lock.lock()
        guard !self.isFinished else {
            self.lock.unlock()
            return
        }
        self.isFinished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.lock.unlock()

        if cancelSession {
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
        continuation?.resume(with: result)
    }
}

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

    let legacyCookieFile =
        appSupport
            .appendingPathComponent("Kaset", isDirectory: true)
            .appendingPathComponent("cookies.dat")

    let containerCookieFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.sertacozercan.Kaset/Data", isDirectory: true)
        .appendingPathComponent("Library/Application Support/Kaset", isDirectory: true)
        .appendingPathComponent("cookies.dat")

    func decodeCookies(at cookieFile: URL) -> [HTTPCookie]? {
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

    // Once the sandboxed app has created its Application Support directory, its
    // container export is authoritative. Never resurrect the legacy host archive
    // after logout, account switching, expiry, corruption, or a cleared export.
    if FileManager.default.fileExists(atPath: containerCookieFile.path) {
        return decodeCookies(at: containerCookieFile)
    }

    let containerStorageDirectory = containerCookieFile.deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: containerStorageDirectory.path) {
        return nil
    }

    guard FileManager.default.fileExists(atPath: legacyCookieFile.path) else {
        return nil
    }
    return decodeCookies(at: legacyCookieFile)
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
    let sapisid = ytCookies.first { $0.name == "SAPISID" }
    let fallbackCookie = ytCookies.first { $0.name == "__Secure-3PAPISID" }
    return (sapisid ?? fallbackCookie)?.value
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

func buildSIDAuthorizationHeader(
    from cookies: [HTTPCookie],
    includeAllAvailableProofs: Bool
) -> String? {
    let ytCookies = filterCookiesForAPIHost(cookies)
    let sapisid = ytCookies.first { $0.name == "SAPISID" }?.value
        ?? ytCookies.first { $0.name == "__Secure-3PAPISID" }?.value
    let oneParty = ytCookies.first { $0.name == "__Secure-1PAPISID" }?.value
    let threeParty = ytCookies.first { $0.name == "__Secure-3PAPISID" }?.value
    let timestamp = Int(Date().timeIntervalSince1970)

    func authorization(scheme: String, sid: String?) -> String? {
        guard let sid else { return nil }
        let input = "\(timestamp) \(sid) \(activeOrigin)"
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return "\(scheme) \(timestamp)_\(hash.map { String(format: "%02x", $0) }.joined())"
    }

    var values = [authorization(scheme: "SAPISIDHASH", sid: sapisid)].compactMap(\.self)
    if includeAllAvailableProofs {
        values.append(contentsOf: [
            authorization(scheme: "SAPISID1PHASH", sid: oneParty),
            authorization(scheme: "SAPISID3PHASH", sid: threeParty),
        ].compactMap(\.self))
    }
    return values.isEmpty ? nil : values.joined(separator: " ")
}

// MARK: - API Key Resolution

private func webClientConfigurationRequest(timeout: TimeInterval? = nil) -> URLRequest {
    var request = URLRequest(url: activeWebClientURL)
    if let timeout {
        request.timeoutInterval = timeout
    }
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )
    return request
}

private func webClientConfiguration(authenticated: Bool) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    if authenticated, let cookies = loadCookiesFromAppBackup(), !cookies.isEmpty {
        let storage = HTTPCookieStorage()
        for cookie in cookies {
            storage.setCookie(cookie)
        }
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
    }
    return configuration
}

func resolveAPIKey(authenticated: Bool = false) async throws -> String {
    if let cachedAPIKey {
        return cachedAPIKey
    }

    if let override = ProcessInfo.processInfo.environment[apiKeyEnvironmentVariable],
       !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedAPIKey = trimmed
        await resolveLiveClientVersionIfNeeded(authenticated: authenticated)
        return trimmed
    }

    let request = webClientConfigurationRequest()
    let (data, response) = try await boundedResponseData(
        configuration: webClientConfiguration(authenticated: authenticated),
        request: request,
        maximumBytes: maximumConfigurationResponseBytes
    )
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
    if cachedClientVersion == nil,
       let version = extractInnertubeClientVersion(from: html)
    {
        cachedClientVersion = version
    }
    cachedAPIKey = key
    return key
}

/// Resolves only the live client version when the API key came from an explicit
/// environment override. Failure is non-fatal: callers can still use the
/// configured fallback, and search-audit labels that source explicitly.
func resolveLiveClientVersionIfNeeded(authenticated: Bool = false) async {
    guard cachedClientVersion == nil else { return }

    let request = webClientConfigurationRequest(timeout: 5)
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await boundedResponseData(
            configuration: webClientConfiguration(authenticated: authenticated),
            request: request,
            maximumBytes: maximumConfigurationResponseBytes
        )
    } catch let error as ResponseSizeLimitError {
        print("⚠️ Web client configuration skipped: \(error.localizedDescription)")
        return
    } catch {
        return
    }

    guard let httpResponse = response as? HTTPURLResponse,
          (200 ... 399).contains(httpResponse.statusCode),
          let html = String(data: data, encoding: .utf8)
    else {
        return
    }

    if let version = extractInnertubeClientVersion(from: html) {
        cachedClientVersion = version
    }
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

func extractConfigBoolean(named name: String, from html: String) -> Bool? {
    let pattern = "\"\(name)\"\\s*:\\s*(true|false)"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
              in: html,
              range: NSRange(html.startIndex..., in: html)
          ),
          let range = Range(match.range(at: 1), in: html)
    else {
        return nil
    }
    return html[range] == "true"
}

func extractConfigInteger(named name: String, from html: String) -> Int? {
    let pattern = "\"\(name)\"\\s*:\\s*(-?[0-9]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
              in: html,
              range: NSRange(html.startIndex..., in: html)
          ),
          let range = Range(match.range(at: 1), in: html)
    else {
        return nil
    }
    return Int(html[range])
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
            "hl": globalHl,
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
        if let authorization = buildSIDAuthorizationHeader(
            from: cookies,
            includeAllAvailableProofs: false
        ),
            let cookieHeader = buildCookieHeader(from: cookies)
        {
            headers["Cookie"] = cookieHeader
            headers["Authorization"] = authorization
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

func hasUsableAuthMaterial() -> Bool {
    guard let cookies = loadCookiesFromAppBackup() else { return false }
    return getSAPISID(from: cookies) != nil && buildCookieHeader(from: cookies) != nil
}

// MARK: - APIWireResponse

struct APIWireResponse {
    let data: Data
    let statusCode: Int
    let contentType: String?
}

private let maximumWireResponseBytes = 32 * 1024 * 1024
private let maximumConfigurationResponseBytes = 8 * 1024 * 1024

// MARK: - ResponseSizeLimitError

struct ResponseSizeLimitError: LocalizedError {
    let maximumBytes: Int

    var errorDescription: String? {
        "Response exceeds the configured \(self.maximumBytes / 1_048_576) MiB limit"
    }
}

func boundedResponseData(
    configuration: URLSessionConfiguration,
    request: URLRequest,
    maximumBytes: Int
) async throws -> (Data, URLResponse) {
    guard let originURL = request.url else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Request URL is missing"]
        )
    }
    let delegate = BoundedResponseDataDelegate(
        originURL: originURL,
        maximumBytes: maximumBytes
    )
    return try await delegate.load(configuration: configuration, request: request)
}

func canonicalAPIEndpoint(_ endpoint: String) throws -> String {
    let pathSegments = endpoint.split(separator: "/", omittingEmptySubsequences: false)
    guard !endpoint.isEmpty, endpoint.count <= 160,
          !endpoint.hasPrefix("/"), !endpoint.hasSuffix("/"),
          !endpoint.contains("//"),
          pathSegments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          endpoint.unicodeScalars.allSatisfy({ scalar in
              switch scalar.value {
              case 45, 47, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                  true
              default:
                  false
              }
          })
    else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Endpoint must be a plain relative API path"]
        )
    }
    return endpoint
}

func makeWireRequest(endpoint: String, body: [String: Any], authenticated: Bool = false) async throws
    -> APIWireResponse
{
    let endpoint = try canonicalAPIEndpoint(endpoint)
    let apiKey = try await resolveAPIKey(authenticated: authenticated)
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

    let (data, response) = try await boundedResponseData(
        configuration: .ephemeral,
        request: request,
        maximumBytes: maximumWireResponseBytes
    )

    guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(
            domain: "APIExplorer", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
        )
    }

    return APIWireResponse(
        data: data,
        statusCode: httpResponse.statusCode,
        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
    )
}

func makeRequest(endpoint: String, body: [String: Any], authenticated: Bool = false) async throws
    -> (data: [String: Any], statusCode: Int)
{
    let response = try await makeWireRequest(
        endpoint: endpoint, body: body, authenticated: authenticated
    )

    guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw NSError(
            domain: "APIExplorer", code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Non-object JSON or streaming response; use wire-action for a safe structural audit",
            ]
        )
    }

    return (json, response.statusCode)
}

// MARK: - Response Analysis

func joinedRunsText(_ data: [String: Any]?) -> String? {
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

private func playlistPanelBylineSummary(_ data: [String: Any]) -> String {
    guard let renderer = findFirstRenderer(named: "playlistPanelVideoRenderer", in: data),
          let byline = renderer["longBylineText"] as? [String: Any],
          let runs = byline["runs"] as? [[String: Any]],
          !runs.isEmpty
    else { return "" }

    var output = "\n🎤 Playlist-panel long byline runs:\n"
    for (index, run) in runs.enumerated() {
        let text = run["text"] as? String ?? ""
        let browseId = ((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
        let browseKind = if let browseId {
            if browseId.hasPrefix("MPLAUC") {
                "MPLAUC…"
            } else if browseId.hasPrefix("UC") {
                "UC…"
            } else if browseId.hasPrefix("MPRE") {
                "MPRE…"
            } else {
                "other"
            }
        } else {
            "none"
        }
        output += "  [\(index)] text=\(String(reflecting: text)) browse=\(browseKind)\n"
    }
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

private func collectAlbumPlaylistTargets(in value: Any, targets: inout Set<String>) {
    if let dictionary = value as? [String: Any] {
        if let playlistId = dictionary["playlistId"] as? String,
           playlistId.hasPrefix("OLAK")
        {
            targets.insert(playlistId)
        }
        for child in dictionary.values {
            collectAlbumPlaylistTargets(in: child, targets: &targets)
        }
    } else if let array = value as? [Any] {
        for child in array {
            collectAlbumPlaylistTargets(in: child, targets: &targets)
        }
    }
}

private func albumLibraryTargetSummary(_ data: [String: Any]) -> String {
    var targets = Set<String>()
    collectAlbumPlaylistTargets(in: data, targets: &targets)
    guard !targets.isEmpty else { return "" }

    return "\n💾 Album library target:\n  • Found \(targets.count) unique OLAK playlist target(s) for album mutations\n"
}

func analyzeResponse(
    _ data: [String: Any],
    verbose: Bool = false,
    searchAuditContext: SearchAuditContext = .automatic
) -> String {
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

    output += albumLibraryTargetSummary(data)

    output += chapterProbeSummary(data)

    output += libraryFeedbackProbeSummary(data)

    output += playlistPanelBylineSummary(data)

    if !youtubeMode {
        output += searchResponseAuditSummary(
            data,
            context: searchAuditContext
        )
    }

    output += rendererHistogram(data)

    return output
}

// MARK: - Commands

/// Known endpoints that require authentication
let authRequiredEndpoints = Set([
    "FEmusic_liked_playlists",
    "FEmusic_liked_albums",
    "FEmusic_liked_videos",
    "FEmusic_history",
    "FEmusic_library_landing",
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
    // Album pages are public, but authenticated requests expose personalized
    // Save/Remove library controls and their OLAK mutation targets.
    if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
        return loadCookiesFromAppBackup() != nil
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
                try writePrivateOutput(prettyData, to: outputFile)
                print("\n💾 Saved with owner-only permissions: \(outputFile)")
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

func actionNeedsAuthentication(_ endpoint: String) -> Bool {
    guard !forceUnauthenticatedRequests else { return false }
    // In YouTube mode, personalized actions (guide, next, search) return richer
    // data signed in, so use auth whenever cookies are available.
    return authRequiredActions.contains(endpoint)
        || (youtubeMode && hasUsableAuthMaterial())
}

func exploreAction(
    _ endpoint: String, bodyJson: String, verbose: Bool = false, outputFile: String? = nil
) async {
    let needsAuth = actionNeedsAuthentication(endpoint)
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
        print("❌ Invalid JSON object body")
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
        print(analyzeResponse(
            data,
            verbose: verbose,
            searchAuditContext: endpoint == "search" && !youtubeMode ? .firstPage : .automatic
        ))

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
                try writePrivateOutput(prettyData, to: outputFile)
                print("\n💾 Saved with owner-only permissions: \(outputFile)")
            }
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

private let maximumPrivateBodyBytes = 2 * 1024 * 1024
private let maximumPrivatePromptBytes = 64 * 1024
private let maximumPrivatePromptCharacters = 16000

private func posixError(_ description: String, code: Int32 = errno) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}

private func writeAll(_ data: Data, fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(
                fileDescriptor,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                throw posixError("Could not write private output")
            }
            offset += written
        }
    }
}

private func extendedACLStatus(fileDescriptor: Int32) throws -> Bool {
    errno = 0
    guard let accessControlList = acl_get_fd_np(fileDescriptor, ACL_TYPE_EXTENDED) else {
        if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP {
            return false
        }
        throw posixError("Could not inspect file access controls")
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(accessControlList)) }

    var firstEntry: acl_entry_t?
    errno = 0
    if acl_get_entry(accessControlList, Int32(ACL_FIRST_ENTRY.rawValue), &firstEntry) == 0 {
        return true
    }
    if errno == EINVAL {
        return false
    }
    throw posixError("Could not inspect file access controls")
}

private func clearExtendedACL(fileDescriptor: Int32) throws {
    guard let emptyAccessControlList = acl_init(0) else {
        throw posixError("Could not initialize file access controls")
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(emptyAccessControlList)) }

    let result = acl_set_fd_np(fileDescriptor, emptyAccessControlList, ACL_TYPE_EXTENDED)
    if result == 0 || errno == ENOTSUP || errno == EOPNOTSUPP {
        return
    }
    throw posixError("Could not clear inherited file access controls")
}

private func verifyOwnerOnlyNode(fileDescriptor: Int32, expectedType: mode_t) throws {
    var status = stat()
    guard fstat(fileDescriptor, &status) == 0 else {
        throw posixError("Could not verify private file")
    }
    guard (status.st_mode & S_IFMT) == expectedType,
          status.st_uid == geteuid(),
          status.st_mode & 0o077 == 0,
          try !extendedACLStatus(fileDescriptor: fileDescriptor)
    else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "File access is not owner-only"]
        )
    }
}

func writePrivateOutput(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    let destinationDirectory = url.deletingLastPathComponent().path
    let filename = url.lastPathComponent.isEmpty ? "api-explorer-output" : url.lastPathComponent
    var directoryTemplate = Array("\(destinationDirectory)/.\(filename).stage.XXXXXX".utf8CString)
    guard mkdtemp(&directoryTemplate) != nil else {
        throw posixError("Could not create private staging directory")
    }
    let stagingDirectory = String(
        decoding: directoryTemplate.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
    )
    guard stagingDirectory.withCString({ Darwin.chmod($0, S_IRWXU) }) == 0 else {
        throw posixError("Could not secure private staging directory")
    }
    let stagingFile = "\(stagingDirectory)/payload"
    var stagingFileExists = false
    defer {
        if stagingFileExists {
            stagingFile.withCString { _ = Darwin.unlink($0) }
        }
        stagingDirectory.withCString { _ = Darwin.rmdir($0) }
    }

    let directoryDescriptor = stagingDirectory.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard directoryDescriptor >= 0 else {
        throw posixError("Could not open private staging directory")
    }
    defer { _ = Darwin.close(directoryDescriptor) }
    guard fchmod(directoryDescriptor, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
        throw posixError("Could not secure private staging directory")
    }
    try clearExtendedACL(fileDescriptor: directoryDescriptor)
    try verifyOwnerOnlyNode(fileDescriptor: directoryDescriptor, expectedType: S_IFDIR)

    let fileDescriptor = "payload".withCString {
        Darwin.openat(
            directoryDescriptor,
            $0,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
    }
    guard fileDescriptor >= 0 else {
        throw posixError("Could not create private output")
    }
    stagingFileExists = true
    defer { _ = Darwin.close(fileDescriptor) }

    guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw posixError("Could not secure private output")
    }
    try clearExtendedACL(fileDescriptor: fileDescriptor)
    try verifyOwnerOnlyNode(fileDescriptor: fileDescriptor, expectedType: S_IFREG)
    try writeAll(data, fileDescriptor: fileDescriptor)
    guard fsync(fileDescriptor) == 0 else {
        throw posixError("Could not synchronize private output")
    }

    let renameResult = stagingFile.withCString { sourcePath in
        url.path.withCString { destinationPath in
            Darwin.rename(sourcePath, destinationPath)
        }
    }
    guard renameResult == 0 else {
        throw posixError("Could not replace output file")
    }
    stagingFileExists = false
}

private func readBoundedData(
    fileDescriptor: Int32,
    maximumBytes: Int = maximumPrivateBodyBytes,
    contentDescription: String = "Request body"
) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let maximumRead = min(buffer.count, maximumBytes + 1 - result.count)
        guard maximumRead > 0 else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(contentDescription) exceeds its size limit",
                ]
            )
        }
        let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fileDescriptor, rawBuffer.baseAddress, maximumRead)
        }
        if readCount == 0 {
            break
        }
        if readCount < 0 {
            if errno == EINTR {
                continue
            }
            throw posixError("Could not read request body")
        }
        result.append(buffer, count: readCount)
        if result.count > maximumBytes {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(contentDescription) exceeds its size limit",
                ]
            )
        }
    }
    return result
}

func loadPrivatePrompt(from promptFile: String) throws -> String {
    let data: Data
    if promptFile == "-" {
        guard Darwin.isatty(STDIN_FILENO) == 0 else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Interactive stdin is not accepted; pipe or redirect the prompt instead",
                ]
            )
        }
        data = try readBoundedData(
            fileDescriptor: STDIN_FILENO,
            maximumBytes: maximumPrivatePromptBytes,
            contentDescription: "Prompt"
        )
    } else {
        let expandedPath = NSString(string: promptFile).expandingTildeInPath
        let fileDescriptor = expandedPath.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fileDescriptor >= 0 else {
            throw posixError("Could not open private prompt file")
        }
        defer { _ = Darwin.close(fileDescriptor) }

        var status = stat()
        guard fstat(fileDescriptor, &status) == 0 else {
            throw posixError("Could not inspect private prompt file")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Prompt path must be a regular file"]
            )
        }
        guard status.st_uid == geteuid(),
              status.st_mode & 0o777 == S_IRUSR | S_IWUSR
        else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Prompt file must be owned by the current user with mode 0600",
                ]
            )
        }
        guard try !extendedACLStatus(fileDescriptor: fileDescriptor) else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Prompt file must not have an extended ACL (use chmod -N)",
                ]
            )
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(maximumPrivatePromptBytes)
        else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Prompt exceeds its size limit"]
            )
        }
        data = try readBoundedData(
            fileDescriptor: fileDescriptor,
            maximumBytes: maximumPrivatePromptBytes,
            contentDescription: "Prompt"
        )
    }

    guard var prompt = String(data: data, encoding: .utf8) else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Prompt must be valid UTF-8"]
        )
    }
    prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, prompt.count <= maximumPrivatePromptCharacters else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Prompt must contain 1-\(maximumPrivatePromptCharacters) characters",
            ]
        )
    }
    return prompt
}

func loadRequestBodyJSON(inlineBody: String?, bodyFile: String?) throws -> String {
    if inlineBody != nil, bodyFile != nil {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Use either an inline body or --body-file, not both"]
        )
    }
    if let inlineBody {
        return inlineBody
    }
    guard let bodyFile else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "A JSON body or --body-file is required"]
        )
    }

    let data: Data
    if bodyFile == "-" {
        data = try readBoundedData(fileDescriptor: STDIN_FILENO)
    } else {
        let expandedPath = NSString(string: bodyFile).expandingTildeInPath
        let fileDescriptor = expandedPath.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fileDescriptor >= 0 else {
            throw posixError("Could not open private request body")
        }
        defer { _ = Darwin.close(fileDescriptor) }

        var status = stat()
        guard fstat(fileDescriptor, &status) == 0 else {
            throw posixError("Could not inspect private request body")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Request body path must be a regular file"]
            )
        }
        guard status.st_mode & 0o077 == 0 else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Request body file must be owner-only (chmod 600)",
                ]
            )
        }
        guard try !extendedACLStatus(fileDescriptor: fileDescriptor) else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Request body file must not have an extended ACL (use chmod -N)",
                ]
            )
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(maximumPrivateBodyBytes)
        else {
            throw NSError(
                domain: "APIExplorer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Request body exceeds 2 MiB"]
            )
        }
        data = try readBoundedData(fileDescriptor: fileDescriptor)
    }

    guard !data.isEmpty, let body = String(data: data, encoding: .utf8)
    else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Request body must be non-empty UTF-8 under 2 MiB"]
        )
    }
    return body
}

func requiresPrivateBodySource(_ endpoint: String) -> Bool {
    ["get_answer", "get_panel", "streaming_panel"].contains(endpoint)
}

func requiresRedactedWireInspection(_ endpoint: String) -> Bool {
    endpoint == "next" || requiresPrivateBodySource(endpoint)
}

func exploreWireAction(
    _ endpoint: String, bodyJson: String, outputFile: String? = nil
) async {
    let needsAuth = actionNeedsAuthentication(endpoint)
    let authIcon = needsAuth ? "🔐" : "🌐"

    print("\(authIcon) Inspecting wire response: \(endpoint)")
    if needsAuth {
        print("   Auth material: \(hasUsableAuthMaterial() ? "✅ available" : "❌ unavailable")")
    }
    print("   Raw response values stay hidden")
    print()

    guard let bodyData = bodyJson.data(using: .utf8),
          let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    else {
        print("❌ Invalid JSON object body")
        return
    }

    do {
        let response = try await makeWireRequest(
            endpoint: endpoint, body: body, authenticated: needsAuth
        )
        print(wireResponseAuditSummary(
            data: response.data,
            statusCode: response.statusCode,
            contentType: response.contentType
        ))

        if let outputFile {
            try writePrivateOutput(response.data, to: outputFile)
            print("\n💾 Saved raw response with owner-only permissions: \(outputFile)")
            print("   ⚠️ Treat this file as sensitive; it may contain personalized or opaque data.")
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
    }
}

// swiftlint:disable no_print
private func auditSearchFilter(
    _ probe: SearchFilterProbe,
    authenticated: Bool,
    verbose: Bool
) async {
    do {
        let (filterResponse, filterStatus) = try await makeRequest(
            endpoint: "search",
            body: [
                "query": probe.query,
                "params": probe.params,
            ],
            authenticated: authenticated
        )
        print("\n══ \(probe.label) — HTTP \(filterStatus) ══")
        guard isSuccessfulAPIResponse(statusCode: filterStatus, data: filterResponse) else {
            print("  ❌ Filter probe failed: \(apiFailureDescription(statusCode: filterStatus, data: filterResponse))")
            return
        }
        if verbose {
            print("   Params: \(terminalSafe(probe.params))")
        }
        let filterSummary = searchResponseAuditSummary(
            filterResponse,
            sampleLimit: verbose ? 12 : 4,
            context: .firstPage
        )
        print(filterSummary.isEmpty ? "  ⚠️ No recognized YouTube Music search shape" : filterSummary)
        if probe.label == "Podcasts" {
            print("  • Kaset uses a dedicated podcast-show parser for this filter.")
        }

        guard let continuationValue = firstSearchContinuationValue(in: filterResponse) else {
            print("  • Continuation probe: none offered")
            return
        }

        let (continuationResponse, continuationStatus) = try await makeRequest(
            endpoint: "search",
            body: ["continuation": continuationValue],
            authenticated: authenticated
        )
        print("  • Continuation probe via /search: HTTP \(continuationStatus)")
        guard isSuccessfulAPIResponse(
            statusCode: continuationStatus,
            data: continuationResponse
        ) else {
            print("  ❌ Continuation probe failed: \(apiFailureDescription(statusCode: continuationStatus, data: continuationResponse))")
            return
        }
        let continuationSummary = searchResponseAuditSummary(
            continuationResponse,
            sampleLimit: verbose ? 8 : 2,
            context: .continuation
        )
        print(continuationSummary.isEmpty
            ? "  ⚠️ Unrecognized search continuation response shape"
            : continuationSummary)
    } catch {
        print("  ❌ \(probe.label) probe failed: \(error.localizedDescription)")
    }
}

/// Audits the live YouTube Music search response, every filter chip returned by the
/// service, and the first continuation page for each filter that offers one.
func auditSearch(_ query: String, verbose: Bool = false) async {
    guard !youtubeMode else {
        print("❌ search-audit currently supports YouTube Music mode only")
        print("   Use 'action search' for regular YouTube response inspection.")
        return
    }

    let authenticated = !forceUnauthenticatedRequests && hasUsableAuthMaterial()
    let mode = authenticated ? "cookie auth requested (validity unverified)" : "guest"
    print("🔬 Auditing YouTube Music search")
    print("   Query: \(terminalSafe(query))")
    print("   Session: \(mode)")
    print()

    do {
        if ProcessInfo.processInfo.environment[apiKeyEnvironmentVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false {
            await resolveLiveClientVersionIfNeeded(authenticated: authenticated)
        }
        let (baseResponse, baseStatus) = try await makeRequest(
            endpoint: "search",
            body: ["query": query],
            authenticated: authenticated
        )
        let versionSource = if clientVersionWasForced {
            "override"
        } else if cachedClientVersion != nil {
            "live"
        } else {
            "fallback"
        }
        print("   Client version: \(terminalSafe(cachedClientVersion ?? activeFallbackClientVersion)) (\(versionSource))")
        print("══ Unfiltered search — HTTP \(baseStatus) ══")
        guard isSuccessfulAPIResponse(statusCode: baseStatus, data: baseResponse) else {
            print("  ❌ Unfiltered probe failed: \(apiFailureDescription(statusCode: baseStatus, data: baseResponse))")
            return
        }
        let baseSummary = searchResponseAuditSummary(
            baseResponse,
            sampleLimit: verbose ? 20 : 8,
            context: .firstPage
        )
        print(baseSummary.isEmpty ? "  ⚠️ No recognized YouTube Music search shape" : baseSummary)

        let probes = searchFilterProbes(from: baseResponse)
        guard !probes.isEmpty else {
            print("\n⚠️ The unfiltered response exposed no navigable filter chips.")
            return
        }

        print("\n🧭 Probing \(probes.count) live filter chip(s): \(probes.map(\.label).joined(separator: ", "))")
        let unsupportedLabels = probes.map(\.label).filter { !kasetSearchFilterLabels.contains($0) }
        if !unsupportedLabels.isEmpty {
            print("   Filter chips without a dedicated Kaset filter: \(unsupportedLabels.joined(separator: ", "))")
        }

        for probe in probes {
            await auditSearchFilter(probe, authenticated: authenticated, verbose: verbose)
        }
    } catch {
        print("❌ Search audit failed: \(error.localizedDescription)")
    }
}

// swiftlint:enable no_print

/// Explores a continuation request to fetch more items.
/// - Parameters:
///   - token: The continuation token
///   - endpoint: The endpoint to use ("browse" for home/library, "search" for search, "next" for mix queues)
func exploreContinuation(
    _ token: String, endpoint: String = "browse", verbose: Bool = false, outputFile: String? = nil
) async {
    print("🔄 Exploring continuation request")
    print("   Token: present (value hidden)")
    print("   Endpoint: \(endpoint)")
    print()

    var body: [String: Any] = ["continuation": token]
    // Preserve the caller's requested session mode: cookies are used when they
    // are available, while --guest/--no-auth forces a signed-out continuation.
    let authenticated = !forceUnauthenticatedRequests && hasUsableAuthMaterial()
    // For "next" endpoint continuations (mix queues), add required parameters
    if endpoint == "next" {
        body["enablePersistentPlaylistPanel"] = true
        body["isAudioOnly"] = true
    }

    do {
        let (data, statusCode) = try await makeRequest(
            endpoint: endpoint, body: body, authenticated: authenticated
        )

        if statusCode == 401 || statusCode == 403 {
            print("❌ HTTP \(statusCode) - Authentication required")
            return
        }

        print("✅ HTTP \(statusCode)")
        print()
        print(analyzeResponse(
            data,
            verbose: verbose,
            searchAuditContext: endpoint == "search" && !youtubeMode ? .continuation : .automatic
        ))

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
        } else {
            let actionGroups = searchContinuationActionGroups(in: data)
            if !actionGroups.isEmpty {
                print("   Found action-envelope continuation format")
                for (index, group) in actionGroups.enumerated() {
                    print("   └─ Group \(index): \(group.envelope).\(group.command)")
                    print("      └─ continuationItems: \(group.items.count) items")
                }
            } else {
                print("   ⚠️ No recognized continuation format found")
                print("   Top-level keys: \(Array(data.keys))")
            }
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
                try writePrivateOutput(prettyData, to: outputFile)
                print("\n💾 Saved with owner-only permissions: \(outputFile)")
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
    let apiKey: String
    do {
        apiKey = try await resolveAPIKey(authenticated: true)
    } catch let error as ResponseSizeLimitError {
        print("⚠️ Account discovery skipped: \(error.localizedDescription)")
        return nil
    } catch {
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
            ?? extractConfigInteger(named: "SESSION_INDEX", from: html).map(String.init)
        let loggedIn = extractConfigBoolean(named: "LOGGED_IN", from: html)

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
        print("LOGGED_IN:             \(loggedIn.map(String.init) ?? "(absent)")")

        if verbose {
            let missingFields = [
                (name: "DATASYNC_ID", isMissing: dataSyncId == nil),
                (name: "DELEGATED_SESSION_ID", isMissing: delegated == nil),
                (name: "SESSION_INDEX", isMissing: sessionIndex == nil),
            ]
            for field in missingFields where field.isMissing {
                print("  (note: \(field.name) not found in page ytcfg)")
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
        FEmusic_liked_albums          User's saved albums
        FEmusic_liked_videos          Liked songs (returns playlist format)
        FEmusic_history               Listening history (organized by time)
        FEmusic_library_landing       Library overview page
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
        📌 OPTIONAL LIBRARY SORT PARAMS
        ═══════════════════════════════════════════════════════════════════════════════

        ggMGKgQIARAA    Alphabetical A-Z
        ggMGKgQIARAB    Alphabetical Z-A
        ggMGKgQIABAB    Recently Added

        Saved albums use FEmusic_liked_albums and do not require params for the default order.
        Example: swift run api-explorer browse FEmusic_liked_albums

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

        🤖 AI / PANEL TRANSPORTS (experimental, inspect with redacted audit commands)
        ───────────────────────────────────────────────────────────────────────────────
        get_answer                    Timed/polling AI answer command transport
        get_panel                     Engagement-panel continuation/bootstrap transport
        streaming_panel               Chunked engagement-panel response transport
        get_watch                     Combined player + watch-next bootstrap transport

        Audit a video:                swift run api-explorer ask-video-audit <VIDEO_ID>
        Compare Ask request profiles: swift run api-explorer ask-video-parity <VIDEO_ID>
        Inspect wire format:          swift run api-explorer --youtube wire-action <ep> '{}'

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
          action <endpoint> [body]       Explore a JSON action endpoint
          wire-action <endpoint> [body]  Safely inspect JSON, streaming, or opaque responses
          ask-video-audit <videoId>      Audit Ask Gemini / YouChat without sending a prompt
          ask-video-parity <videoId>     Compare ordered read-only Ask request profiles
          ask-video-live-test <videoId>  Replay the server-issued summary suggestion
          ask-video-free-text-test <videoId>
                                         Validate one server-commanded free-text request
          search-audit <query>           Audit live Music search shapes, filters, and continuations
          continuation <token> [ep]      Explore a continuation (ep: 'browse', 'search', or 'next')
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
          -v, --verbose                  Show raw JSON for browse/action/continuation; expand audits
          -o, --output <file>            Save raw output with owner-only permissions (mode 0600)
          --body-file <path|->           Read a sensitive JSON body from a chmod-600 file or stdin
          --prompt-file <path|->         Read a private prompt from a mode-0600 file or stdin
          --confirm-live-ai              Required acknowledgement for live Ask commands
          --fresh-chats N                Run 1-3 independent summary chats (default: 1)
          --follow-up                    Replay the first server-issued follow-up suggestion
          --authuser N                   Use Google account at index N (for multi-account)
          --brand <ID>                   Use brand account ID (21-digit number)
          --client-version <version>     Override the resolved InnerTube client version
          --hl <code>                    Override the InnerTube `hl` language parameter
                                         (default: en). Use to compare how a locale
                                         code localizes real responses.
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
          swift run api-explorer ask-video-audit dQw4w9WgXcQ          # Redacted AI audit
          swift run api-explorer ask-video-parity dQw4w9WgXcQ         # Read-only profile matrix
          swift run api-explorer ask-video-live-test dQw4w9WgXcQ --confirm-live-ai --follow-up
          swift run api-explorer ask-video-free-text-test dQw4w9WgXcQ --confirm-live-ai --prompt-file -
          swift run api-explorer --youtube wire-action get_watch '{"playerRequest":{"videoId":"dQw4w9WgXcQ"},"watchNextRequest":{"videoId":"dQw4w9WgXcQ"}}'
          swift run api-explorer --youtube wire-action streaming_panel --body-file /path/to/private-body.json

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

          # Deeply audit YouTube Music search response coverage
          swift run api-explorer --guest search-audit "ambient electronic mix"

          # Continuation (for pagination / infinite mix)
          swift run api-explorer continuation <token>           # browse endpoint (default)
          swift run api-explorer --guest continuation <token> search # guest filtered search results
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

private func commandLineOptionValue(
    after index: Int,
    in arguments: [String],
    allowSingleDash: Bool = false
) -> String? {
    guard index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    if value == "-" {
        return allowSingleDash ? value : nil
    }
    guard !value.hasPrefix("-") else { return nil }
    return value
}

func runMain() async {
    let args = Array(CommandLine.arguments.dropFirst())
    var verbose = false
    var confirmLiveAI = false
    var includeAskFollowUp = false
    var freshChatCount = 1
    var outputFile: String?
    var bodyFile: String?
    var promptFile: String?
    var filteredArgs: [String] = []

    var index = 0
    while index < args.count {
        let argument = args[index]
        switch argument {
        case "-v", "--verbose":
            verbose = true
        case "--youtube", "--yt":
            activateYouTubeMode()
        case "--no-auth", "--guest":
            forceUnauthenticatedRequests = true
        case "--confirm-live-ai":
            confirmLiveAI = true
        case "--follow-up":
            includeAskFollowUp = true
        case "-o", "--output":
            guard let value = commandLineOptionValue(
                after: index,
                in: args,
                allowSingleDash: true
            ) else {
                print("❌ \(argument) requires a path")
                return
            }
            index += 1
            outputFile = value
        case "--body-file":
            guard let value = commandLineOptionValue(
                after: index,
                in: args,
                allowSingleDash: true
            ) else {
                print("❌ --body-file requires a path or -")
                return
            }
            index += 1
            bodyFile = value
        case "--prompt-file":
            guard let value = commandLineOptionValue(
                after: index,
                in: args,
                allowSingleDash: true
            ) else {
                print("❌ --prompt-file requires a path or -")
                return
            }
            index += 1
            promptFile = value
        case "--authuser":
            guard let rawValue = commandLineOptionValue(after: index, in: args),
                  let value = Int(rawValue),
                  value >= 0
            else {
                print("❌ --authuser requires a nonnegative integer")
                return
            }
            index += 1
            authUserOptionWasSpecified = true
            globalAuthUserIndex = value
        case "--brand":
            guard let value = commandLineOptionValue(after: index, in: args) else {
                print("❌ --brand requires an account ID")
                return
            }
            index += 1
            globalBrandAccountId = value
        case "--hl":
            guard let rawValue = commandLineOptionValue(after: index, in: args) else {
                print("❌ --hl requires a language code")
                return
            }
            index += 1
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("-") else {
                print("❌ Invalid --hl value: provide a language code such as en, ko, or zh-CN")
                return
            }
            globalHl = value
        case "--client-version":
            guard let rawValue = commandLineOptionValue(after: index, in: args) else {
                print("❌ --client-version requires a value")
                return
            }
            index += 1
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("-") else {
                print("❌ Invalid --client-version value: provide a version such as 1.20231204.01.00")
                return
            }
            cachedClientVersion = value
            clientVersionWasForced = true
        case "--fresh-chats":
            guard let rawValue = commandLineOptionValue(after: index, in: args),
                  let value = Int(rawValue),
                  (1 ... 3).contains(value)
            else {
                print("❌ --fresh-chats requires an integer between 1 and 3")
                return
            }
            index += 1
            freshChatCount = value
        case "--":
            filteredArgs.append(contentsOf: args.dropFirst(index + 1))
            index = args.count
            continue
        default:
            filteredArgs.append(argument)
        }
        index += 1
    }

    guard let command = filteredArgs.first else {
        showHelp()
        return
    }
    guard promptFile == nil || command == "ask-video-free-text-test" else {
        print("❌ --prompt-file is supported only by ask-video-free-text-test")
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
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: action <endpoint> [body-json] [--body-file <path|->]")
            return
        }
        do {
            let endpoint = try canonicalAPIEndpoint(filteredArgs[1])
            if requiresPrivateBodySource(endpoint) {
                print("❌ \(endpoint) must use wire-action, not action")
                print("   Sensitive panel responses are always summarized with raw values hidden.")
                return
            }
            let bodyJson = try loadRequestBodyJSON(
                inlineBody: filteredArgs.count >= 3 ? filteredArgs[2] : nil,
                bodyFile: bodyFile
            )
            if requiresRedactedWireInspection(endpoint) {
                await exploreWireAction(
                    endpoint, bodyJson: bodyJson, outputFile: outputFile
                )
            } else {
                await exploreAction(
                    endpoint, bodyJson: bodyJson, verbose: verbose, outputFile: outputFile
                )
            }
        } catch {
            print("❌ \(error.localizedDescription)")
        }

    case "wire-action":
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: wire-action <endpoint> [body-json] [--body-file <path|->]")
            print("   Safely reports structure without printing raw response values.")
            return
        }
        do {
            let endpoint = try canonicalAPIEndpoint(filteredArgs[1])
            if requiresPrivateBodySource(endpoint), bodyFile == nil {
                print("❌ \(endpoint) requires --body-file <chmod-600-path|->")
                print("   Opaque panel/conversation values must not be placed in argv or shell history.")
                return
            }
            let bodyJson = try loadRequestBodyJSON(
                inlineBody: filteredArgs.count >= 3 ? filteredArgs[2] : nil,
                bodyFile: bodyFile
            )
            await exploreWireAction(
                endpoint, bodyJson: bodyJson, outputFile: outputFile
            )
        } catch {
            print("❌ \(error.localizedDescription)")
        }

    case "ask-video-audit":
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: ask-video-audit <videoId>")
            return
        }
        if outputFile != nil {
            print("⚠️ --output is ignored by ask-video-audit; the audit never saves raw payloads")
        }
        await auditAskVideo(filteredArgs[1], verbose: verbose)

    case "ask-video-parity":
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: ask-video-parity <videoId>")
            return
        }
        await auditAskVideoRequestParity(
            filteredArgs[1],
            hasUnsupportedOptions: filteredArgs.count != 2
                || outputFile != nil
                || bodyFile != nil
                || clientVersionWasForced
                || includeAskFollowUp
                || freshChatCount != 1
        )

    case "ask-video-live-test":
        guard filteredArgs.count == 2 else {
            print("❌ Usage: ask-video-live-test <videoId> --confirm-live-ai [--follow-up] [--fresh-chats N]")
            return
        }
        guard confirmLiveAI else {
            print("❌ ask-video-live-test requires --confirm-live-ai")
            print("   This command sends the server-issued summary suggestion to YouTube.")
            return
        }
        guard outputFile == nil,
              bodyFile == nil,
              !clientVersionWasForced,
              !forceUnauthenticatedRequests,
              !authUserOptionWasSpecified,
              globalBrandAccountId == nil
        else {
            print("❌ ask-video-live-test received an unsupported authentication, client, or file option")
            print("   Supported options: --confirm-live-ai, --follow-up, --fresh-chats N, --verbose")
            return
        }
        await liveTestAskVideo(
            filteredArgs[1],
            freshChatCount: freshChatCount,
            includeFollowUp: includeAskFollowUp,
            verbose: verbose
        )

    case "ask-video-free-text-test":
        guard filteredArgs.count == 2 else {
            print("❌ Usage: ask-video-free-text-test <videoId> --confirm-live-ai --prompt-file <chmod-600-path|->")
            return
        }
        guard confirmLiveAI else {
            print("❌ ask-video-free-text-test requires --confirm-live-ai")
            print("   This command submits one private free-text prompt to YouTube.")
            return
        }
        guard let promptFile else {
            print("❌ ask-video-free-text-test requires --prompt-file <chmod-600-path|->")
            return
        }
        guard outputFile == nil,
              bodyFile == nil,
              !verbose,
              !clientVersionWasForced,
              !forceUnauthenticatedRequests,
              !authUserOptionWasSpecified,
              globalBrandAccountId == nil,
              !includeAskFollowUp,
              freshChatCount == 1
        else {
            print("❌ ask-video-free-text-test received an unsupported option or account mode")
            print("   Supported options: --confirm-live-ai and --prompt-file <chmod-600-path|->")
            return
        }
        do {
            let prompt = try loadPrivatePrompt(from: promptFile)
            await liveTestAskVideoFreeText(filteredArgs[1], prompt: prompt)
        } catch {
            print("❌ Could not load the private prompt: \(error.localizedDescription)")
        }

    case "search-audit":
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: search-audit <query>")
            print("   Example: search-audit \"ambient electronic mix\"")
            return
        }
        if outputFile != nil {
            print("⚠️ --output is ignored by search-audit; use 'action search' to save raw JSON")
        }
        await auditSearch(filteredArgs[1], verbose: verbose)

    case "continuation":
        guard filteredArgs.count >= 2 else {
            print("❌ Usage: continuation <token> [endpoint]")
            print("   endpoint: 'browse' (default), 'search' for search, or 'next' for mix queues")
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
