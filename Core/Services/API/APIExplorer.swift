import Foundation

// MARK: - APIExplorer

/// A development utility for exploring and documenting YouTube Music API endpoints.
///
/// ## Purpose
/// This tool enables discovery and testing of YouTube Music API endpoints to identify
/// new functionality that can be implemented in the app. It provides structured exploration
/// of both browse endpoints (content pages) and action endpoints (API operations).
///
/// ## Usage
/// ```swift
/// // In a test or debug context:
/// let explorer = APIExplorer(webKitManager: .shared)
///
/// // Explore a specific browse endpoint
/// let result = await explorer.exploreBrowseEndpoint("FEmusic_charts")
/// DiagnosticsLogger.api.info("\(result.summary)")
///
/// // Explore an action endpoint
/// let actionResult = await explorer.exploreActionEndpoint("player", body: ["videoId": "dQw4w9WgXcQ"])
/// DiagnosticsLogger.api.info("\(actionResult.responseKeys)")
/// ```
///
/// ## Security Note
/// This class is intended for development/debugging only. It logs response structures
/// but not sensitive user data. Do not use in production builds.
///
/// ## Documentation
/// Results from exploration should be documented in `docs/api-discovery.md`.
/// When new endpoints are implemented, update the documentation status accordingly.
@MainActor
final class APIExplorer {
    // MARK: - Types

    /// Result of exploring a browse endpoint.
    struct BrowseResult: Sendable {
        /// The browse ID that was explored (e.g., "FEmusic_charts")
        let browseId: String

        /// Whether the request succeeded
        let success: Bool

        /// HTTP status code if available
        let statusCode: Int?

        /// Error message if the request failed
        let errorMessage: String?

        /// Top-level keys in the response JSON
        let responseKeys: [String]

        /// Number of sections found (if applicable)
        let sectionCount: Int

        /// Types of sections found (e.g., ["musicCarouselShelfRenderer", "gridRenderer"])
        let sectionTypes: [String]

        /// Whether authentication appears to be required
        let requiresAuth: Bool

        /// The params value used (if any)
        let params: String?

        /// Raw response data for detailed inspection
        let rawResponse: [String: Any]?

        /// A human-readable summary of the exploration result
        var summary: String {
            if !self.success {
                let authNote = self.requiresAuth ? " (requires authentication)" : ""
                let paramsNote = self.params != nil ? " [params: \(self.params!)]" : ""
                return "❌ \(self.browseId): \(self.errorMessage ?? "Unknown error")\(authNote)\(paramsNote)"
            }
            let sectionInfo = self.sectionCount > 0 ? ", \(self.sectionCount) sections" : ""
            let typesInfo = self.sectionTypes.isEmpty ? "" : " [\(self.sectionTypes.joined(separator: ", "))]"
            let paramsNote = self.params != nil ? " [params: \(self.params!)]" : ""
            return "✅ \(self.browseId): \(self.responseKeys.count) keys\(sectionInfo)\(typesInfo)\(paramsNote)"
        }
    }

    /// Result of exploring a browse endpoint with params variations.
    struct ParamsExplorationResult: Sendable {
        /// A single param test result
        struct ParamTestResult: Sendable {
            let params: String
            let paramsDescription: String
            let statusCode: Int?
            let success: Bool
            let errorMessage: String?
        }

        let browseId: String
        let results: [ParamTestResult]

        var summary: String {
            var lines = ["📊 Params exploration for \(browseId):"]
            for result in self.results {
                let status = result.success ? "✅" : "❌"
                let code = result.statusCode.map { "HTTP \($0)" } ?? "Error"
                let error = result.errorMessage ?? ""
                lines.append("  \(status) \(result.paramsDescription): \(code) \(error)")
            }
            return lines.joined(separator: "\n")
        }

        var workingParams: [String] {
            self.results.filter(\.success).map(\.params)
        }
    }

    /// Result of exploring an action endpoint.
    struct ActionResult: Sendable {
        /// The endpoint path (e.g., "player", "music/get_queue")
        let endpoint: String

        /// Whether the request succeeded
        let success: Bool

        /// HTTP status code if available
        let statusCode: Int?

        /// Error message if the request failed
        let errorMessage: String?

        /// Top-level keys in the response JSON
        let responseKeys: [String]

        /// Whether authentication appears to be required
        let requiresAuth: Bool

        /// Approximate response size in bytes
        let responseSize: Int

        /// Raw response data for detailed inspection
        let rawResponse: [String: Any]?

        /// A human-readable summary
        var summary: String {
            if !self.success {
                let authNote = self.requiresAuth ? " (requires authentication)" : ""
                return "❌ \(self.endpoint): \(self.errorMessage ?? "Unknown error")\(authNote)"
            }
            let sizeKB = self.responseSize / 1024
            return "✅ \(self.endpoint): \(self.responseKeys.count) keys, ~\(sizeKB)KB response"
        }
    }

    /// Result of exploring authentication status.
    struct AuthStatus: Sendable {
        let isAuthenticated: Bool
        let hasSAPISID: Bool
        let hasCookies: Bool
        let cookieCount: Int
        let authTestEndpoint: String?
        let authTestResult: Bool?

        var summary: String {
            var lines = ["🔐 Authentication Status:"]
            lines.append("  Cookies available: \(self.hasCookies) (\(self.cookieCount) cookies)")
            lines.append("  SAPISID present: \(self.hasSAPISID)")
            lines.append("  Authenticated: \(self.isAuthenticated)")
            if let endpoint = authTestEndpoint, let result = authTestResult {
                let icon = result ? "✅" : "❌"
                lines.append("  Auth test (\(endpoint)): \(icon)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Detailed response structure for debugging.
    struct ResponseStructure: Sendable {
        let endpoint: String
        let keys: [String]
        let nestedStructure: [String: [String]]
        let containsLoginPrompt: Bool
        let hasUserData: Bool

        var summary: String {
            var lines = ["📋 Response structure for \(endpoint):"]
            lines.append("  Top-level keys: \(self.keys.joined(separator: ", "))")
            lines.append("  Contains login prompt: \(self.containsLoginPrompt)")
            lines.append("  Has user data: \(self.hasUserData)")
            if !self.nestedStructure.isEmpty {
                lines.append("  Nested structure:")
                for (key, subkeys) in self.nestedStructure.sorted(by: { $0.key < $1.key }) {
                    lines.append("    \(key): \(subkeys.joined(separator: ", "))")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Properties

    private let webKitManager: WebKitManager
    private let logger = DiagnosticsLogger.api

    /// YouTube Music API base URL
    private static let baseURL = "https://music.youtube.com/youtubei/v1"

    /// API key (extracted from YouTube Music web client)
    private static let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"

    /// Client version for WEB_REMIX
    private static let clientVersion = "1.20231204.01.00"

    // MARK: - Initialization

    /// Creates an API explorer instance.
    /// - Parameter webKitManager: The WebKit manager for cookie access
    init(webKitManager: WebKitManager = .shared) {
        self.webKitManager = webKitManager
    }

    // MARK: - Exploration Methods

    /// Explores a browse endpoint and returns structured results.
    /// - Parameters:
    ///   - browseId: The browse ID to explore (e.g., "FEmusic_charts")
    ///   - params: Optional params value for library endpoints
    ///   - includeRawResponse: Whether to include the raw response data
    /// - Returns: A BrowseResult with information about the endpoint
    func exploreBrowseEndpoint(
        _ browseId: String,
        params: String? = nil,
        includeRawResponse: Bool = false
    ) async -> BrowseResult {
        self.logger.info("[APIExplorer] Exploring browse endpoint: \(browseId)")

        var body: [String: Any] = ["browseId": browseId]
        if let params {
            body["params"] = params
        }

        do {
            let (data, statusCode) = try await makeRequest("browse", body: body)

            let responseKeys = Array(data.keys).sorted()
            let (sectionCount, sectionTypes) = self.parseSectionInfo(from: data)

            return BrowseResult(
                browseId: browseId,
                success: true,
                statusCode: statusCode,
                errorMessage: nil,
                responseKeys: responseKeys,
                sectionCount: sectionCount,
                sectionTypes: sectionTypes,
                requiresAuth: false,
                params: params,
                rawResponse: includeRawResponse ? data : nil
            )
        } catch let error as ExplorerError {
            return BrowseResult(
                browseId: browseId,
                success: false,
                statusCode: error.statusCode,
                errorMessage: error.message,
                responseKeys: [],
                sectionCount: 0,
                sectionTypes: [],
                requiresAuth: error.statusCode == 401 || error.statusCode == 403,
                params: params,
                rawResponse: nil
            )
        } catch {
            return BrowseResult(
                browseId: browseId,
                success: false,
                statusCode: nil,
                errorMessage: error.localizedDescription,
                responseKeys: [],
                sectionCount: 0,
                sectionTypes: [],
                requiresAuth: false,
                params: params,
                rawResponse: nil
            )
        }
    }

    /// Explores a browse endpoint with all known params variations.
    /// Use this to discover which params work for library endpoints.
    /// - Parameter browseId: The browse ID to test (e.g., "FEmusic_library_albums")
    /// - Returns: A ParamsExplorationResult showing which params work
    func exploreWithAllParams(_ browseId: String) async -> ParamsExplorationResult {
        self.logger.info("[APIExplorer] Testing all params for: \(browseId)")

        var results: [ParamsExplorationResult.ParamTestResult] = []

        // First try without params
        let noParamsResult = await exploreBrowseEndpoint(browseId, params: nil)
        results.append(ParamsExplorationResult.ParamTestResult(
            params: "",
            paramsDescription: "No params",
            statusCode: noParamsResult.statusCode,
            success: noParamsResult.success,
            errorMessage: noParamsResult.errorMessage
        ))

        // Try all known params variations
        for param in LibraryParams.allCases {
            let result = await exploreBrowseEndpoint(browseId, params: param.rawValue)
            results.append(ParamsExplorationResult.ParamTestResult(
                params: param.rawValue,
                paramsDescription: param.description,
                statusCode: result.statusCode,
                success: result.success,
                errorMessage: result.errorMessage
            ))
        }

        return ParamsExplorationResult(browseId: browseId, results: results)
    }

    /// Checks current authentication status.
    /// - Returns: AuthStatus with details about cookie and auth availability
    func checkAuthStatus() async -> AuthStatus {
        self.logger.info("[APIExplorer] Checking authentication status")

        let hasCookies = await webKitManager.cookieHeader(for: "youtube.com") != nil
        let hasSAPISID = await webKitManager.getSAPISID() != nil

        // Count cookies
        var cookieCount = 0
        if let cookieHeader = await webKitManager.cookieHeader(for: "youtube.com") {
            cookieCount = cookieHeader.components(separatedBy: ";").count
        }

        // Test auth with a known auth-required endpoint
        let testResult = await exploreBrowseEndpoint("FEmusic_liked_playlists")
        let isAuthenticated = testResult.success && testResult.statusCode == 200

        return AuthStatus(
            isAuthenticated: isAuthenticated,
            hasSAPISID: hasSAPISID,
            hasCookies: hasCookies,
            cookieCount: cookieCount,
            authTestEndpoint: "FEmusic_liked_playlists",
            authTestResult: isAuthenticated
        )
    }

    /// Analyzes the response structure of an endpoint in detail.
    /// - Parameters:
    ///   - browseId: The browse ID to analyze
    ///   - params: Optional params value
    /// - Returns: ResponseStructure with detailed analysis
    func analyzeResponseStructure(_ browseId: String, params: String? = nil) async -> ResponseStructure {
        self.logger.info("[APIExplorer] Analyzing response structure for: \(browseId)")

        let result = await exploreBrowseEndpoint(browseId, params: params, includeRawResponse: true)

        guard let response = result.rawResponse else {
            return ResponseStructure(
                endpoint: browseId,
                keys: result.responseKeys,
                nestedStructure: [:],
                containsLoginPrompt: false,
                hasUserData: false
            )
        }

        // Check for login prompt indicators
        let responseString = String(describing: response)
        let containsLoginPrompt = responseString.contains("Sign in") ||
            responseString.contains("signInEndpoint") ||
            responseString.contains("loginRequired")

        // Check for user data indicators
        let hasUserData = responseString.contains("playlistId") ||
            responseString.contains("videoId") ||
            responseString.contains("musicResponsiveListItemRenderer")

        // Build nested structure (one level deep)
        var nestedStructure: [String: [String]] = [:]
        for (key, value) in response {
            if let dict = value as? [String: Any] {
                nestedStructure[key] = Array(dict.keys).sorted()
            } else if let array = value as? [[String: Any]], let first = array.first {
                nestedStructure["\(key)[0]"] = Array(first.keys).sorted()
            }
        }

        return ResponseStructure(
            endpoint: browseId,
            keys: result.responseKeys,
            nestedStructure: nestedStructure,
            containsLoginPrompt: containsLoginPrompt,
            hasUserData: hasUserData
        )
    }

    /// Explores all library endpoints with various params to discover working combinations.
    /// - Returns: Dictionary of browseId to working params
    func discoverLibraryParams() async -> [String: [String]] {
        self.logger.info("[APIExplorer] Discovering library params")

        let libraryEndpoints = [
            "FEmusic_library_albums",
            "FEmusic_library_artists",
            "FEmusic_library_songs",
            "FEmusic_history",
            "FEmusic_recently_played",
            "FEmusic_library_landing",
        ]

        var workingParams: [String: [String]] = [:]

        for endpoint in libraryEndpoints {
            let result = await exploreWithAllParams(endpoint)
            workingParams[endpoint] = result.workingParams
            self.logger.info("[APIExplorer] \(result.summary)")
        }

        return workingParams
    }

    /// Explores an action endpoint and returns structured results.
    /// - Parameters:
    ///   - endpoint: The endpoint path (e.g., "player", "music/get_queue")
    ///   - body: The request body parameters
    ///   - includeRawResponse: Whether to include the raw response data
    /// - Returns: An ActionResult with information about the endpoint
    func exploreActionEndpoint(
        _ endpoint: String,
        body: [String: Any],
        includeRawResponse: Bool = false
    ) async -> ActionResult {
        self.logger.info("[APIExplorer] Exploring action endpoint: \(endpoint)")

        do {
            let (data, statusCode) = try await makeRequest(endpoint, body: body)
            let responseKeys = Array(data.keys).sorted()

            // Estimate response size
            let jsonData = try? JSONSerialization.data(withJSONObject: data)
            let responseSize = jsonData?.count ?? 0

            return ActionResult(
                endpoint: endpoint,
                success: true,
                statusCode: statusCode,
                errorMessage: nil,
                responseKeys: responseKeys,
                requiresAuth: false,
                responseSize: responseSize,
                rawResponse: includeRawResponse ? data : nil
            )
        } catch let error as ExplorerError {
            return ActionResult(
                endpoint: endpoint,
                success: false,
                statusCode: error.statusCode,
                errorMessage: error.message,
                responseKeys: [],
                requiresAuth: error.statusCode == 401 || error.statusCode == 403,
                responseSize: 0,
                rawResponse: nil
            )
        } catch {
            return ActionResult(
                endpoint: endpoint,
                success: false,
                statusCode: nil,
                errorMessage: error.localizedDescription,
                responseKeys: [],
                requiresAuth: false,
                responseSize: 0,
                rawResponse: nil
            )
        }
    }

    /// Explores all known browse endpoints and returns results.
    /// - Parameter includeImplemented: Whether to include already-implemented endpoints
    /// - Returns: Array of BrowseResult for each endpoint
    func exploreAllBrowseEndpoints(includeImplemented: Bool = false) async -> [BrowseResult] {
        let endpoints = Self.browseEndpoints.filter { includeImplemented || !$0.isImplemented }
        var results: [BrowseResult] = []

        for endpoint in endpoints {
            let result = await exploreBrowseEndpoint(endpoint.id)
            results.append(result)
        }

        return results
    }

    /// Runs a comprehensive exploration of all endpoints and generates a report.
    /// This is useful for getting a complete picture of the API surface.
    /// - Returns: A comprehensive markdown report
    func runFullExploration() async -> String {
        self.logger.info("[APIExplorer] Running full API exploration")

        var report = """
        # Full API Exploration Report

        Generated: \(ISO8601DateFormatter().string(from: Date()))

        ## Authentication Status

        """

        // Check auth first
        let authStatus = await checkAuthStatus()
        report += authStatus.summary + "\n\n"

        report += "## Browse Endpoints\n\n"

        // Test all browse endpoints
        for endpoint in Self.browseEndpoints {
            let result = await exploreBrowseEndpoint(endpoint.id)
            report += "### \(endpoint.name) (`\(endpoint.id)`)\n\n"
            report += "- **Description**: \(endpoint.description)\n"
            report += "- **Requires Auth**: \(endpoint.requiresAuth ? "Yes" : "No")\n"
            report += "- **Implemented**: \(endpoint.isImplemented ? "Yes" : "No")\n"
            report += "- **Status**: \(result.summary)\n"
            if let notes = endpoint.notes {
                report += "- **Notes**: \(notes)\n"
            }

            // If it failed and needs params, try params exploration
            if !result.success, endpoint.id.contains("library_") {
                report += "- **Params exploration**:\n"
                for param in [LibraryParams.recentlyAdded, .alphabeticalAZ, .defaultSort] {
                    let paramResult = await exploreBrowseEndpoint(endpoint.id, params: param.rawValue)
                    let status = paramResult.success ? "✅" : "❌ HTTP \(paramResult.statusCode ?? 0)"
                    report += "  - \(param.description): \(status)\n"
                }
            }
            report += "\n"
        }

        report += "## Action Endpoints\n\n"

        // Test key action endpoints
        let testActions: [(endpoint: String, body: [String: Any])] = [
            ("player", ["videoId": "dQw4w9WgXcQ"]),
            ("music/get_queue", ["videoIds": ["dQw4w9WgXcQ"]]),
            ("playlist/get_add_to_playlist", ["videoId": "dQw4w9WgXcQ"]),
        ]

        for (endpointId, body) in testActions {
            if let endpoint = Self.actionEndpoints.first(where: { $0.id == endpointId }) {
                let result = await exploreActionEndpoint(endpointId, body: body)
                report += "### \(endpoint.name) (`\(endpointId)`)\n\n"
                report += "- **Description**: \(endpoint.description)\n"
                report += "- **Requires Auth**: \(endpoint.requiresAuth ? "Yes" : "No")\n"
                report += "- **Implemented**: \(endpoint.isImplemented ? "Yes" : "No")\n"
                report += "- **Status**: \(result.summary)\n"
                if let notes = endpoint.notes {
                    report += "- **Notes**: \(notes)\n"
                }
                report += "\n"
            }
        }

        report += """

        ## Library Params Discovery

        Testing which params values work for library endpoints:

        """

        let libraryParams = await discoverLibraryParams()
        for (endpoint, working) in libraryParams.sorted(by: { $0.key < $1.key }) {
            if working.isEmpty {
                report += "- **\(endpoint)**: No working params found\n"
            } else {
                report += "- **\(endpoint)**: \(working.count) working params\n"
                for param in working {
                    if let libParam = LibraryParams(rawValue: param) {
                        report += "  - `\(param)` (\(libParam.description))\n"
                    } else {
                        report += "  - `\(param)`\n"
                    }
                }
            }
        }

        return report
    }

    /// Generates a markdown report of all endpoints.
    /// - Returns: A formatted markdown string documenting all endpoints
    func generateEndpointReport() async -> String {
        var report = """
        # YouTube Music API Endpoint Report

        Generated: \(ISO8601DateFormatter().string(from: Date()))

        ## Authentication Status

        """

        let authStatus = await checkAuthStatus()
        report += authStatus.summary + "\n\n"

        report += """
        ## Browse Endpoints

        | ID | Name | Auth | Implemented | Status |
        |----|------|------|-------------|--------|

        """

        // Add browse endpoints
        for endpoint in Self.browseEndpoints {
            let authIcon = endpoint.requiresAuth ? "🔐" : "🌐"
            let implIcon = endpoint.isImplemented ? "✅" : "⏳"
            let result = await exploreBrowseEndpoint(endpoint.id)
            let statusIcon = result.success ? "✅" : (result.requiresAuth ? "🔒" : "❌")

            report += "| `\(endpoint.id)` | \(endpoint.name) | \(authIcon) | \(implIcon) | \(statusIcon) |\n"
        }

        report += """

        ## Action Endpoints

        | Endpoint | Name | Auth | Implemented |
        |----------|------|------|-------------|

        """

        // Add action endpoints
        for endpoint in Self.actionEndpoints {
            let authIcon = endpoint.requiresAuth ? "🔐" : "🌐"
            let implIcon = endpoint.isImplemented ? "✅" : "⏳"

            report += "| `\(endpoint.id)` | \(endpoint.name) | \(authIcon) | \(implIcon) |\n"
        }

        report += """

        ## Legend

        - 🌐 = No authentication required
        - 🔐 = Authentication required
        - ✅ = Implemented / Working
        - ⏳ = Not yet implemented
        - 🔒 = Auth required (returned 401/403)
        - ❌ = Error (not auth-related)

        """

        return report
    }

    /// Tests a custom params value for a library endpoint.
    /// Use this when you've captured a new params value from the web client.
    /// - Parameters:
    ///   - browseId: The browse ID to test
    ///   - params: The base64-encoded params value
    /// - Returns: BrowseResult with detailed information
    func testCustomParams(_ browseId: String, params: String) async -> BrowseResult {
        self.logger.info("[APIExplorer] Testing custom params for \(browseId): \(params)")
        return await self.exploreBrowseEndpoint(browseId, params: params, includeRawResponse: true)
    }

    /// Decodes a base64 params value to show its raw bytes (for debugging).
    /// - Parameter params: The base64-encoded params value
    /// - Returns: A hex dump of the decoded bytes
    func decodeParams(_ params: String) -> String {
        guard let data = Data(base64Encoded: params) else {
            return "Invalid base64"
        }
        let bytes = data.map { String(format: "%02x", $0) }
        return "Decoded \(data.count) bytes: \(bytes.joined(separator: " "))"
    }

    /// Prints usage instructions for the API Explorer.
    static var usageInstructions: String {
        """
        # APIExplorer Usage Guide

        ## Quick Start

        ```swift
        let explorer = APIExplorer()

        // Check auth status
        let auth = await explorer.checkAuthStatus()
        DiagnosticsLogger.api.info("\\(auth.summary)")

        // Explore a specific endpoint
        let result = await explorer.exploreBrowseEndpoint("FEmusic_charts")
        DiagnosticsLogger.api.info("\\(result.summary)")

        // Explore with params (for library endpoints)
        let libResult = await explorer.exploreBrowseEndpoint(
            "FEmusic_library_albums",
            params: LibraryParams.recentlyAdded.rawValue
        )
        DiagnosticsLogger.api.info("\\(libResult.summary)")

        // Discover which params work
        let paramsResult = await explorer.exploreWithAllParams("FEmusic_library_albums")
        DiagnosticsLogger.api.info("\\(paramsResult.summary)")

        // Run full exploration
        let report = await explorer.runFullExploration()
        DiagnosticsLogger.api.info("\\(report)")
        ```

        ## Key Methods

        - `checkAuthStatus()` - Verify cookies and SAPISIDHASH are available
        - `exploreBrowseEndpoint(_:params:)` - Test a browse endpoint
        - `exploreWithAllParams(_:)` - Try all known params variations
        - `discoverLibraryParams()` - Find working params for library endpoints
        - `analyzeResponseStructure(_:)` - Get detailed response analysis
        - `runFullExploration()` - Generate comprehensive report
        - `testCustomParams(_:params:)` - Test a captured params value

        ## Capturing Params from Web Client

        1. Open music.youtube.com in Chrome
        2. Open DevTools → Network tab
        3. Navigate to Library → Albums (or Songs, Artists)
        4. Find the `browse` request in Network tab
        5. Look at the request payload for `params` field
        6. Test with: `await explorer.testCustomParams("FEmusic_library_albums", params: "...")`

        """
    }

    // MARK: - Private Methods

    /// Internal error type for exploration
    private struct ExplorerError: Error {
        let message: String
        let statusCode: Int?
    }

    /// Makes an API request and returns the parsed response.
    private func makeRequest(_ endpoint: String, body: [String: Any]) async throws -> ([String: Any], Int) {
        let urlString = "\(Self.baseURL)/\(endpoint)?key=\(Self.apiKey)&prettyPrint=false"
        guard let url = URL(string: urlString) else {
            throw ExplorerError(message: "Invalid URL", statusCode: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Add headers
        let headers = try await buildHeaders()
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Build body with context
        var fullBody = body
        fullBody["context"] = self.buildContext()

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExplorerError(message: "Invalid response", statusCode: nil)
        }

        let statusCode = httpResponse.statusCode

        guard (200 ... 299).contains(statusCode) else {
            throw ExplorerError(
                message: "HTTP \(statusCode)",
                statusCode: statusCode
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExplorerError(message: "Invalid JSON", statusCode: statusCode)
        }

        return (json, statusCode)
    }

    /// Builds request headers including authentication if available.
    private func buildHeaders() async throws -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        ]

        // Try to add auth headers if cookies are available
        if let cookieHeader = await webKitManager.cookieHeader(for: "youtube.com"),
           let sapisid = await webKitManager.getSAPISID()
        {
            let origin = WebKitManager.origin
            let timestamp = Int(Date().timeIntervalSince1970)
            let hashInput = "\(timestamp) \(sapisid) \(origin)"

            // Import CryptoKit for SHA1
            let hashData = Data(hashInput.utf8)
            var sha1 = [UInt8](repeating: 0, count: 20)
            hashData.withUnsafeBytes { buffer in
                _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &sha1)
            }
            let hash = sha1.map { String(format: "%02x", $0) }.joined()
            let sapisidhash = "\(timestamp)_\(hash)"

            headers["Cookie"] = cookieHeader
            headers["Authorization"] = "SAPISIDHASH \(sapisidhash)"
            headers["Origin"] = origin
            headers["Referer"] = origin
            headers["X-Goog-AuthUser"] = "0"
            headers["X-Origin"] = origin
        }

        return headers
    }

    /// Builds the standard API context.
    private func buildContext() -> [String: Any] {
        [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": Self.clientVersion,
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

    /// Parses section information from a browse response.
    private func parseSectionInfo(from data: [String: Any]) -> (count: Int, types: [String]) {
        var sectionTypes: Set<String> = []
        var sectionCount = 0

        // Navigate to contents
        guard let contents = data["contents"] as? [String: Any] else {
            return (0, [])
        }

        // Try singleColumnBrowseResultsRenderer
        if let singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
           let tabs = singleColumn["tabs"] as? [[String: Any]]
        {
            for tab in tabs {
                if let tabRenderer = tab["tabRenderer"] as? [String: Any],
                   let tabContent = tabRenderer["content"] as? [String: Any],
                   let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
                   let sections = sectionListRenderer["contents"] as? [[String: Any]]
                {
                    sectionCount = sections.count
                    for section in sections {
                        sectionTypes.formUnion(section.keys)
                    }
                }
            }
        }

        // Try tabbedSearchResultsRenderer (for search)
        if let tabbedSearch = contents["tabbedSearchResultsRenderer"] as? [String: Any],
           let tabs = tabbedSearch["tabs"] as? [[String: Any]]
        {
            for tab in tabs {
                if let tabRenderer = tab["tabRenderer"] as? [String: Any],
                   let tabContent = tabRenderer["content"] as? [String: Any],
                   let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
                   let sections = sectionListRenderer["contents"] as? [[String: Any]]
                {
                    sectionCount += sections.count
                    for section in sections {
                        sectionTypes.formUnion(section.keys)
                    }
                }
            }
        }

        return (sectionCount, Array(sectionTypes).sorted())
    }
}

// MARK: - CommonCrypto Import for SHA1

import CommonCrypto
