import Foundation
import YouTubeAskCore

/// A parity profile is eligible for selection only when YouTube explicitly
/// confirms the request was handled as signed in. A missing marker is not
/// equivalent to `loggedOut: false` and must fail closed.
func askParityHasConfirmedSignedInState(_ loggedOut: Bool?) -> Bool {
    loggedOut == false
}

func askVideoAuditSummary(_ response: [String: Any]) -> String {
    var auditor = AskVideoResponseAuditor()
    return auditor.audit(response).rendered()
}

func wireResponseAuditSummary(data: Data, statusCode: Int, contentType: String?) -> String {
    WireResponseAuditor.summary(data: data, statusCode: statusCode, contentType: contentType)
}

func extractYouTubeMainAppJavaScriptURL(from html: String, baseURL: URL) -> URL? {
    YouTubeMainAppScriptExtractor.extract(from: html, baseURL: baseURL)
}

func youtubeAIFrontendCapabilitySummary(html: String, mainJavaScript: String?) -> String {
    YouTubeAIFrontendCapabilityAuditor.summary(html: html, mainJavaScript: mainJavaScript)
}

func youtubeAIFrontendFlowDebugSummary(mainJavaScript: String) -> String {
    YouTubeAIFrontendFlowDebugAuditor.summary(mainJavaScript: mainJavaScript)
}

// MARK: - Ask workflow

private func fetchYouTubeWebResource(
    _ url: URL,
    authenticated: Bool
) async throws -> APIWireResponse {
    guard url.scheme?.lowercased() == "https",
          url.host?.lowercased() == "www.youtube.com",
          url.port == nil || url.port == 443
    else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Only HTTPS www.youtube.com resources are allowed"]
        )
    }

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

    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )

    let (data, response) = try await boundedResponseData(
        configuration: configuration,
        request: request,
        maximumBytes: maximumAskWebResourceBytes
    )
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.url?.scheme?.lowercased() == "https",
          httpResponse.url?.host?.lowercased() == "www.youtube.com",
          httpResponse.url?.port == nil || httpResponse.url?.port == 443
    else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid or cross-origin web response"]
        )
    }

    return APIWireResponse(
        data: data,
        statusCode: httpResponse.statusCode,
        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
    )
}

private func normalizedMediaType(_ contentType: String?) -> String? {
    contentType?
        .split(separator: ";", maxSplits: 1)
        .first
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

private func isValidYouTubeVideoID(_ value: String) -> Bool {
    guard (6 ... 20).contains(value.count) else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
            true
        default:
            false
        }
    }
}

private func serverLoggedOutState(in response: [String: Any]) -> Bool? {
    if let responseContext = response["responseContext"] as? [String: Any],
       let mainAppContext = responseContext["mainAppWebResponseContext"] as? [String: Any],
       let loggedOut = mainAppContext["loggedOut"] as? Bool
    {
        return loggedOut
    }
    if let watchNextResponse = response["watchNextResponse"] as? [String: Any] {
        return serverLoggedOutState(in: watchNextResponse)
    }
    return nil
}

// MARK: - AskRuntimeWEBConfiguration

private struct AskRuntimeWEBConfiguration {
    let runtimeAPIIdentifier: String
    let clientVersion: String
    let visitorData: String
}

private let maximumAskWebResourceBytes = 24 * 1024 * 1024
private let maximumAskConfigurationResponseBytes = 8 * 1024 * 1024

// MARK: - AskParityFailureCategory

private enum AskParityFailureCategory: String {
    case none
    case invalidVideoID = "invalid-video-id"
    case authenticationUnavailable = "authentication-unavailable"
    case unsupportedAccountSelection = "unsupported-account-selection"
    case unsupportedOptions = "unsupported-options"
    case runtimeConfigurationUnavailable = "runtime-configuration-unavailable"
    case requestConfigurationUnavailable = "request-configuration-unavailable"
    case nextNetworkFailure = "next-network-failure"
    case nextResponseTooLarge = "next-response-too-large"
    case nextAuthenticationRejected = "next-authentication-rejected"
    case nextRateLimited = "next-rate-limited"
    case nextHTTPFailure = "next-http-failure"
    case nextDecodeFailure = "next-decode-failure"
    case nextParseFailure = "next-parse-failure"
    case ineligible
    case panelCommandUnavailable = "panel-command-unavailable"
    case panelNetworkFailure = "panel-network-failure"
    case panelResponseTooLarge = "panel-response-too-large"
    case panelAuthenticationRejected = "panel-authentication-rejected"
    case panelRateLimited = "panel-rate-limited"
    case panelHTTPFailure = "panel-http-failure"
    case panelDecodeFailure = "panel-decode-failure"
    case panelParseFailure = "panel-parse-failure"
    case summarySuggestionUnavailable = "summary-suggestion-unavailable"
}

// MARK: - AskParityStageMetrics

private struct AskParityStageMetrics {
    var statusCode: Int?
    var byteCount: Int?
    var wireFormat: String?

    var statusDescription: String {
        self.statusCode.map(String.init) ?? "not-run"
    }

    var sizeDescription: String {
        self.byteCount.map(String.init) ?? "not-run"
    }

    var formatDescription: String {
        self.wireFormat ?? "not-run"
    }
}

// MARK: - AskParityCapabilityState

private enum AskParityCapabilityState: String {
    case notRun = "not-run"
    case absent
    case present
}

// MARK: - AskParityReport

private struct AskParityReport {
    let profileName: String
    var next = AskParityStageMetrics()
    var panel = AskParityStageMetrics()
    var eligibility = "unknown"
    var nextChipCount = 0
    var panelChipCount = 0
    var nextFreeTextCapability = AskParityCapabilityState.notRun
    var panelFreeTextCapability = AskParityCapabilityState.notRun
    var failureCategory: AskParityFailureCategory

    func render() {
        print("profile: \(self.profileName)")
        print("status: next=\(self.next.statusDescription) panel=\(self.panel.statusDescription)")
        print("size: next=\(self.next.sizeDescription) panel=\(self.panel.sizeDescription)")
        print("format: next=\(self.next.formatDescription) panel=\(self.panel.formatDescription)")
        print("eligibility: \(self.eligibility)")
        print("chip-counts: next=\(self.nextChipCount) panel=\(self.panelChipCount)")
        print(
            "free-text-capability: next=\(self.nextFreeTextCapability.rawValue) "
                + "panel=\(self.panelFreeTextCapability.rawValue)"
        )
        print("failure-category: \(self.failureCategory.rawValue)")
    }
}

// MARK: - AskParityEvaluation

private struct AskParityEvaluation {
    let report: AskParityReport
    let passed: Bool
}

// MARK: - AskParitySelection

private struct AskParitySelection {
    let profile: YouTubeAskRequestProfile
    let runtimeConfiguration: AskRuntimeWEBConfiguration?
    let cookies: [HTTPCookie]

    var profileName: String {
        askParityProfileName(self.profile)
    }
}

// MARK: - AskParityRequestError

private enum AskParityRequestError: Error {
    case configurationUnavailable
}

private let askParityUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

private func askWebClientConfigurationRequest(timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(url: activeWebClientURL)
    request.timeoutInterval = timeout
    request.setValue(askParityUserAgent, forHTTPHeaderField: "User-Agent")
    return request
}

private func askParityProfileName(_ profile: YouTubeAskRequestProfile) -> String {
    if profile == .fixedProduction {
        return "fixed-production-single-proof"
    }
    if profile == .fixedProductionWithAllSIDProofs {
        return "fixed-production-all-proofs"
    }
    return "runtime-web-all-proofs"
}

private func askParityWireFormat(_ envelope: YouTubeAskWireEnvelope) -> String {
    let format = switch envelope.format {
    case .jsonObject:
        "json-object"
    case .jsonArray:
        "json-array"
    case .newlineDelimitedJSON:
        "newline-delimited-json"
    case .lengthPrefixedJSON:
        "length-prefixed-json"
    }
    return envelope.hadXSSIPrefix ? "xssi-\(format)" : format
}

private func askParityHTTPFailureCategory(
    statusCode: Int,
    stage: String
) -> AskParityFailureCategory {
    if statusCode == 401 || statusCode == 403 {
        return stage == "next" ? .nextAuthenticationRejected : .panelAuthenticationRejected
    }
    if statusCode == 429 {
        return stage == "next" ? .nextRateLimited : .panelRateLimited
    }
    return stage == "next" ? .nextHTTPFailure : .panelHTTPFailure
}

private func askParityServerLoggedOutState(
    in envelope: YouTubeAskWireEnvelope
) -> Bool? {
    let maximumDepth = 40
    let maximumVisitedNodes = 50000
    var visitedNodes = 0
    var foundLoggedOut = false
    var foundSignedIn = false
    var traversalWasTruncated = false

    func collectLoggedOutValues(in value: YouTubeAskJSONValue, depth: Int) {
        guard depth <= maximumDepth, visitedNodes < maximumVisitedNodes else {
            traversalWasTruncated = true
            return
        }
        visitedNodes += 1

        switch value {
        case let .object(object):
            if let responseContext = object["responseContext"]?.objectValue,
               let mainAppContext = responseContext["mainAppWebResponseContext"]?.objectValue,
               case let .bool(loggedOut)? = mainAppContext["loggedOut"]
            {
                if loggedOut {
                    foundLoggedOut = true
                } else {
                    foundSignedIn = true
                }
            }
            for nestedValue in object.values {
                collectLoggedOutValues(in: nestedValue, depth: depth + 1)
            }
        case let .array(array):
            for nestedValue in array {
                collectLoggedOutValues(in: nestedValue, depth: depth + 1)
            }
        default:
            break
        }
    }

    for root in envelope.roots {
        collectLoggedOutValues(in: root, depth: 0)
    }

    // Any explicit logged-out marker rejects the response, including a
    // conflicting stream that also contains `loggedOut: false`. If traversal
    // was truncated, a lone signed-in marker cannot prove the unseen remainder
    // is safe, so the result remains unknown and fails closed.
    if foundLoggedOut {
        return true
    }
    if foundSignedIn, !traversalWasTruncated {
        return false
    }
    return nil
}

private func askRuntimeWEBConfiguration(cookies: [HTTPCookie]) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    let storage = HTTPCookieStorage()
    for cookie in cookies {
        storage.setCookie(cookie)
    }
    configuration.httpCookieStorage = storage
    configuration.httpShouldSetCookies = true
    configuration.httpCookieAcceptPolicy = .always
    return configuration
}

private func resolveAskRuntimeWEBConfiguration(
    cookies: [HTTPCookie]
) async throws -> AskRuntimeWEBConfiguration {
    let request = askWebClientConfigurationRequest(timeout: 10)
    let (data, response) = try await boundedResponseData(
        configuration: askRuntimeWEBConfiguration(cookies: cookies),
        request: request,
        maximumBytes: maximumAskConfigurationResponseBytes
    )
    guard let httpResponse = response as? HTTPURLResponse,
          (200 ... 399).contains(httpResponse.statusCode),
          let html = String(data: data, encoding: .utf8),
          let runtimeAPIIdentifier = extractInnertubeAPIKey(from: html),
          let clientVersion = extractInnertubeClientVersion(from: html),
          let visitorData = extractConfigValue(named: "VISITOR_DATA", from: html),
          !runtimeAPIIdentifier.isEmpty, !clientVersion.isEmpty, !visitorData.isEmpty
    else {
        throw AskParityRequestError.configurationUnavailable
    }
    return AskRuntimeWEBConfiguration(
        runtimeAPIIdentifier: runtimeAPIIdentifier,
        clientVersion: clientVersion,
        visitorData: visitorData
    )
}

private func askParityContext(
    profile: YouTubeAskRequestProfile,
    runtimeConfiguration: AskRuntimeWEBConfiguration?
) throws -> [String: Any] {
    var client: [String: Any] = [
        "clientName": "WEB",
        "clientVersion": profile.clientVersion,
        "hl": "en",
        "gl": "US",
        "browserName": "Safari",
        "browserVersion": "17.0",
        "osName": "Macintosh",
        "osVersion": "10_15_7",
        "platform": "DESKTOP",
        "userAgent": askParityUserAgent,
        "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
    ]
    if profile.usesVisitorData {
        guard let runtimeConfiguration else {
            throw AskParityRequestError.configurationUnavailable
        }
        client["visitorData"] = runtimeConfiguration.visitorData
    }
    return [
        "client": client,
        "user": ["lockedSafetyMode": false],
    ]
}

private func makeAskParityWireRequest(
    endpoint: String,
    bodyData: Data,
    profile: YouTubeAskRequestProfile,
    runtimeConfiguration: AskRuntimeWEBConfiguration?,
    cookies: [HTTPCookie]
) async throws -> APIWireResponse {
    let endpoint = try canonicalAPIEndpoint(endpoint)
    guard var body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let cookieHeader = buildCookieHeader(from: cookies),
          let authorization = buildSIDAuthorizationHeader(
              from: cookies,
              includeAllAvailableProofs: profile.usesAllSIDProofs
          )
    else {
        throw AskParityRequestError.configurationUnavailable
    }
    body["context"] = try askParityContext(
        profile: profile,
        runtimeConfiguration: runtimeConfiguration
    )

    var components = URLComponents(string: "\(activeBaseURL)/\(endpoint)")
    var queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
    if profile.includesRuntimeAPIParameter {
        guard let runtimeConfiguration else {
            throw AskParityRequestError.configurationUnavailable
        }
        queryItems.insert(URLQueryItem(name: "key", value: runtimeConfiguration.runtimeAPIIdentifier), at: 0)
    }
    components?.queryItems = queryItems
    guard let url = components?.url else {
        throw AskParityRequestError.configurationUnavailable
    }

    var request = URLRequest(
        url: url,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 30
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(askParityUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(activeOrigin, forHTTPHeaderField: "Origin")
    request.setValue(activeOrigin, forHTTPHeaderField: "Referer")
    request.setValue(activeOrigin, forHTTPHeaderField: "X-Origin")
    request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    if profile.usesVisitorData {
        guard let runtimeConfiguration else {
            throw AskParityRequestError.configurationUnavailable
        }
        request.setValue(runtimeConfiguration.visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await boundedResponseData(
        configuration: .ephemeral,
        request: request,
        maximumBytes: YouTubeAskLimits.maximumResponseBytes
    )
    guard let httpResponse = response as? HTTPURLResponse else {
        throw AskParityRequestError.configurationUnavailable
    }
    return APIWireResponse(
        data: data,
        statusCode: httpResponse.statusCode,
        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
    )
}

// MARK: - AskParityNextEvaluation

private struct AskParityNextEvaluation {
    let report: AskParityReport
    let bootstrap: YouTubeAskParsedBootstrap?
}

private func evaluateAskParityNext(
    profile: YouTubeAskRequestProfile,
    videoID: String,
    runtimeConfiguration: AskRuntimeWEBConfiguration?,
    cookies: [HTTPCookie],
    initialReport: AskParityReport
) async -> AskParityNextEvaluation {
    var report = initialReport
    guard let nextBody = try? JSONSerialization.data(withJSONObject: ["videoId": videoID]) else {
        report.failureCategory = .requestConfigurationUnavailable
        return AskParityNextEvaluation(report: report, bootstrap: nil)
    }

    let nextResponse: APIWireResponse
    do {
        nextResponse = try await makeAskParityWireRequest(
            endpoint: "next",
            bodyData: nextBody,
            profile: profile,
            runtimeConfiguration: runtimeConfiguration,
            cookies: cookies
        )
    } catch is ResponseSizeLimitError {
        report.failureCategory = .nextResponseTooLarge
        return AskParityNextEvaluation(report: report, bootstrap: nil)
    } catch AskParityRequestError.configurationUnavailable {
        report.failureCategory = .requestConfigurationUnavailable
        return AskParityNextEvaluation(report: report, bootstrap: nil)
    } catch {
        report.failureCategory = .nextNetworkFailure
        return AskParityNextEvaluation(report: report, bootstrap: nil)
    }
    report.next.statusCode = nextResponse.statusCode
    report.next.byteCount = nextResponse.data.count

    guard (200 ... 299).contains(nextResponse.statusCode) else {
        report.failureCategory = askParityHTTPFailureCategory(
            statusCode: nextResponse.statusCode,
            stage: "next"
        )
        return AskParityNextEvaluation(report: report, bootstrap: nil)
    }

    let nextEnvelope: YouTubeAskWireEnvelope
    do {
        nextEnvelope = try YouTubeAskWireDecoder.decode(nextResponse.data)
        report.next.wireFormat = askParityWireFormat(nextEnvelope)
    } catch {
        report.failureCategory = .nextDecodeFailure
        return AskParityNextEvaluation(report: report, bootstrap: nil)
    }
    guard askParityHasConfirmedSignedInState(
        askParityServerLoggedOutState(in: nextEnvelope)
    ) else {
        report.failureCategory = .nextAuthenticationRejected
        return AskParityNextEvaluation(report: report, bootstrap: nil)
    }

    do {
        guard let bootstrap = try YouTubeAskParser.parseBootstrap(from: nextEnvelope) else {
            report.eligibility = "ineligible"
            report.failureCategory = .ineligible
            return AskParityNextEvaluation(report: report, bootstrap: nil)
        }
        report.eligibility = "eligible"
        report.nextChipCount = bootstrap.suggestions.count
        report.nextFreeTextCapability = bootstrap.freeTextCommand == nil ? .absent : .present
        return AskParityNextEvaluation(report: report, bootstrap: bootstrap)
    } catch {
        report.failureCategory = .nextParseFailure
        return AskParityNextEvaluation(report: report, bootstrap: nil)
    }
}

private func evaluateAskParityPanel(
    profile: YouTubeAskRequestProfile,
    bootstrap: YouTubeAskParsedBootstrap,
    runtimeConfiguration: AskRuntimeWEBConfiguration?,
    cookies: [HTTPCookie],
    nextReport: AskParityReport
) async -> AskParityEvaluation {
    var report = nextReport
    let nextHasSummarySuggestion = bootstrap.suggestions.contains { suggestion in
        isAskSummaryLabel(suggestion.label)
    }

    // Even when `next` already exposes the summary chip, parity still requires
    // a read-only panel continuation so the exact `get_panel` transport used by
    // live suggestions is validated without submitting that chip.
    guard let panelCommand = bootstrap.panelCommand else {
        report.failureCategory = .panelCommandUnavailable
        return AskParityEvaluation(report: report, passed: false)
    }

    let panelBody = YouTubeAskRequestBuilder.makePanelBootstrapBody(command: panelCommand)
    let panelResponse: APIWireResponse
    do {
        panelResponse = try await makeAskParityWireRequest(
            endpoint: "get_panel",
            bodyData: panelBody,
            profile: profile,
            runtimeConfiguration: runtimeConfiguration,
            cookies: cookies
        )
    } catch is ResponseSizeLimitError {
        report.failureCategory = .panelResponseTooLarge
        return AskParityEvaluation(report: report, passed: false)
    } catch AskParityRequestError.configurationUnavailable {
        report.failureCategory = .requestConfigurationUnavailable
        return AskParityEvaluation(report: report, passed: false)
    } catch {
        report.failureCategory = .panelNetworkFailure
        return AskParityEvaluation(report: report, passed: false)
    }
    report.panel.statusCode = panelResponse.statusCode
    report.panel.byteCount = panelResponse.data.count

    guard (200 ... 299).contains(panelResponse.statusCode) else {
        report.failureCategory = askParityHTTPFailureCategory(
            statusCode: panelResponse.statusCode,
            stage: "panel"
        )
        return AskParityEvaluation(report: report, passed: false)
    }

    let panelEnvelope: YouTubeAskWireEnvelope
    do {
        panelEnvelope = try YouTubeAskWireDecoder.decode(panelResponse.data)
        report.panel.wireFormat = askParityWireFormat(panelEnvelope)
    } catch {
        report.failureCategory = .panelDecodeFailure
        return AskParityEvaluation(report: report, passed: false)
    }
    guard askParityHasConfirmedSignedInState(
        askParityServerLoggedOutState(in: panelEnvelope)
    ) else {
        report.failureCategory = .panelAuthenticationRejected
        return AskParityEvaluation(report: report, passed: false)
    }

    do {
        let panelConversation = try YouTubeAskParser.parseConversation(from: panelEnvelope)
        report.panelChipCount = panelConversation.suggestions.count
        report.panelFreeTextCapability = panelConversation.freeTextCommand == nil ? .absent : .present
        let panelHasSummarySuggestion = panelConversation.suggestions.contains { suggestion in
            isAskSummaryLabel(suggestion.label)
        }
        guard nextHasSummarySuggestion || panelHasSummarySuggestion else {
            report.failureCategory = .summarySuggestionUnavailable
            return AskParityEvaluation(report: report, passed: false)
        }
    } catch {
        report.failureCategory = .panelParseFailure
        return AskParityEvaluation(report: report, passed: false)
    }

    report.failureCategory = .none
    return AskParityEvaluation(report: report, passed: true)
}

private func evaluateAskParityProfile(
    _ profile: YouTubeAskRequestProfile,
    videoID: String,
    runtimeConfiguration: AskRuntimeWEBConfiguration?,
    cookies: [HTTPCookie]
) async -> AskParityEvaluation {
    let initialReport = AskParityReport(
        profileName: askParityProfileName(profile),
        failureCategory: .none
    )
    let nextEvaluation = await evaluateAskParityNext(
        profile: profile,
        videoID: videoID,
        runtimeConfiguration: runtimeConfiguration,
        cookies: cookies,
        initialReport: initialReport
    )
    guard let bootstrap = nextEvaluation.bootstrap else {
        return AskParityEvaluation(report: nextEvaluation.report, passed: false)
    }
    return await evaluateAskParityPanel(
        profile: profile,
        bootstrap: bootstrap,
        runtimeConfiguration: runtimeConfiguration,
        cookies: cookies,
        nextReport: nextEvaluation.report
    )
}

private func renderAskParityPreflightFailure(_ category: AskParityFailureCategory) {
    AskParityReport(profileName: "preflight", failureCategory: category).render()
}

private func selectAskParityProfile(
    videoID: String,
    cookies: [HTTPCookie],
    evaluateAllProfiles: Bool = false
) async -> AskParitySelection? {
    var firstPassingSelection: AskParitySelection?
    let fixedProfiles = YouTubeAskRequestProfile.orderedParityProfiles(
        runtimeClientVersion: YouTubeAskRequestProfile.productionClientVersion
    ).prefix(2)
    for profile in fixedProfiles {
        let evaluation = await evaluateAskParityProfile(
            profile,
            videoID: videoID,
            runtimeConfiguration: nil,
            cookies: cookies
        )
        evaluation.report.render()
        if evaluation.passed {
            let selection = AskParitySelection(
                profile: profile,
                runtimeConfiguration: nil,
                cookies: cookies
            )
            firstPassingSelection = firstPassingSelection ?? selection
            if !evaluateAllProfiles {
                return selection
            }
        }
        print()
    }

    let runtimeConfiguration: AskRuntimeWEBConfiguration
    do {
        runtimeConfiguration = try await resolveAskRuntimeWEBConfiguration(cookies: cookies)
    } catch {
        AskParityReport(
            profileName: "runtime-web-all-proofs",
            failureCategory: .runtimeConfigurationUnavailable
        ).render()
        return firstPassingSelection
    }
    let runtimeProfile = YouTubeAskRequestProfile.orderedParityProfiles(
        runtimeClientVersion: runtimeConfiguration.clientVersion
    )[2]
    let evaluation = await evaluateAskParityProfile(
        runtimeProfile,
        videoID: videoID,
        runtimeConfiguration: runtimeConfiguration,
        cookies: cookies
    )
    evaluation.report.render()
    if evaluation.passed, firstPassingSelection == nil {
        firstPassingSelection = AskParitySelection(
            profile: runtimeProfile,
            runtimeConfiguration: runtimeConfiguration,
            cookies: cookies
        )
    }
    return firstPassingSelection
}

func auditAskVideoRequestParity(
    _ videoID: String,
    hasUnsupportedOptions: Bool
) async {
    guard isValidYouTubeVideoID(videoID) else {
        renderAskParityPreflightFailure(.invalidVideoID)
        return
    }
    if !youtubeMode {
        activateYouTubeMode()
    }
    guard !hasUnsupportedOptions else {
        renderAskParityPreflightFailure(.unsupportedOptions)
        return
    }
    guard !forceUnauthenticatedRequests,
          let cookies = loadCookiesFromAppBackup(),
          getSAPISID(from: cookies) != nil,
          buildCookieHeader(from: cookies) != nil
    else {
        renderAskParityPreflightFailure(.authenticationUnavailable)
        return
    }
    guard !authUserOptionWasSpecified, globalBrandAccountId == nil else {
        renderAskParityPreflightFailure(.unsupportedAccountSelection)
        return
    }

    _ = await selectAskParityProfile(
        videoID: videoID,
        cookies: cookies,
        evaluateAllProfiles: true
    )
}

private func askYouChatPanelContinuationTokens(in root: Any) -> [String] {
    let maximumDepth = 80
    let maximumVisitedNodes = 100_000
    let maximumChildrenPerContainer = 2048
    var visitedNodes = 0
    var tokens: [String] = []
    var seenTokens: Set<String> = []

    func hasDirectYouChatSignal(_ dictionary: [String: Any]) -> Bool {
        let exactMarkers: Set = [
            "PAai_companion",
            "PAyouchat",
            "engagement-panel-youchat",
        ]
        return dictionary.contains { key, value in
            key.lowercased().contains("youchat")
                || (value as? String).map(exactMarkers.contains) == true
        }
    }

    func walk(
        _ value: Any,
        depth: Int,
        youChatRelevant: Bool,
        insideSendUserQueryCommand: Bool
    ) {
        guard depth <= maximumDepth, visitedNodes < maximumVisitedNodes else { return }
        visitedNodes += 1

        if let dictionary = value as? [String: Any] {
            let nestedYouChatRelevant = youChatRelevant || hasDirectYouChatSignal(dictionary)
            if dictionary["request"] as? String == "CONTINUATION_REQUEST_TYPE_GET_PANEL",
               let continuationValue = dictionary["token"] as? String,
               !continuationValue.isEmpty,
               nestedYouChatRelevant,
               !insideSendUserQueryCommand,
               seenTokens.insert(continuationValue).inserted
            {
                tokens.append(continuationValue)
            }
            for key in dictionary.keys.sorted().prefix(maximumChildrenPerContainer) {
                guard let nestedValue = dictionary[key] else { continue }
                walk(
                    nestedValue,
                    depth: depth + 1,
                    youChatRelevant: nestedYouChatRelevant,
                    insideSendUserQueryCommand: insideSendUserQueryCommand
                        || key == "sendUserQueryCommand"
                )
            }
        } else if let array = value as? [Any] {
            for nestedValue in array.prefix(maximumChildrenPerContainer) {
                walk(
                    nestedValue,
                    depth: depth + 1,
                    youChatRelevant: youChatRelevant,
                    insideSendUserQueryCommand: insideSendUserQueryCommand
                )
            }
        }
    }

    walk(
        root,
        depth: 0,
        youChatRelevant: false,
        insideSendUserQueryCommand: false
    )
    return tokens
}

// MARK: - AskPanelSuggestion

private struct AskPanelSuggestion {
    let label: String
    let continuation: String
    let schemaLayers: [String]

    var isSummarySuggestion: Bool {
        isAskSummaryLabel(self.label)
    }
}

private func isAskSummaryLabel(_ label: String) -> Bool {
    let normalized = label
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: " .!?…"))
    let exactSummaryLabels: Set = [
        "summary",
        "video summary",
        "summary of this video",
        "summarize",
        "summarise",
        "summarize video",
        "summarise video",
        "summarize this video",
        "summarise this video",
        "summarize the video",
        "summarise the video",
        "summarize key points",
        "summarise key points",
        "summarize the key points",
        "summarise the key points",
        "give me a summary",
        "give me a summary of this video",
        "provide a summary",
    ]
    return exactSummaryLabels.contains(normalized)
}

private func safeAskSchemaKey(_ key: String) -> String {
    guard !key.isEmpty, key.count <= 80,
          key.unicodeScalars.allSatisfy({ scalar in
              switch scalar.value {
              case 36, 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                  true
              default:
                  false
              }
          })
    else {
        return "<redacted-key>"
    }
    return key
}

private func askSchemaValueDescription(_ value: Any) -> String {
    if value is String {
        return "string"
    }
    if value is Bool {
        return "bool"
    }
    if value is NSNumber {
        return "number"
    }
    if value is NSNull {
        return "null"
    }
    if let dictionary = value as? [String: Any] {
        let keys = dictionary.keys.map(safeAskSchemaKey).sorted().prefix(16)
        return "object{\(keys.joined(separator: ","))\(dictionary.count > 16 ? ",…" : "")}"
    }
    if let array = value as? [Any] {
        let elementDescription = array.first.map(askSchemaValueDescription) ?? "empty"
        return "array<\(elementDescription)>"
    }
    return "other"
}

private func askSchemaLayer(
    via: String,
    dictionary: [String: Any]
) -> String {
    let fields = dictionary.keys.sorted().prefix(24).compactMap { key -> String? in
        guard let value = dictionary[key] else { return nil }
        return "\(safeAskSchemaKey(key)):\(askSchemaValueDescription(value))"
    }
    return "via \(via) -> {\(fields.joined(separator: ", "))\(dictionary.count > 24 ? ", …" : "")}"
}

private func firstAskSchemaValue(forKey targetKey: String, in root: Any) -> Any? {
    let maximumDepth = 80
    let maximumVisitedNodes = 100_000
    let maximumChildrenPerContainer = 2048
    var visitedNodes = 0

    func find(_ value: Any, depth: Int) -> Any? {
        guard depth <= maximumDepth, visitedNodes < maximumVisitedNodes else { return nil }
        visitedNodes += 1
        if let dictionary = value as? [String: Any] {
            if let match = dictionary[targetKey] {
                return match
            }
            for nestedValue in dictionary.values.prefix(maximumChildrenPerContainer) {
                if let match = find(nestedValue, depth: depth + 1) {
                    return match
                }
            }
        } else if let array = value as? [Any] {
            for nestedValue in array.prefix(maximumChildrenPerContainer) {
                if let match = find(nestedValue, depth: depth + 1) {
                    return match
                }
            }
        }
        return nil
    }

    return find(root, depth: 0)
}

private func askSchemaTree(_ root: Any, maximumDepth: Int = 8) -> [String] {
    let maximumVisitedNodes = 400
    let maximumChildrenPerContainer = 32
    var visitedNodes = 0
    var lines: [String] = []

    func append(_ value: Any, path: String, depth: Int) {
        guard depth <= maximumDepth, visitedNodes < maximumVisitedNodes else { return }
        visitedNodes += 1
        if let dictionary = value as? [String: Any] {
            lines.append("\(path): object")
            for key in dictionary.keys.sorted().prefix(maximumChildrenPerContainer) {
                guard let nestedValue = dictionary[key] else { continue }
                append(
                    nestedValue,
                    path: "\(path).\(safeAskSchemaKey(key))",
                    depth: depth + 1
                )
            }
        } else if let array = value as? [Any] {
            lines.append("\(path): array")
            for (index, nestedValue) in array.prefix(4).enumerated() {
                append(nestedValue, path: "\(path)[\(index)]", depth: depth + 1)
            }
        } else {
            lines.append("\(path): \(askSchemaValueDescription(value))")
        }
    }

    append(root, path: "$", depth: 0)
    if visitedNodes >= maximumVisitedNodes {
        lines.append("<schema traversal bounded>")
    }
    return lines
}

private func askVisibleText(in value: Any) -> String? {
    if let string = value as? String {
        return string
    }
    guard let dictionary = value as? [String: Any] else { return nil }
    if let content = dictionary["content"] as? String {
        return content
    }
    if let simpleText = dictionary["simpleText"] as? String {
        return simpleText
    }
    if let runs = dictionary["runs"] as? [[String: Any]] {
        let text = runs.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
    return nil
}

private func askPanelSuggestions(in root: Any) -> [AskPanelSuggestion] {
    let maximumDepth = 80
    let maximumVisitedNodes = 100_000
    let maximumChildrenPerContainer = 2048
    var visitedNodes = 0
    var suggestions: [AskPanelSuggestion] = []
    var seenContinuations: Set<String> = []

    func collectSuggestions(
        from viewModel: [String: Any],
        context: [String]
    ) {
        guard let chipsData = viewModel["chipsData"] as? [String: Any],
              let chipItems = chipsData["chipData"] as? [[String: Any]]
        else {
            return
        }

        let viewModelContext = Array(
            (context + [askSchemaLayer(via: "youChatItemViewModel", dictionary: viewModel)])
                .suffix(8)
        )
        let chipsContext = Array(
            (viewModelContext + [askSchemaLayer(via: "chipsData", dictionary: chipsData)])
                .suffix(8)
        )
        for (index, chip) in chipItems.prefix(maximumChildrenPerContainer).enumerated() {
            guard let continuation = chip["continuation"] as? String,
                  !continuation.isEmpty,
                  let label = chip["text"].flatMap(askVisibleText),
                  !label.isEmpty,
                  label.count <= 200,
                  seenContinuations.insert(continuation).inserted
            else {
                continue
            }
            let chipContext = Array(
                (chipsContext + [askSchemaLayer(via: "[\(index)]", dictionary: chip)])
                    .suffix(8)
            )
            suggestions.append(AskPanelSuggestion(
                label: label,
                continuation: continuation,
                schemaLayers: chipContext
            ))
        }
    }

    func walk(_ value: Any, depth: Int, via: String, context: [String]) {
        guard depth <= maximumDepth, visitedNodes < maximumVisitedNodes else { return }
        visitedNodes += 1

        if let dictionary = value as? [String: Any] {
            let nextContext = Array(
                (context + [askSchemaLayer(via: via, dictionary: dictionary)]).suffix(8)
            )
            if let viewModel = dictionary["youChatItemViewModel"] as? [String: Any] {
                collectSuggestions(from: viewModel, context: nextContext)
            }
            for (key, nestedValue) in dictionary.sorted(by: { $0.key < $1.key })
                .prefix(maximumChildrenPerContainer)
            {
                walk(
                    nestedValue,
                    depth: depth + 1,
                    via: safeAskSchemaKey(key),
                    context: nextContext
                )
            }
        } else if let array = value as? [Any] {
            for (index, nestedValue) in array.prefix(maximumChildrenPerContainer).enumerated() {
                walk(nestedValue, depth: depth + 1, via: "[\(index)]", context: context)
            }
        }
    }

    walk(root, depth: 0, via: "$", context: [])
    return suggestions
}

private func replacingAskOutputMatches(
    in value: String,
    pattern: String,
    replacement: String
) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    let range = NSRange(value.startIndex ..< value.endIndex, in: value)
    return expression.stringByReplacingMatches(
        in: value,
        options: [],
        range: range,
        withTemplate: replacement
    )
}

private func sanitizedAskVisibleOutput(_ value: String, maximumCharacters: Int = 16000) -> String {
    let bidiControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]
    var sanitized = String.UnicodeScalarView()
    sanitized.reserveCapacity(value.unicodeScalars.count)
    for scalar in value.unicodeScalars {
        let scalarValue = scalar.value
        if bidiControls.contains(scalarValue) {
            continue
        }
        if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" {
            continue
        }
        sanitized.append(scalar)
    }

    var result = String(sanitized)
    result = replacingAskOutputMatches(
        in: result,
        pattern: "\\u001B\\[[0-?]*[ -/]*[@-~]",
        replacement: ""
    )
    result = replacingAskOutputMatches(
        in: result,
        pattern: "(?i)https?://[^\\s)>]+",
        replacement: "<link omitted>"
    )
    result = replacingAskOutputMatches(
        in: result,
        pattern: "(?<![A-Za-z0-9])[A-Za-z0-9_-]{48,}(?![A-Za-z0-9])",
        replacement: "<opaque text omitted>"
    )
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.count > maximumCharacters {
        result = String(result.prefix(maximumCharacters)) + "\n[…output truncated…]"
    }
    return result
}

private func makeSelectedAskWireRequest(
    endpoint: String,
    bodyData: Data,
    selection: AskParitySelection
) async throws -> APIWireResponse {
    try await makeAskParityWireRequest(
        endpoint: endpoint,
        bodyData: bodyData,
        profile: selection.profile,
        runtimeConfiguration: selection.runtimeConfiguration,
        cookies: selection.cookies
    )
}

private func confirmedSignedInAskEnvelope(
    from response: APIWireResponse,
    operation: String
) throws -> YouTubeAskWireEnvelope {
    let envelope = try YouTubeAskWireDecoder.decode(response.data)
    guard askParityHasConfirmedSignedInState(
        askParityServerLoggedOutState(in: envelope)
    ) else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "YouTube did not explicitly confirm the \(operation) response as signed in",
            ]
        )
    }
    return envelope
}

private func makeAskSuggestionRequest(
    _ suggestion: YouTubeAskParsedSuggestion,
    selection: AskParitySelection
) async throws -> APIWireResponse {
    let currentUnixTimeMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
    let clientMessageId = "youchat-\(currentUnixTimeMilliseconds)"
    let bodyData = try YouTubeAskRequestBuilder.makeDirectChipBody(
        command: suggestion.command,
        clientMessageID: clientMessageId
    )
    let response = try await makeSelectedAskWireRequest(
        endpoint: "get_panel",
        bodyData: bodyData,
        selection: selection
    )
    guard (200 ... 299).contains(response.statusCode) else {
        throw NSError(
            domain: "APIExplorer",
            code: response.statusCode,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Ask panel request returned HTTP \(response.statusCode)",
            ]
        )
    }
    _ = try confirmedSignedInAskEnvelope(
        from: response,
        operation: "Ask suggestion"
    )
    return response
}

// MARK: - AskFreeTextValidationError

private enum AskFreeTextValidationError: LocalizedError {
    case commandUnavailable
    case malformedCommand
    case ambiguousCommand
    case requestEncodingFailed
    case requestSnapshotUnavailable
    case requestSnapshotChanged
    case nextRequestFailed
    case nextHTTPFailure(Int)
    case nextAuthenticationRejected
    case initialPanelRequestFailed
    case initialPanelHTTPFailure(Int)
    case initialPanelAuthenticationRejected
    case streamingRequestFailed
    case streamingHTTPFailure(Int)
    case responseTooLarge
    case responseDecodeFailed
    case responseParseFailed
    case answerUnavailable

    var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            "No eligible PAyouchat free-text command was available from next or initial get_panel"
        case .malformedCommand:
            "The eligible PAyouchat free-text command did not match the exact supported schema"
        case .ambiguousCommand:
            "Multiple distinct eligible PAyouchat free-text commands were present"
        case .requestEncodingFailed:
            "The fixed free-text request body could not be encoded"
        case .requestSnapshotUnavailable:
            "The authenticated WEB request snapshot could not be prepared"
        case .requestSnapshotChanged:
            "The authenticated WEB request snapshot changed before the private prompt could be sent"
        case .nextRequestFailed:
            "The authenticated watch bootstrap request failed"
        case let .nextHTTPFailure(statusCode):
            "The authenticated watch bootstrap returned HTTP \(statusCode)"
        case .nextAuthenticationRejected:
            "YouTube did not explicitly confirm the watch bootstrap as signed in"
        case .initialPanelRequestFailed:
            "The prompt-free initial Ask panel request failed"
        case let .initialPanelHTTPFailure(statusCode):
            "The prompt-free initial Ask panel returned HTTP \(statusCode)"
        case .initialPanelAuthenticationRejected:
            "YouTube did not explicitly confirm the initial Ask panel as signed in"
        case .streamingRequestFailed:
            "The one-shot free-text request failed"
        case let .streamingHTTPFailure(statusCode):
            "The one-shot free-text request returned HTTP \(statusCode)"
        case .responseTooLarge:
            "The Ask response exceeded the safety limit"
        case .responseDecodeFailed:
            "The Ask response could not be decoded safely"
        case .responseParseFailed:
            "The one-shot free-text response did not match a confirmed YouChat response container"
        case .answerUnavailable:
            "The one-shot free-text response did not contain visible assistant text"
        }
    }
}

// MARK: - AskFreeTextCommandSource

private enum AskFreeTextCommandSource: String {
    case watchNext = "next"
    case initialPanel = "initial-get-panel"
}

// MARK: - AskLoadedFreeTextCommand

private struct AskLoadedFreeTextCommand: CustomStringConvertible, CustomDebugStringConvertible {
    let command: YouTubeAskOpaqueCommand
    let source: AskFreeTextCommandSource

    var description: String {
        "<redacted Ask free-text command>"
    }

    var debugDescription: String {
        self.description
    }
}

// MARK: - AskFreeTextCookieState

private struct AskFreeTextCookieState: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresAt: TimeInterval?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let isSessionOnly: Bool

    var description: String {
        "<redacted Ask free-text cookie state>"
    }

    var debugDescription: String {
        self.description
    }

    var sortComponents: [String] {
        [
            self.domain,
            self.path,
            self.name,
            self.value,
            self.expiresAt.map { String($0) } ?? "",
            self.isSecure ? "1" : "0",
            self.isHTTPOnly ? "1" : "0",
            self.isSessionOnly ? "1" : "0",
        ]
    }
}

// MARK: - AskFreeTextAccountState

private struct AskFreeTextAccountState: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let youtubeMode: Bool
    let apiHost: String
    let webClientURL: String
    let baseURL: String
    let origin: String
    let clientName: String
    let authUserIndex: Int
    let authUserOptionWasSpecified: Bool
    let brandAccountID: String?
    let forceUnauthenticatedRequests: Bool
    let clientVersionWasForced: Bool

    var description: String {
        "<redacted Ask free-text account state>"
    }

    var debugDescription: String {
        self.description
    }
}

// MARK: - AskFreeTextBackingState

private struct AskFreeTextBackingState: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let account: AskFreeTextAccountState
    let cookies: [AskFreeTextCookieState]

    var description: String {
        "<redacted Ask free-text backing state>"
    }

    var debugDescription: String {
        self.description
    }
}

// MARK: - AskFreeTextRequestSnapshot

private struct AskFreeTextRequestSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
    let baseURL: String
    let runtimeAPIIdentifier: String
    let contextData: Data
    let headers: [String: String]
    let backingState: AskFreeTextBackingState

    var description: String {
        "<redacted Ask free-text request snapshot>"
    }

    var debugDescription: String {
        self.description
    }
}

private func currentAskFreeTextAccountState() -> AskFreeTextAccountState {
    AskFreeTextAccountState(
        youtubeMode: youtubeMode,
        apiHost: activeAPIHost,
        webClientURL: activeWebClientURL.absoluteString,
        baseURL: activeBaseURL,
        origin: activeOrigin,
        clientName: activeClientName,
        authUserIndex: globalAuthUserIndex,
        authUserOptionWasSpecified: authUserOptionWasSpecified,
        brandAccountID: globalBrandAccountId,
        forceUnauthenticatedRequests: forceUnauthenticatedRequests,
        clientVersionWasForced: clientVersionWasForced
    )
}

private func askFreeTextCookieMatchesHost(_ cookie: HTTPCookie, host: String) -> Bool {
    let domain = cookie.domain.lowercased()
    if domain.hasPrefix(".") {
        let suffix = String(domain.dropFirst())
        return host == suffix || host.hasSuffix(".\(suffix)")
    }
    return host == domain || host.hasSuffix(".\(domain)")
}

private func askFreeTextCookieState(
    cookies: [HTTPCookie],
    host: String
) -> [AskFreeTextCookieState] {
    cookies
        .filter { askFreeTextCookieMatchesHost($0, host: host) }
        .map { cookie in
            AskFreeTextCookieState(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path,
                expiresAt: cookie.expiresDate?.timeIntervalSinceReferenceDate,
                isSecure: cookie.isSecure,
                isHTTPOnly: cookie.isHTTPOnly,
                isSessionOnly: cookie.isSessionOnly
            )
        }
        .sorted { lhs, rhs in
            lhs.sortComponents.lexicographicallyPrecedes(rhs.sortComponents)
        }
}

private func currentAskFreeTextBackingState() throws -> AskFreeTextBackingState {
    let account = currentAskFreeTextAccountState()
    guard account.youtubeMode,
          !account.forceUnauthenticatedRequests,
          !account.authUserOptionWasSpecified,
          account.authUserIndex == 0,
          account.brandAccountID == nil,
          !account.clientVersionWasForced,
          let cookies = loadCookiesFromAppBackup(),
          getSAPISID(from: cookies) != nil,
          buildCookieHeader(from: cookies) != nil
    else {
        throw AskFreeTextValidationError.requestSnapshotUnavailable
    }
    return AskFreeTextBackingState(
        account: account,
        cookies: askFreeTextCookieState(cookies: cookies, host: account.apiHost)
    )
}

private func askFreeTextContextData(
    runtimeConfiguration: AskRuntimeWEBConfiguration,
    account: AskFreeTextAccountState
) throws -> Data {
    let context: [String: Any] = [
        "client": [
            "clientName": account.clientName,
            "clientVersion": runtimeConfiguration.clientVersion,
            "hl": "en",
            "gl": "US",
            "browserName": "Safari",
            "browserVersion": "17.0",
            "osName": "Macintosh",
            "osVersion": "10_15_7",
            "platform": "DESKTOP",
        ],
        "user": ["lockedSafetyMode": false],
    ]
    return try JSONSerialization.data(withJSONObject: context)
}

private func askFreeTextHeaders(
    cookies: [HTTPCookie],
    account: AskFreeTextAccountState
) throws -> [String: String] {
    guard let cookieHeader = buildCookieHeader(from: cookies),
          let authorization = buildSIDAuthorizationHeader(
              from: cookies,
              includeAllAvailableProofs: false
          )
    else {
        throw AskFreeTextValidationError.requestSnapshotUnavailable
    }
    return [
        "Content-Type": "application/json",
        "User-Agent": askParityUserAgent,
        "Origin": account.origin,
        "Referer": "\(account.origin)/",
        "Cookie": cookieHeader,
        "Authorization": authorization,
        "X-Goog-AuthUser": String(account.authUserIndex),
        "X-Origin": account.origin,
    ]
}

private func captureAskFreeTextRequestSnapshot() async throws -> AskFreeTextRequestSnapshot {
    let initialBackingState = try currentAskFreeTextBackingState()
    guard let cookies = loadCookiesFromAppBackup(),
          currentAskFreeTextAccountState() == initialBackingState.account,
          askFreeTextCookieState(
              cookies: cookies,
              host: initialBackingState.account.apiHost
          ) == initialBackingState.cookies
    else {
        throw AskFreeTextValidationError.requestSnapshotChanged
    }

    let runtimeConfiguration: AskRuntimeWEBConfiguration
    do {
        runtimeConfiguration = try await resolveAskRuntimeWEBConfiguration(cookies: cookies)
    } catch {
        throw AskFreeTextValidationError.requestSnapshotUnavailable
    }

    // Configuration discovery can await network I/O. Re-read the authoritative
    // cookie export and account selectors before sealing the snapshot so a
    // concurrent logout or account change cannot produce a mixed request.
    let finalBackingState: AskFreeTextBackingState
    do {
        finalBackingState = try currentAskFreeTextBackingState()
    } catch {
        throw AskFreeTextValidationError.requestSnapshotChanged
    }
    guard finalBackingState == initialBackingState else {
        throw AskFreeTextValidationError.requestSnapshotChanged
    }

    let contextData: Data
    let headers: [String: String]
    do {
        contextData = try askFreeTextContextData(
            runtimeConfiguration: runtimeConfiguration,
            account: initialBackingState.account
        )
        headers = try askFreeTextHeaders(
            cookies: cookies,
            account: initialBackingState.account
        )
    } catch let error as AskFreeTextValidationError {
        throw error
    } catch {
        throw AskFreeTextValidationError.requestSnapshotUnavailable
    }

    return AskFreeTextRequestSnapshot(
        baseURL: initialBackingState.account.baseURL,
        runtimeAPIIdentifier: runtimeConfiguration.runtimeAPIIdentifier,
        contextData: contextData,
        headers: headers,
        backingState: initialBackingState
    )
}

private func validateAskFreeTextRequestSnapshot(
    _ snapshot: AskFreeTextRequestSnapshot
) throws {
    let currentState: AskFreeTextBackingState
    do {
        currentState = try currentAskFreeTextBackingState()
    } catch {
        throw AskFreeTextValidationError.requestSnapshotChanged
    }
    guard currentState == snapshot.backingState else {
        throw AskFreeTextValidationError.requestSnapshotChanged
    }
}

private func makeRuntimeAskFreeTextWireRequest(
    endpoint: String,
    bodyData: Data,
    requestSnapshot: AskFreeTextRequestSnapshot,
    clickTrackingContextData: Data? = nil,
    validateBackingStateBeforeSending: Bool = false
) async throws -> APIWireResponse {
    let endpoint = try canonicalAPIEndpoint(endpoint)
    guard var body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let snapshotContext = try JSONSerialization.jsonObject(
              with: requestSnapshot.contextData
          ) as? [String: Any]
    else {
        throw AskFreeTextValidationError.requestEncodingFailed
    }
    var components = URLComponents(string: "\(requestSnapshot.baseURL)/\(endpoint)")
    components?.queryItems = [
        URLQueryItem(name: "key", value: requestSnapshot.runtimeAPIIdentifier),
        URLQueryItem(name: "prettyPrint", value: "false"),
    ]
    guard let url = components?.url else {
        throw AskFreeTextValidationError.requestEncodingFailed
    }

    var context = snapshotContext
    if let clickTrackingContextData {
        guard let clickTrackingContext = try JSONSerialization.jsonObject(
            with: clickTrackingContextData
        ) as? [String: Any],
            Set(clickTrackingContext.keys) == ["clickTracking"],
            let clickTracking = clickTrackingContext["clickTracking"] as? [String: Any],
            Set(clickTracking.keys) == ["clickTrackingParams"]
        else {
            throw AskFreeTextValidationError.requestEncodingFailed
        }
        context["clickTracking"] = clickTracking
    }
    body["context"] = context

    var request = URLRequest(
        url: url,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 30
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    for (key, value) in requestSnapshot.headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    let finalBody = try JSONSerialization.data(withJSONObject: body)
    try YouTubeAskRequestBuilder.validateRequestBodySize(finalBody)
    request.httpBody = finalBody

    if validateBackingStateBeforeSending {
        try validateAskFreeTextRequestSnapshot(requestSnapshot)
    }

    let (data, response) = try await boundedResponseData(
        configuration: .ephemeral,
        request: request,
        maximumBytes: YouTubeAskLimits.maximumResponseBytes
    )
    guard let httpResponse = response as? HTTPURLResponse else {
        throw AskFreeTextValidationError.streamingRequestFailed
    }
    return APIWireResponse(
        data: data,
        statusCode: httpResponse.statusCode,
        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
    )
}

private func loadAskFreeTextCommand(
    videoID: String,
    requestSnapshot: AskFreeTextRequestSnapshot
) async throws -> AskLoadedFreeTextCommand {
    guard let nextBody = try? JSONSerialization.data(withJSONObject: ["videoId": videoID]) else {
        throw AskFreeTextValidationError.requestEncodingFailed
    }
    let nextResponse: APIWireResponse
    do {
        nextResponse = try await makeRuntimeAskFreeTextWireRequest(
            endpoint: "next",
            bodyData: nextBody,
            requestSnapshot: requestSnapshot
        )
    } catch is ResponseSizeLimitError {
        throw AskFreeTextValidationError.responseTooLarge
    } catch {
        throw AskFreeTextValidationError.nextRequestFailed
    }
    guard (200 ... 299).contains(nextResponse.statusCode) else {
        throw AskFreeTextValidationError.nextHTTPFailure(nextResponse.statusCode)
    }

    let nextEnvelope: YouTubeAskWireEnvelope
    do {
        nextEnvelope = try YouTubeAskWireDecoder.decode(nextResponse.data)
    } catch {
        throw AskFreeTextValidationError.responseDecodeFailed
    }

    guard askParityHasConfirmedSignedInState(
        askParityServerLoggedOutState(in: nextEnvelope)
    ) else {
        throw AskFreeTextValidationError.nextAuthenticationRejected
    }

    let bootstrap: YouTubeAskParsedBootstrap
    do {
        guard let parsed = try YouTubeAskParser.parseBootstrap(from: nextEnvelope) else {
            throw AskFreeTextValidationError.commandUnavailable
        }
        bootstrap = parsed
    } catch let error as AskFreeTextValidationError {
        throw error
    } catch YouTubeAskCoreError.ambiguousBootstrap {
        throw AskFreeTextValidationError.ambiguousCommand
    } catch {
        throw AskFreeTextValidationError.malformedCommand
    }

    if let command = bootstrap.freeTextCommand {
        return AskLoadedFreeTextCommand(command: command, source: .watchNext)
    }
    guard let panelCommand = bootstrap.panelCommand else {
        throw AskFreeTextValidationError.commandUnavailable
    }

    let panelBody = YouTubeAskRequestBuilder.makePanelBootstrapBody(command: panelCommand)
    let panelResponse: APIWireResponse
    do {
        panelResponse = try await makeRuntimeAskFreeTextWireRequest(
            endpoint: "get_panel",
            bodyData: panelBody,
            requestSnapshot: requestSnapshot,
            validateBackingStateBeforeSending: true
        )
    } catch is ResponseSizeLimitError {
        throw AskFreeTextValidationError.responseTooLarge
    } catch let error as AskFreeTextValidationError {
        throw error
    } catch {
        throw AskFreeTextValidationError.initialPanelRequestFailed
    }
    guard (200 ... 299).contains(panelResponse.statusCode) else {
        throw AskFreeTextValidationError.initialPanelHTTPFailure(panelResponse.statusCode)
    }

    let panelEnvelope: YouTubeAskWireEnvelope
    do {
        panelEnvelope = try YouTubeAskWireDecoder.decode(panelResponse.data)
    } catch {
        throw AskFreeTextValidationError.responseDecodeFailed
    }

    guard askParityHasConfirmedSignedInState(
        askParityServerLoggedOutState(in: panelEnvelope)
    ) else {
        throw AskFreeTextValidationError.initialPanelAuthenticationRejected
    }

    let panelConversation: YouTubeAskParsedConversation
    do {
        panelConversation = try YouTubeAskParser.parseConversation(from: panelEnvelope)
    } catch YouTubeAskCoreError.ambiguousBootstrap {
        throw AskFreeTextValidationError.ambiguousCommand
    } catch {
        throw AskFreeTextValidationError.malformedCommand
    }
    guard let command = panelConversation.freeTextCommand else {
        throw AskFreeTextValidationError.commandUnavailable
    }
    return AskLoadedFreeTextCommand(command: command, source: .initialPanel)
}

private func sendAskFreeTextRequest(
    command: YouTubeAskOpaqueCommand,
    prompt: String,
    requestSnapshot: AskFreeTextRequestSnapshot
) async throws -> APIWireResponse {
    let bodyData: Data
    let clickTrackingContextData: Data
    do {
        let milliseconds = max(0, Int64(Date().timeIntervalSince1970 * 1000))
        bodyData = try YouTubeAskRequestBuilder.makeFreeTextBody(
            command: command,
            clientMessageID: "youchat-\(milliseconds)",
            userInputText: prompt,
            playerOffsetMilliseconds: 0
        )
        clickTrackingContextData = try YouTubeAskRequestBuilder.makeFreeTextClickTrackingContext(
            command: command
        )
    } catch {
        throw AskFreeTextValidationError.requestEncodingFailed
    }
    do {
        return try await makeRuntimeAskFreeTextWireRequest(
            endpoint: "get_panel",
            bodyData: bodyData,
            requestSnapshot: requestSnapshot,
            clickTrackingContextData: clickTrackingContextData,
            validateBackingStateBeforeSending: true
        )
    } catch is ResponseSizeLimitError {
        throw AskFreeTextValidationError.responseTooLarge
    } catch let error as AskFreeTextValidationError {
        throw error
    } catch {
        throw AskFreeTextValidationError.streamingRequestFailed
    }
}

func liveTestAskVideoFreeText(
    _ videoID: String,
    prompt: String
) async {
    guard isValidYouTubeVideoID(videoID) else {
        print("❌ Invalid YouTube video ID")
        return
    }
    if !youtubeMode {
        activateYouTubeMode()
    }
    guard !forceUnauthenticatedRequests else {
        print("❌ ask-video-free-text-test requires authentication; remove --guest/--no-auth")
        return
    }
    guard !authUserOptionWasSpecified, globalAuthUserIndex == 0, globalBrandAccountId == nil else {
        print("❌ ask-video-free-text-test supports only the signed-in primary account")
        return
    }
    guard let cookies = loadCookiesFromAppBackup(),
          getSAPISID(from: cookies) != nil,
          buildCookieHeader(from: cookies) != nil
    else {
        print("❌ No usable Kaset cookie export is available")
        return
    }

    print("🧪 Ask Gemini guarded free-text test")
    print("====================================\n")
    print("Video ID: validated (value not displayed)")
    print("Prompt: loaded privately (\(prompt.count) characters; content not displayed)")
    print(
        "Safety: at most one prompt-free initial get_panel plus one generated get_panel; "
            + "no retry or raw output"
    )
    print("Request profile: runtime WEB configuration validated by the read-only Ask audit")

    do {
        let requestSnapshot = try await captureAskFreeTextRequestSnapshot()
        let loadedCommand = try await loadAskFreeTextCommand(
            videoID: videoID,
            requestSnapshot: requestSnapshot
        )
        print(
            "Eligible PAyouchat free-text command: validated from "
                + "\(loadedCommand.source.rawValue) (opaque values hidden)"
        )

        let response = try await sendAskFreeTextRequest(
            command: loadedCommand.command,
            prompt: prompt,
            requestSnapshot: requestSnapshot
        )
        printAskLiveWireSummary(response, verbose: false)
        guard (200 ... 299).contains(response.statusCode) else {
            throw AskFreeTextValidationError.streamingHTTPFailure(response.statusCode)
        }

        let envelope: YouTubeAskWireEnvelope
        do {
            envelope = try YouTubeAskWireDecoder.decode(response.data)
        } catch {
            throw AskFreeTextValidationError.responseDecodeFailed
        }

        let conversation: YouTubeAskParsedConversation
        do {
            conversation = try YouTubeAskParser.parseConversation(from: envelope)
        } catch {
            throw AskFreeTextValidationError.responseParseFailed
        }
        guard !conversation.messages.isEmpty else {
            throw AskFreeTextValidationError.answerUnavailable
        }

        print("\nAssistant response:")
        for message in conversation.messages {
            print(renderedAskLiveMessage(message))
        }
        print("\nServer-issued follow-up suggestions: \(conversation.suggestions.count)")
        print("Opaque command and conversation values were not displayed or saved")
    } catch let error as AskFreeTextValidationError {
        print("❌ Free-text validation failed: \(error.localizedDescription)")
    } catch {
        print("❌ Free-text validation failed safely; no raw values were displayed")
    }
}

private func makeAskSummaryRequest(
    videoId: String,
    selection: AskParitySelection
) async throws -> APIWireResponse {
    let nextBody = try JSONSerialization.data(withJSONObject: ["videoId": videoId])
    let nextResponse = try await makeSelectedAskWireRequest(
        endpoint: "next",
        bodyData: nextBody,
        selection: selection
    )
    guard (200 ... 299).contains(nextResponse.statusCode) else {
        throw NSError(
            domain: "APIExplorer",
            code: nextResponse.statusCode,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Watch bootstrap request returned HTTP \(nextResponse.statusCode)",
            ]
        )
    }
    let nextEnvelope = try confirmedSignedInAskEnvelope(
        from: nextResponse,
        operation: "watch bootstrap"
    )

    guard let bootstrap = try YouTubeAskParser.parseBootstrap(from: nextEnvelope) else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No eligible Ask bootstrap was available"]
        )
    }
    let watchSuggestions = bootstrap.suggestions
    if let summarySuggestion = watchSuggestions.first(where: { isAskSummaryLabel($0.label) }) {
        return try await makeAskSuggestionRequest(
            summarySuggestion,
            selection: selection
        )
    }

    guard let panelCommand = bootstrap.panelCommand else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No server-issued Ask panel continuation was available"]
        )
    }

    let panelBody = YouTubeAskRequestBuilder.makePanelBootstrapBody(command: panelCommand)
    let panelResponse = try await makeSelectedAskWireRequest(
        endpoint: "get_panel",
        bodyData: panelBody,
        selection: selection
    )
    guard (200 ... 299).contains(panelResponse.statusCode) else {
        throw NSError(
            domain: "APIExplorer",
            code: panelResponse.statusCode,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Ask panel bootstrap returned HTTP \(panelResponse.statusCode)",
            ]
        )
    }
    let panelEnvelope = try confirmedSignedInAskEnvelope(
        from: panelResponse,
        operation: "Ask panel bootstrap"
    )
    let panelConversation = try YouTubeAskParser.parseConversation(from: panelEnvelope)
    let panelSuggestions = panelConversation.suggestions
    guard let summarySuggestion = panelSuggestions.first(where: { isAskSummaryLabel($0.label) }) else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "No recognizable server-issued summary suggestion was found (watch candidates: \(watchSuggestions.count), panel candidates: \(panelSuggestions.count))",
            ]
        )
    }

    return try await makeAskSuggestionRequest(
        summarySuggestion,
        selection: selection
    )
}

private func printAskLiveWireSummary(
    _ response: APIWireResponse,
    verbose: Bool
) {
    print("  HTTP \(response.statusCode), \(response.data.count) response bytes")
    if verbose {
        print(wireResponseAuditSummary(
            data: response.data,
            statusCode: response.statusCode,
            contentType: response.contentType
        ))
    }
}

// MARK: - AskLiveAnswer

private struct AskLiveAnswer {
    let text: String
    let wasTruncated: Bool
}

private func renderedAskLiveMessage(_ message: YouTubeAskParsedMessage) -> String {
    let visibleText = sanitizedAskVisibleOutput(message.text)
    guard message.wasTruncated else { return visibleText }
    return visibleText + "\n[…answer truncated by safety limit…]"
}

private func runAskLiveChat(
    videoId: String,
    selection: AskParitySelection,
    includeFollowUp: Bool,
    verbose: Bool
) async throws -> AskLiveAnswer {
    let response = try await makeAskSummaryRequest(
        videoId: videoId,
        selection: selection
    )
    printAskLiveWireSummary(response, verbose: verbose)

    let conversation = try YouTubeAskParser.parseConversation(
        from: YouTubeAskWireDecoder.decode(response.data)
    )
    guard let answerMessage = conversation.messages.first else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No generated summary text was found"]
        )
    }
    print("\nSummary:\n\(renderedAskLiveMessage(answerMessage))")

    let answer = AskLiveAnswer(
        text: answerMessage.text,
        wasTruncated: answerMessage.wasTruncated
    )
    guard includeFollowUp else { return answer }
    let followUps = conversation.suggestions
        .filter { !isAskSummaryLabel($0.label) }
    guard let followUp = followUps.first else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The summary response did not expose a follow-up suggestion",
            ]
        )
    }
    print(
        "\nFollow-up question:\n\(sanitizedAskVisibleOutput(followUp.label, maximumCharacters: 500))"
    )
    let followUpResponse = try await makeAskSuggestionRequest(
        followUp,
        selection: selection
    )
    printAskLiveWireSummary(followUpResponse, verbose: verbose)

    let followUpConversation = try YouTubeAskParser.parseConversation(
        from: YouTubeAskWireDecoder.decode(followUpResponse.data)
    )
    guard let followUpAnswer = followUpConversation.messages.first else {
        throw NSError(
            domain: "APIExplorer",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "No generated follow-up answer was found",
            ]
        )
    }
    print("\nFollow-up answer:\n\(renderedAskLiveMessage(followUpAnswer))")
    return answer
}

func liveTestAskVideo(
    _ videoId: String,
    freshChatCount: Int,
    includeFollowUp: Bool,
    verbose: Bool
) async {
    guard isValidYouTubeVideoID(videoId) else {
        print("❌ Invalid YouTube video ID")
        return
    }
    if !youtubeMode {
        activateYouTubeMode()
    }
    guard !forceUnauthenticatedRequests else {
        print("❌ ask-video-live-test requires authentication; remove --guest/--no-auth")
        return
    }
    guard !authUserOptionWasSpecified, globalBrandAccountId == nil else {
        print("❌ ask-video-live-test does not support --authuser or --brand")
        return
    }
    guard let cookies = loadCookiesFromAppBackup(),
          getSAPISID(from: cookies) != nil,
          buildCookieHeader(from: cookies) != nil
    else {
        print("❌ No usable Kaset cookie export is available")
        return
    }
    guard (1 ... 3).contains(freshChatCount) else {
        print("❌ --fresh-chats must be between 1 and 3")
        return
    }

    print("🧪 Ask Gemini live summary test")
    print("===============================\n")
    print("Video ID: \(videoId)")
    print("Fresh chats requested: \(freshChatCount)")
    print("Server-issued follow-up: \(includeFollowUp ? "enabled" : "disabled")")
    print("Safety: only the server-issued summary suggestion is replayed; opaque state stays in memory")
    print("\nRead-only request-profile validation:")

    guard let selection = await selectAskParityProfile(
        videoID: videoId,
        cookies: cookies
    ) else {
        print("\n❌ No request profile passed authenticated Ask parity validation")
        return
    }
    print("\nSelected request profile: \(selection.profileName)")
    print("The selected profile and runtime bundle will be reused for every live Ask request")

    var summaryAnswers: [AskLiveAnswer] = []
    for chatIndex in 1 ... freshChatCount {
        print("\nChat \(chatIndex): server-issued summary")
        do {
            let answer = try await runAskLiveChat(
                videoId: videoId,
                selection: selection,
                includeFollowUp: includeFollowUp,
                verbose: verbose
            )
            summaryAnswers.append(answer)
        } catch {
            print("❌ Chat \(chatIndex) failed: \(error.localizedDescription)")
            return
        }
    }

    if summaryAnswers.count > 1 {
        print("\nFresh-chat validation:")
        print("  Successful independent bootstraps: \(summaryAnswers.count)")
        if summaryAnswers.contains(where: \.wasTruncated) {
            print("  Generated summaries exactly equal: not evaluated (truncated answer)")
        } else {
            let firstAnswer = summaryAnswers[0].text
            let allEqual = summaryAnswers.dropFirst().allSatisfy { $0.text == firstAnswer }
            print("  Generated summaries exactly equal: \(allEqual ? "yes" : "no")")
        }
        print("  Conversation identifiers: not displayed or inferred")
    }
}

func auditAskVideo(_ videoId: String, verbose: Bool) async {
    guard isValidYouTubeVideoID(videoId) else {
        print("❌ Invalid YouTube video ID")
        return
    }

    if !youtubeMode {
        activateYouTubeMode()
    }
    guard !authUserOptionWasSpecified, globalBrandAccountId == nil else {
        print("❌ ask-video-audit does not support --authuser or --brand")
        print("   The watch-page GET cannot safely guarantee the same selected identity as API probes.")
        return
    }

    let authenticated = !forceUnauthenticatedRequests && hasUsableAuthMaterial()
    print("🔬 Ask Gemini / YouChat API audit")
    print("=================================\n")
    print("Video ID: \(videoId)")
    print("Auth material: \(authenticated ? "✅ available (server validity checked below)" : "⚠️ unavailable")")
    print("Safety: read-only probes; no prompt is submitted; opaque values remain hidden")
    if verbose {
        print("Verbose mode remains schema-only; raw response values are never emitted")
    }
    print()

    do {
        print("1) Watch-next bootstrap (`next`)")
        let nextResponse = try await makeWireRequest(
            endpoint: "next",
            body: ["videoId": videoId],
            authenticated: authenticated
        )
        print(wireResponseAuditSummary(
            data: nextResponse.data,
            statusCode: nextResponse.statusCode,
            contentType: nextResponse.contentType
        ))
        let nextEnvelope = try? YouTubeAskWireDecoder.decode(nextResponse.data)
        let parsedBootstrap = nextEnvelope.flatMap { envelope in
            try? YouTubeAskParser.parseBootstrap(from: envelope)
        } ?? nil
        let nextJSON = try? JSONSerialization.jsonObject(with: nextResponse.data) as? [String: Any]
        if let nextEnvelope,
           let loggedOut = askParityServerLoggedOutState(in: nextEnvelope)
        {
            print("  Server session: \(loggedOut ? "❌ signed out" : "✅ signed in")")
            if loggedOut, authenticated {
                print("  ⚠️ The available cookie export was not accepted as a signed-in YouTube WEB session.")
            }
        }

        let nextSuggestions = parsedBootstrap?.suggestions ?? []
        print("  Server-issued query suggestions: \(nextSuggestions.count)")
        if nextSuggestions.contains(where: { isAskSummaryLabel($0.label) }) {
            print("  Summary suggestion: ✅ available")
            if verbose, let nextJSON {
                let schemaSuggestions = askPanelSuggestions(in: nextJSON)
                if let summarySuggestion = schemaSuggestions.first(where: \.isSummarySuggestion) {
                    print("  Summary suggestion schema (values hidden):")
                    for layer in summarySuggestion.schemaLayers {
                        print("    - \(layer)")
                    }
                }
                print("  Summary chip schema tree (values hidden):")
                if let summaryChip = firstAskSchemaValue(
                    forKey: "chipData",
                    in: nextJSON
                ) {
                    for line in askSchemaTree(summaryChip, maximumDepth: 7) {
                        print("    - \(line)")
                    }
                }
                for commandKey in ["sendUserQueryCommand", "formDataDecoratorCommand"] {
                    print("  \(commandKey) schema (values hidden):")
                    if let command = firstAskSchemaValue(forKey: commandKey, in: nextJSON) {
                        for line in askSchemaTree(command, maximumDepth: 10) {
                            print("    - \(line)")
                        }
                    } else {
                        print("    - unavailable")
                    }
                }
            }
        } else {
            print("  Summary suggestion: unavailable")
        }

        print("\n2) Ask panel bootstrap (`get_panel`, server-issued continuation)")
        if let panelCommand = parsedBootstrap?.panelCommand {
            let panelBodyData = YouTubeAskRequestBuilder.makePanelBootstrapBody(
                command: panelCommand
            )
            guard let panelBody = try JSONSerialization.jsonObject(with: panelBodyData) as? [String: Any] else {
                throw NSError(
                    domain: "APIExplorer",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not construct the Ask panel bootstrap body"]
                )
            }
            let panelResponse = try await makeWireRequest(
                endpoint: "get_panel",
                body: panelBody,
                authenticated: authenticated
            )
            print(wireResponseAuditSummary(
                data: panelResponse.data,
                statusCode: panelResponse.statusCode,
                contentType: panelResponse.contentType
            ))
            if let panelEnvelope = try? YouTubeAskWireDecoder.decode(panelResponse.data),
               let panelConversation = try? YouTubeAskParser.parseConversation(from: panelEnvelope)
            {
                let suggestions = panelConversation.suggestions
                print("  Server-issued panel suggestions: \(suggestions.count)")
                print("  Panel summary suggestion: \(suggestions.contains(where: { isAskSummaryLabel($0.label) }) ? "✅ available" : "unavailable")")
            }
        } else {
            print("   No server-issued Ask panel continuation was available.")
        }

        print("\n3) Combined watch bootstrap (`get_watch`)")
        let getWatchResponse = try await makeWireRequest(
            endpoint: "get_watch",
            body: [
                "playerRequest": ["videoId": videoId],
                "watchNextRequest": ["videoId": videoId],
            ],
            authenticated: authenticated
        )
        print(wireResponseAuditSummary(
            data: getWatchResponse.data,
            statusCode: getWatchResponse.statusCode,
            contentType: getWatchResponse.contentType
        ))

        print("\n4) AI answer transport capability (`get_answer`, empty read-only probe)")
        let answerResponse = try await makeWireRequest(
            endpoint: "get_answer",
            body: [:],
            authenticated: authenticated
        )
        print(wireResponseAuditSummary(
            data: answerResponse.data,
            statusCode: answerResponse.statusCode,
            contentType: answerResponse.contentType
        ))

        print("\n5) Current web frontend capability markers")
        var watchComponents = URLComponents(string: "https://www.youtube.com/watch")
        watchComponents?.queryItems = [URLQueryItem(name: "v", value: videoId)]
        guard let watchURL = watchComponents?.url else {
            print("   ❌ Could not construct watch URL")
            return
        }
        let pageResponse = try await fetchYouTubeWebResource(
            watchURL, authenticated: authenticated
        )
        guard (200 ... 299).contains(pageResponse.statusCode),
              let pageMediaType = normalizedMediaType(pageResponse.contentType),
              ["text/html", "application/xhtml+xml"].contains(pageMediaType),
              let html = String(data: pageResponse.data, encoding: .utf8)
        else {
            print("   ❌ Watch page source unavailable or not HTML (HTTP \(pageResponse.statusCode))")
            return
        }

        var mainJavaScript: String?
        if let scriptURL = extractYouTubeMainAppJavaScriptURL(
            from: html, baseURL: watchURL
        ) {
            do {
                let scriptResponse = try await fetchYouTubeWebResource(
                    scriptURL, authenticated: false
                )
                if (200 ... 299).contains(scriptResponse.statusCode),
                   let scriptMediaType = normalizedMediaType(scriptResponse.contentType),
                   [
                       "application/ecmascript", "application/javascript",
                       "text/ecmascript", "text/javascript",
                   ].contains(scriptMediaType),
                   let script = String(data: scriptResponse.data, encoding: .utf8)
                {
                    mainJavaScript = script
                    print(
                        "   Watch page HTTP \(pageResponse.statusCode), main app HTTP \(scriptResponse.statusCode)"
                    )
                } else {
                    print("   Watch page HTTP \(pageResponse.statusCode); main app source unavailable")
                }
            } catch let error as ResponseSizeLimitError {
                print("   Main app source skipped: \(error.localizedDescription)")
            } catch {
                print("   Watch page HTTP \(pageResponse.statusCode); main app source unavailable")
            }
        } else {
            print("   Watch page HTTP \(pageResponse.statusCode); main app asset not found")
        }
        print(youtubeAIFrontendCapabilitySummary(
            html: html, mainJavaScript: mainJavaScript
        ))
        if verbose, let mainJavaScript {
            print()
            print(youtubeAIFrontendFlowDebugSummary(mainJavaScript: mainJavaScript))
        }
    } catch {
        print("❌ Audit failed: \(error.localizedDescription)")
    }
}

// MARK: - AskVideoAuditSafety

private enum AskVideoAuditSafety {
    static func canonicalFieldName(_ value: String) -> String {
        value.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            if (48 ... 57).contains(scalar.value) || (97 ... 122).contains(scalar.value) {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    static func safeSchemaName(_ key: String, maximumLength: Int = 100) -> String? {
        guard !key.isEmpty, key.count <= maximumLength else { return nil }
        let allowed = key.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 36, 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
        return allowed ? key : nil
    }

    private static let fixedResponseKeys: Set<String> = [
        "apiUrl", "clickTrackingParams", "clientMessageId", "command", "commandMetadata",
        "content", "contents", "continuation", "conversationId", "currentVideoEndpoint",
        "engagementPanels", "formDataDecoratorCommand", "frameworkUpdates", "getAnswerCommand",
        "globalConfiguration", "header", "identifier", "inputComposerFormData", "label",
        "onResponseReceivedCommand", "onResponseReceivedCommands", "pageContext", "panelIdentifier",
        "params", "placeholder", "placeholderText", "playerOverlays", "playerResponse",
        "previousClientMessageId", "responseContext", "responseType", "runs", "sendUserQueryCommand",
        "simpleText", "subStreamResponseCompleted", "tag", "targetId", "text", "timedCommand",
        "title", "token", "topbar", "trackingParams", "updateConversationIdCommand",
        "videoSummaryContentViewModel", "videoSummaryParagraphViewModel", "watchNextResponse",
        "webCommandMetadata", "wireChunks", "youchatPendingResponseEntity",
    ]

    static func safeResponseKey(_ key: String) -> String? {
        if self.fixedResponseKeys.contains(key) {
            return key
        }
        if key.hasSuffix("Renderer") {
            return "<renderer-key>"
        }
        if key.hasSuffix("ViewModel") {
            return "<view-model-key>"
        }
        if key.hasSuffix("Command") {
            return "<command-key>"
        }
        if key.hasSuffix("Endpoint") {
            return "<endpoint-key>"
        }
        if key.hasSuffix("Entity") {
            return "<entity-key>"
        }
        return nil
    }

    static func appending(key: String, to path: String) -> String {
        if let safeKey = safeResponseKey(key), self.isSimplePathKey(safeKey) {
            return "\(path).\(safeKey)"
        }
        let safeKey = Self.safeResponseKey(key) ?? "<redacted-key>"
        return "\(path)[\(String(reflecting: safeKey))]"
    }

    static func safeYouTubeInnerTubePath(from rawValue: String) -> String? {
        guard !rawValue.isEmpty, rawValue.count <= 2048,
              let components = URLComponents(string: rawValue)
        else {
            return nil
        }
        if components.scheme != nil || components.host != nil {
            guard components.scheme?.lowercased() == "https",
                  let host = components.host?.lowercased(),
                  Self.isYouTubeHost(host)
            else {
                return nil
            }
        } else {
            guard rawValue.hasPrefix("/"), !rawValue.hasPrefix("//") else { return nil }
        }
        let path = components.percentEncodedPath
        guard !path.contains("%"),
              path.hasPrefix("/youtubei/v1/"),
              path.count <= 256
        else {
            return nil
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard (3 ... 6).contains(segments.count),
              segments.allSatisfy({ segment in
                  !segment.isEmpty && segment.count <= 64
                      && segment.unicodeScalars.allSatisfy { scalar in
                          switch scalar.value {
                          case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                              true
                          default:
                              false
                          }
                      }
              })
        else {
            return nil
        }
        return path
    }

    static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    static func isOpaqueField(key: String, value: Any) -> Bool {
        let canonical = Self.canonicalFieldName(key)
        if canonical.contains("token") || canonical.contains("params")
            || canonical == "conversationid" || canonical.hasSuffix("conversationid")
            || canonical == "continuation" || canonical.hasSuffix("continuationtoken")
            || canonical.contains("tracking") || canonical.contains("visitor")
            || canonical.contains("datasync") || canonical.contains("nonce")
            || canonical.contains("serialized") || canonical.contains("integrity")
            || canonical == "clientmessageid" || canonical == "previousclientmessageid"
            || canonical == "pendingsuggestedqueryidentifier" || canonical == "pagecontext"
            || canonical.contains("authorization") || canonical.contains("cookie")
        {
            return true
        }
        return canonical.contains("continuation") && value is String
    }

    static func isConversationIdentifierField(_ field: String) -> Bool {
        let canonical = Self.canonicalFieldName(field)
        return canonical == "conversationid" || canonical.hasSuffix("conversationid")
    }

    static func trimASCIIWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var lowerBound = 0
        var upperBound = bytes.count
        while lowerBound < upperBound, Self.isASCIIWhitespace(bytes[lowerBound]) {
            lowerBound += 1
        }
        while upperBound > lowerBound, Self.isASCIIWhitespace(bytes[upperBound - 1]) {
            upperBound -= 1
        }
        return Array(bytes[lowerBound ..< upperBound])
    }

    static func skipASCIIWhitespace(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, self.isASCIIWhitespace(bytes[index]) {
            index += 1
        }
    }

    static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 13 || byte == 32
    }

    private static func isSimplePathKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              key.count <= 80,
              first.value == 36 || first.value == 95 || (65 ... 90).contains(first.value)
              || (97 ... 122).contains(first.value)
        else {
            return false
        }
        return key.unicodeScalars.dropFirst().allSatisfy { scalar in
            scalar.value == 36 || scalar.value == 95 || (48 ... 57).contains(scalar.value)
                || (65 ... 90).contains(scalar.value) || (97 ... 122).contains(scalar.value)
        }
    }
}

// MARK: - AskVideoResponseAuditor

private struct AskVideoResponseAuditor {
    struct Observation {
        var count = 0
        var samples: [String] = []

        mutating func record(_ sample: String, limit: Int = 5) {
            self.count += 1
            if self.samples.count < limit, !self.samples.contains(sample) {
                self.samples.append(sample)
            }
        }
    }

    struct Report {
        var markers: [String: Observation] = [:]
        var endpoints: [String: Observation] = [:]
        var opaqueFields: [String: Observation] = [:]
        var visitedNodes = 0
        var truncated = false

        var hasAIEvidence: Bool {
            self.truncated || !self.markers.isEmpty || !self.endpoints.isEmpty
                || !self.opaqueFields.isEmpty
        }

        func rendered() -> String {
            var lines = [
                "Ask Gemini / YouChat response audit",
                "  Traversed nodes: \(self.visitedNodes)\(self.truncated ? " (bounded; traversal truncated)" : "")",
            ]
            Self.append(self.markers, title: "AI identifiers and commands", to: &lines)
            Self.append(self.endpoints, title: "AI-related YouTube InnerTube apiUrl paths", to: &lines)
            Self.append(self.opaqueFields, title: "Opaque AI request fields (values redacted)", to: &lines)
            return lines.joined(separator: "\n")
        }

        private static func append(
            _ observations: [String: Observation],
            title: String,
            to lines: inout [String]
        ) {
            lines.append("  \(title):")
            guard !observations.isEmpty else {
                lines.append("    - none detected")
                return
            }
            for (name, observation) in observations.sorted(by: { $0.key < $1.key }) {
                lines.append("    - \(name): \(observation.count) occurrence(s)")
                if !observation.samples.isEmpty {
                    lines.append("      samples: \(observation.samples.joined(separator: ", "))")
                }
            }
        }
    }

    private static let maximumDepth = 80
    private static let maximumVisitedNodes = 100_000
    private static let maximumChildrenPerContainer = 2048
    private static let maximumObservationKinds = 128
    private static let markers: Set<String> = [
        "CONTINUATION_REQUEST_TYPE_GET_PANEL", "PAai_companion", "PAyouchat",
        "engagement-panel-youchat", "formDataDecoratorCommand", "getAnswerCommand",
        "inputComposerFormData", "sendUserQueryCommand", "updateConversationIdCommand",
        "videoSummaryContentViewModel", "videoSummaryParagraphViewModel",
        "youchatPendingResponseEntity",
    ]
    private static let aiEndpoints: Set<String> = [
        "/youtubei/v1/get_answer", "/youtubei/v1/get_panel",
        "/youtubei/v1/get_watch", "/youtubei/v1/streaming_panel",
    ]

    private var report = Report()
    mutating func audit(_ response: [String: Any]) -> Report {
        self.walk(response, path: "$", depth: 0, aiRelevant: false)
        return self.report
    }

    private mutating func walk(
        _ value: Any,
        path: String,
        depth: Int,
        aiRelevant: Bool
    ) {
        guard depth <= Self.maximumDepth, self.report.visitedNodes < Self.maximumVisitedNodes else {
            self.report.truncated = true
            return
        }
        self.report.visitedNodes += 1

        if let dictionary = value as? [String: Any] {
            let dictionaryIsAIRelevant = aiRelevant || Self.hasDirectAISignal(dictionary)
            let keys = dictionary.keys.prefix(Self.maximumChildrenPerContainer).sorted()
            if dictionary.count > Self.maximumChildrenPerContainer {
                self.report.truncated = true
            }
            for key in keys {
                guard self.report.visitedNodes < Self.maximumVisitedNodes else {
                    self.report.truncated = true
                    break
                }
                guard let nestedValue = dictionary[key] else { continue }
                let nestedPath = AskVideoAuditSafety.appending(key: key, to: path)
                let keyMarker = Self.markerLabel(for: key)
                let valueMarker = (nestedValue as? String).flatMap(Self.fixedMarkerLabel)
                let nestedIsAIRelevant = dictionaryIsAIRelevant || keyMarker != nil || valueMarker != nil

                if let keyMarker {
                    if !Self.record(keyMarker, sample: "\(nestedPath) [key]", in: &self.report.markers) {
                        self.report.truncated = true
                    }
                }
                if let valueMarker {
                    if !Self.record(valueMarker, sample: "\(nestedPath) [value]", in: &self.report.markers) {
                        self.report.truncated = true
                    }
                }
                if key == "apiUrl", let rawURL = nestedValue as? String,
                   let endpoint = AskVideoAuditSafety.safeYouTubeInnerTubePath(from: rawURL),
                   Self.aiEndpoints.contains(endpoint)
                {
                    if !Self.record(endpoint, sample: nestedPath, in: &self.report.endpoints) {
                        self.report.truncated = true
                    }
                }

                let fieldIsOpaque = AskVideoAuditSafety.isOpaqueField(key: key, value: nestedValue)
                if fieldIsOpaque,
                   nestedIsAIRelevant || AskVideoAuditSafety.isConversationIdentifierField(key)
                {
                    let field = AskVideoAuditSafety.safeResponseKey(key) ?? "<opaque-field>"
                    let length = (nestedValue as? String).map { "characters=\($0.count)" } ?? "present"
                    if !Self.record(field, sample: "\(nestedPath) (\(length))", in: &self.report.opaqueFields) {
                        self.report.truncated = true
                    }
                }
                if nestedIsAIRelevant, !fieldIsOpaque, Self.isAITextField(key),
                   let text = nestedValue as? String
                {
                    let field = AskVideoAuditSafety.safeResponseKey(key) ?? "<ai-text>"
                    if !Self.record(
                        "\(field) text",
                        sample: "\(nestedPath) (characters=\(text.count), value hidden)",
                        in: &self.report.opaqueFields
                    ) {
                        self.report.truncated = true
                    }
                }
                self.walk(
                    nestedValue,
                    path: nestedPath,
                    depth: depth + 1,
                    aiRelevant: nestedIsAIRelevant
                )
            }
        } else if let array = value as? [Any] {
            if array.count > Self.maximumChildrenPerContainer {
                self.report.truncated = true
            }
            for (index, nestedValue) in array.prefix(Self.maximumChildrenPerContainer).enumerated() {
                guard self.report.visitedNodes < Self.maximumVisitedNodes else {
                    self.report.truncated = true
                    break
                }
                self.walk(
                    nestedValue,
                    path: "\(path)[\(index)]",
                    depth: depth + 1,
                    aiRelevant: aiRelevant
                )
            }
        }
    }

    @discardableResult
    private static func record(
        _ name: String,
        sample: String,
        in observations: inout [String: Observation]
    ) -> Bool {
        guard observations[name] != nil || observations.count < self.maximumObservationKinds else {
            return false
        }
        var observation = observations[name] ?? Observation()
        observation.record(sample)
        observations[name] = observation
        return true
    }

    private static func markerLabel(for candidate: String) -> String? {
        if self.markers.contains(candidate) {
            return candidate
        }
        let canonical = AskVideoAuditSafety.canonicalFieldName(candidate)
        let schemaSuffixes = ["renderer", "viewmodel", "command", "endpoint", "entity"]
        guard candidate.count <= 128,
              candidate.lowercased().contains("youchat"),
              schemaSuffixes.contains(where: canonical.hasSuffix),
              AskVideoAuditSafety.safeSchemaName(candidate, maximumLength: 128) != nil
        else {
            return nil
        }
        return "otherYouChatSchemaMarker"
    }

    private static func fixedMarkerLabel(for candidate: String) -> String? {
        self.markers.contains(candidate) ? candidate : nil
    }

    private static func hasDirectAISignal(_ dictionary: [String: Any]) -> Bool {
        dictionary.prefix(self.maximumChildrenPerContainer).contains { key, value in
            if Self.markerLabel(for: key) != nil
                || AskVideoAuditSafety.isConversationIdentifierField(key)
                || (value as? String).flatMap(Self.markerLabel) != nil
            {
                return true
            }
            guard key == "apiUrl", let rawURL = value as? String,
                  let endpoint = AskVideoAuditSafety.safeYouTubeInnerTubePath(from: rawURL)
            else {
                return false
            }
            return Self.aiEndpoints.contains(endpoint)
        }
    }

    private static func isAITextField(_ key: String) -> Bool {
        let fields: Set = [
            "accessibilitylabel", "content", "description", "header", "label", "message",
            "placeholder", "placeholdertext", "simpletext", "text", "title",
        ]
        return fields.contains(AskVideoAuditSafety.canonicalFieldName(key))
    }
}

// MARK: - WireResponseAuditor

private enum WireResponseAuditor {
    private struct ParsedChunks {
        let chunks: [Any]
        let truncated: Bool
        let limitDescription: String?
    }

    private static let maximumAuditedBytes = 32 * 1024 * 1024
    private static let maximumFrameBytes = 4 * 1024 * 1024
    private static let maximumFrames = 256
    private static let maximumChildrenPerContainer = 2048
    private static let maximumRendererKinds = 256
    private static let maximumTopLevelKeys = 30
    private static let maximumRendererTypes = 20

    static func summary(data: Data, statusCode: Int, contentType: String?) -> String {
        guard data.count <= self.maximumAuditedBytes else {
            return [
                "Wire response audit",
                "  HTTP status: \(statusCode)",
                "  Content type: \(self.safeMediaType(contentType))",
                "  Byte count: \(data.count)",
                "  Classification: response exceeds 32 MiB audit limit",
                "  Response bytes: not parsed or displayed",
            ].joined(separator: "\n")
        }
        let prepared = Self.prepare(data)
        let decoded = Self.decode(data: prepared.data, hadXSSI: prepared.hadXSSI)
        var lines = [
            "Wire response audit",
            "  HTTP status: \(statusCode)",
            "  Content type: \(Self.safeMediaType(contentType))",
            "  Byte count: \(data.count)",
            "  Classification: \(decoded.classification)",
            "  JSON chunk count: \(decoded.chunks.count)",
        ]
        guard !decoded.chunks.isEmpty else {
            lines += ["  Top-level keys: unavailable", "  Response bytes: not displayed"]
            return lines.joined(separator: "\n")
        }

        let topLevelKeyResult = Self.topLevelKeys(in: decoded.chunks)
        let topLevelKeys = topLevelKeyResult.keys
        let shownKeys = topLevelKeys.prefix(Self.maximumTopLevelKeys)
        let remainder = topLevelKeys.count - shownKeys.count
        lines.append(topLevelKeys.isEmpty
            ? "  Top-level keys: none (array or scalar root)"
            : "  Top-level keys (\(topLevelKeys.count)): \(shownKeys.joined(separator: ", "))\(remainder > 0 ? " (+\(remainder) more)" : "")")
        if topLevelKeyResult.truncated {
            lines.append("  Top-level key collection truncated")
        }

        var rendererCounts: [String: Int] = [:]
        var visitedNodes = 0
        var truncated = false
        for chunk in decoded.chunks {
            guard visitedNodes < 100_000 else {
                truncated = true
                break
            }
            Self.collectRenderers(
                in: chunk,
                depth: 0,
                counts: &rendererCounts,
                visitedNodes: &visitedNodes,
                truncated: &truncated
            )
        }
        if rendererCounts.isEmpty {
            lines.append("  Renderer/view-model keys: none detected")
            if truncated {
                lines.append("  Renderer traversal truncated after \(visitedNodes) nodes")
            }
        } else {
            lines.append("  Renderer/view-model keys:")
            let sorted = rendererCounts.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }
            for (name, count) in sorted.prefix(Self.maximumRendererTypes) {
                lines.append("    - \(name): \(count)")
            }
            if sorted.count > Self.maximumRendererTypes {
                lines.append("    - +\(sorted.count - Self.maximumRendererTypes) more type(s)")
            }
            if truncated {
                lines.append("    - traversal bounded after \(visitedNodes) nodes")
            }
        }

        var askAuditor = AskVideoResponseAuditor()
        let root = decoded.chunks.count == 1
            ? (decoded.chunks.first as? [String: Any] ?? ["wireChunks": decoded.chunks])
            : ["wireChunks": decoded.chunks]
        let askReport = askAuditor.audit(root)
        if askReport.hasAIEvidence {
            lines.append(askReport.rendered())
        }
        return lines.joined(separator: "\n")
    }

    private static func prepare(_ data: Data) -> (data: Data, hadXSSI: Bool) {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        var start = 0
        AskVideoAuditSafety.skipASCIIWhitespace(in: bytes, index: &start)
        let prefixes = [Array(")]}'".utf8), Array("for(;;);".utf8), Array("while(1);".utf8)]
        let prefix = prefixes.first { candidate in
            candidate.count <= bytes.count - start
                && bytes[start ..< start + candidate.count].elementsEqual(candidate)
        }
        if let prefix {
            start += prefix.count
            if start < bytes.count, bytes[start] == 44 {
                start += 1
            }
            AskVideoAuditSafety.skipASCIIWhitespace(in: bytes, index: &start)
        }
        return (start < bytes.count ? Data(bytes[start...]) : Data(), prefix != nil)
    }

    private static func decode(data: Data, hadXSSI: Bool) -> (classification: String, chunks: [Any]) {
        let trimmed = Data(AskVideoAuditSafety.trimASCIIWhitespace([UInt8](data)))
        let prefix = hadXSSI ? "XSSI-prefixed " : ""
        guard !trimmed.isEmpty else { return (prefix + "empty response", []) }
        if let json = Self.parseJSON(trimmed) {
            if let array = json as? [Any] {
                let chunks = Array(array.prefix(Self.maximumFrames))
                let suffix = array.count > Self.maximumFrames
                    ? " (truncated to \(Self.maximumFrames) frames)"
                    : ""
                return (prefix + "JSON array" + suffix, chunks)
            }
            return (prefix + "JSON " + Self.rootType(json), [json])
        }
        if let parsed = Self.parseLengthPrefixedJSON(trimmed) {
            let suffix = parsed.limitDescription.map { " (\($0))" }
                ?? (parsed.truncated ? " (truncated at \(Self.maximumFrames) frames)" : "")
            return (prefix + "length-prefixed JSON stream" + suffix, parsed.chunks)
        }
        if let parsed = Self.parseNewlineDelimitedJSON(trimmed) {
            let suffix = parsed.limitDescription.map { " (\($0))" }
                ?? (parsed.truncated ? " (truncated at \(Self.maximumFrames) frames)" : "")
            return (prefix + "newline-delimited JSON stream" + suffix, parsed.chunks)
        }
        return (prefix + (Self.isLikelyText(trimmed) ? "opaque text response" : "opaque/binary response"), [])
    }

    private static func parseJSON(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func parseLengthPrefixedJSON(_ data: Data) -> ParsedChunks? {
        let bytes = [UInt8](data)
        var index = 0
        var chunks: [Any] = []
        while true {
            AskVideoAuditSafety.skipASCIIWhitespace(in: bytes, index: &index)
            if index >= bytes.count {
                break
            }
            if chunks.count >= Self.maximumFrames {
                return ParsedChunks(chunks: chunks, truncated: true, limitDescription: nil)
            }
            let lineStart = index
            while index < bytes.count, bytes[index] != 10, bytes[index] != 13 {
                index += 1
            }
            guard index < bytes.count else { return nil }
            let lengthBytes = AskVideoAuditSafety.trimASCIIWhitespace(Array(bytes[lineStart ..< index]))
            guard !lengthBytes.isEmpty,
                  lengthBytes.allSatisfy({ (48 ... 57).contains($0) })
            else {
                return nil
            }
            var length = 0
            for byte in lengthBytes {
                let digit = Int(byte - 48)
                if length > (Self.maximumFrameBytes - digit) / 10 {
                    return ParsedChunks(
                        chunks: chunks,
                        truncated: true,
                        limitDescription: "frame exceeds 4 MiB audit limit"
                    )
                }
                length = length * 10 + digit
            }
            guard length > 0 else { return nil }
            if length > Self.maximumFrameBytes {
                return ParsedChunks(
                    chunks: chunks,
                    truncated: true,
                    limitDescription: "frame exceeds 4 MiB audit limit"
                )
            }
            if bytes[index] == 13 {
                index += 1
                if index < bytes.count, bytes[index] == 10 {
                    index += 1
                }
            } else {
                index += 1
            }
            guard length <= bytes.count - index,
                  let chunk = Self.parseJSON(Data(bytes[index ..< index + length]))
            else {
                return nil
            }
            chunks.append(chunk)
            index += length
        }
        return chunks.isEmpty
            ? nil
            : ParsedChunks(chunks: chunks, truncated: false, limitDescription: nil)
    }

    private static func parseNewlineDelimitedJSON(_ data: Data) -> ParsedChunks? {
        let bytes = [UInt8](data)
        var chunks: [Any] = []
        var lineStart = 0
        var index = 0
        while index <= bytes.count {
            if chunks.count >= Self.maximumFrames {
                let remaining = bytes[index...]
                let hasMoreData = remaining.contains { !AskVideoAuditSafety.isASCIIWhitespace($0) }
                return ParsedChunks(
                    chunks: chunks,
                    truncated: hasMoreData,
                    limitDescription: nil
                )
            }
            if index < bytes.count, bytes[index] != 10 {
                guard index - lineStart <= Self.maximumFrameBytes else {
                    return ParsedChunks(
                        chunks: chunks,
                        truncated: true,
                        limitDescription: "frame exceeds 4 MiB audit limit"
                    )
                }
                index += 1
                continue
            }

            let line = AskVideoAuditSafety.trimASCIIWhitespace(Array(bytes[lineStart ..< index]))
            lineStart = index + 1
            index += 1
            if line.isEmpty {
                continue
            }
            if line.count > Self.maximumFrameBytes {
                return ParsedChunks(
                    chunks: chunks,
                    truncated: true,
                    limitDescription: "frame exceeds 4 MiB audit limit"
                )
            }
            guard !line.allSatisfy({ (48 ... 57).contains($0) }),
                  let chunk = Self.parseJSON(Data(line))
            else {
                return nil
            }
            chunks.append(chunk)
        }
        return chunks.count >= 2
            ? ParsedChunks(chunks: chunks, truncated: false, limitDescription: nil)
            : nil
    }

    private static func collectRenderers(
        in value: Any,
        depth: Int,
        counts: inout [String: Int],
        visitedNodes: inout Int,
        truncated: inout Bool
    ) {
        guard depth <= 80, visitedNodes < 100_000 else {
            truncated = true
            return
        }
        visitedNodes += 1
        if let dictionary = value as? [String: Any] {
            if dictionary.count > self.maximumChildrenPerContainer {
                truncated = true
            }
            for (key, nestedValue) in dictionary.prefix(self.maximumChildrenPerContainer) {
                guard visitedNodes < 100_000 else {
                    truncated = true
                    break
                }
                if key.hasSuffix("Renderer") || key.hasSuffix("ViewModel") {
                    let safeKey = AskVideoAuditSafety.safeResponseKey(key) ?? "<redacted-renderer-key>"
                    if counts[safeKey] != nil || counts.count < self.maximumRendererKinds {
                        counts[safeKey, default: 0] += 1
                    } else {
                        truncated = true
                    }
                }
                self.collectRenderers(
                    in: nestedValue,
                    depth: depth + 1,
                    counts: &counts,
                    visitedNodes: &visitedNodes,
                    truncated: &truncated
                )
            }
        } else if let array = value as? [Any] {
            if array.count > Self.maximumChildrenPerContainer {
                truncated = true
            }
            for nestedValue in array.prefix(Self.maximumChildrenPerContainer) {
                guard visitedNodes < 100_000 else {
                    truncated = true
                    break
                }
                Self.collectRenderers(
                    in: nestedValue,
                    depth: depth + 1,
                    counts: &counts,
                    visitedNodes: &visitedNodes,
                    truncated: &truncated
                )
            }
        }
    }

    private static func topLevelKeys(in chunks: [Any]) -> (keys: [String], truncated: Bool) {
        var keys: Set<String> = []
        var truncated = false
        func collect(_ dictionary: [String: Any]) {
            if dictionary.count > 128 {
                truncated = true
            }
            for key in dictionary.keys.prefix(128) where keys.count < 128 {
                keys.insert(AskVideoAuditSafety.safeResponseKey(key) ?? "<redacted-key>")
            }
            if keys.count >= 128, dictionary.count > 128 {
                truncated = true
            }
        }
        for chunk in chunks.prefix(Self.maximumFrames) {
            if keys.count >= 128 {
                truncated = true
                break
            }
            if let dictionary = chunk as? [String: Any] {
                collect(dictionary)
            } else if let array = chunk as? [Any] {
                if array.count > Self.maximumChildrenPerContainer {
                    truncated = true
                }
                for case let dictionary as [String: Any] in array.prefix(Self.maximumChildrenPerContainer) {
                    guard keys.count < 128 else { break }
                    collect(dictionary)
                }
            }
        }
        return (keys.sorted(), truncated)
    }

    private static func rootType(_ value: Any) -> String {
        value is [String: Any] ? "object" : (value is [Any] ? "array" : "scalar")
    }

    private static func safeMediaType(_ contentType: String?) -> String {
        guard let contentType else { return "unknown" }
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let recognized: Set = [
            "application/ecmascript", "application/javascript", "application/json",
            "application/octet-stream", "application/problem+json", "application/xhtml+xml",
            "text/ecmascript", "text/html", "text/javascript", "text/plain",
        ]
        guard let mediaType else { return "unknown" }
        return recognized.contains(mediaType) ? mediaType : "other"
    }

    private static func isLikelyText(_ data: Data) -> Bool {
        guard String(data: data, encoding: .utf8) != nil else { return false }
        let bytes = [UInt8](data)
        guard !bytes.contains(0) else { return false }
        let controls = bytes.filter { $0 < 32 && !AskVideoAuditSafety.isASCIIWhitespace($0) }.count
        return bytes.isEmpty || controls * 10 <= bytes.count
    }
}

// MARK: - YouTubeMainAppScriptExtractor

private enum YouTubeMainAppScriptExtractor {
    private struct Candidate {
        let url: URL
        let score: Int
        let order: Int
    }

    static func extract(from html: String, baseURL: URL) -> URL? {
        guard let baseHost = baseURL.host?.lowercased(),
              AskVideoAuditSafety.isYouTubeHost(baseHost),
              let expression = try? NSRegularExpression(
                  pattern: #"<script\b[^>]*>"#,
                  options: [.caseInsensitive, .dotMatchesLineSeparators]
              )
        else {
            return nil
        }

        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        var candidates: [Candidate] = []
        for (order, match) in expression.matches(in: html, range: range).enumerated() {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let attributes = Self.attributes(in: tag)
            guard let source = attributes["src"],
                  let url = Self.safeScriptURL(source, baseURL: baseURL)
            else {
                continue
            }
            let lowerTag = tag.lowercased()
            let lowerSource = source.lowercased()
            let identifiers = ["id", "name", "data-id", "data-name"]
                .compactMap { attributes[$0]?.lowercased() }
            let score = if lowerTag.contains("ytmainappweb") {
                100
            } else if identifiers.contains("base-js"),
                      lowerSource.contains("/s/desktop/"), lowerSource.contains("/jsbin/")
            {
                90
            } else if lowerSource.contains("/jsbin/ytmainappweb")
                || lowerSource.contains("/jsbin/www-main-app")
                || lowerSource.contains("/jsbin/desktop_polymer")
            {
                80
            } else {
                0
            }
            if score > 0 {
                candidates.append(Candidate(url: url, score: score, order: order))
            }
        }
        return candidates.max { lhs, rhs in
            lhs.score == rhs.score ? lhs.order > rhs.order : lhs.score < rhs.score
        }?.url
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#,
            options: .caseInsensitive
        ) else {
            return [:]
        }
        let range = NSRange(tag.startIndex ..< tag.endIndex, in: tag)
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            for capture in 2 ... 4 where match.range(at: capture).location != NSNotFound {
                if let valueRange = Range(match.range(at: capture), in: tag) {
                    result[tag[nameRange].lowercased()] = Self.decodeHTMLEntities(String(tag[valueRange]))
                    break
                }
            }
        }
        return result
    }

    private static func safeScriptURL(_ source: String, baseURL: URL) -> URL? {
        let decoded = Self.decodeHTMLEntities(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              Self.effectivePort(url) == Self.effectivePort(baseURL),
              url.user == nil, url.password == nil
        else {
            return nil
        }
        return url
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
    }
}

// MARK: - YouTubeAIFrontendCapabilityAuditor

private enum YouTubeAIFrontendCapabilityAuditor {
    private struct Capability {
        let label: String
        let needles: [String]
    }

    private static let capabilities = [
        Capability(label: "/youtubei/v1/get_answer", needles: ["/youtubei/v1/get_answer", "\"get_answer\""]),
        Capability(label: "/youtubei/v1/get_panel", needles: ["/youtubei/v1/get_panel", "\"get_panel\""]),
        Capability(label: "/youtubei/v1/streaming_panel", needles: ["/youtubei/v1/streaming_panel", "\"streaming_panel\""]),
        Capability(label: "/youtubei/v1/get_watch", needles: ["/youtubei/v1/get_watch", "\"get_watch\""]),
        Capability(label: "PAyouchat", needles: ["PAyouchat"]),
        Capability(label: "engagement-panel-youchat", needles: ["engagement-panel-youchat"]),
        Capability(label: "PAai_companion", needles: ["PAai_companion"]),
        Capability(label: "inputComposerFormData", needles: ["inputComposerFormData"]),
        Capability(label: "sendUserQueryCommand", needles: ["sendUserQueryCommand"]),
        Capability(label: "CONTINUATION_REQUEST_TYPE_GET_PANEL", needles: ["CONTINUATION_REQUEST_TYPE_GET_PANEL"]),
        Capability(label: "youchatPendingResponseEntity", needles: ["youchatPendingResponseEntity"]),
    ]

    static func summary(html: String, mainJavaScript: String?) -> String {
        var detected = 0
        var lines = [
            "YouTube AI frontend capability audit",
            "  HTML characters scanned: \(html.count)",
            "  Main JavaScript: \(mainJavaScript == nil ? "not provided" : "provided")",
        ]
        for capability in Self.capabilities {
            let htmlCount = capability.needles.reduce(0) { $0 + Self.count($1, in: html) }
            let scriptCount = mainJavaScript.map { script in
                capability.needles.reduce(0) { $0 + Self.count($1, in: script) }
            } ?? 0
            if htmlCount > 0 || scriptCount > 0 {
                detected += 1
            }
            let htmlStatus = htmlCount > 0 ? "present (\(htmlCount))" : "absent"
            let scriptStatus = mainJavaScript == nil
                ? "not scanned"
                : (scriptCount > 0 ? "present (\(scriptCount))" : "absent")
            lines.append("  - \(capability.label): HTML=\(htmlStatus), mainJS=\(scriptStatus)")
        }
        lines += [
            "  Detected capabilities: \(detected)/\(Self.capabilities.count)",
            "  Source contents: not displayed",
        ]
        return lines.joined(separator: "\n")
    }

    private static func count(_ needle: String, in haystack: String) -> Int {
        var count = 0
        var start = haystack.startIndex
        while start < haystack.endIndex,
              let range = haystack.range(of: needle, range: start ..< haystack.endIndex)
        {
            count += 1
            start = range.upperBound
        }
        return count
    }
}

// MARK: - YouTubeAIFrontendFlowDebugAuditor

private enum YouTubeAIFrontendFlowDebugAuditor {
    private static let markers = [
        "chipData",
        "lastMessageIdEntityKey",
        "sendUserQueryCommand",
        "inputComposerFormData",
        "pendingSuggestedQueryIdentifier",
        "clientMessageId",
        "userInputText",
    ]

    private static let preservedIdentifiers: Set<String> = [
        "CONTINUATION_REQUEST_TYPE_GET_PANEL",
        "clientMessageId",
        "chipData",
        "clickTrackingParams",
        "content",
        "continuation",
        "continuationCommand",
        "conversationId",
        "currentUtcTimeMillis",
        "formData",
        "formDataDecoratorCommand",
        "get_panel",
        "id",
        "innertubeCommand",
        "inputComposerFormData",
        "lastMessageIdEntityKey",
        "listMutationCommand",
        "onClick",
        "pageContext",
        "pendingStateEntityKey",
        "pendingSuggestedQueryIdentifier",
        "playerOffsetMs",
        "previousClientMessageId",
        "request",
        "sendUserQueryCommand",
        "streaming_panel",
        "text",
        "token",
        "transparentWhenLoading",
        "userInputText",
    ]

    static func summary(mainJavaScript: String) -> String {
        var lines = [
            "YouTube AI frontend flow contexts",
            "  Source is normalized; non-schema identifiers and string values are removed",
        ]
        for marker in Self.markers {
            let contexts = Self.contexts(around: marker, in: mainJavaScript)
            lines.append("  - \(marker): \(contexts.count) normalized context(s)")
            for context in contexts {
                lines.append("    \(context)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func contexts(around marker: String, in source: String) -> [String] {
        var contexts: [String] = []
        var searchStart = source.startIndex
        while contexts.count < 4,
              searchStart < source.endIndex,
              let range = source.range(of: marker, range: searchStart ..< source.endIndex)
        {
            let lower = source.index(range.lowerBound, offsetBy: -520, limitedBy: source.startIndex)
                ?? source.startIndex
            let upper = source.index(range.upperBound, offsetBy: 760, limitedBy: source.endIndex)
                ?? source.endIndex
            let normalized = Self.normalize(String(source[lower ..< upper]))
            if !contexts.contains(normalized) {
                contexts.append(normalized)
            }
            searchStart = range.upperBound
        }
        return contexts
    }

    private static func normalize(_ source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var output = ""
        var index = 0
        var emittedWhitespace = false

        func append(_ value: String) {
            output.append(value)
            emittedWhitespace = false
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !emittedWhitespace {
                    output.append(" ")
                    emittedWhitespace = true
                }
                index += 1
                continue
            }
            if scalar == "\"" || scalar == "'" {
                let quote = scalar
                var value = ""
                index += 1
                var escaped = false
                while index < scalars.count {
                    let current = scalars[index]
                    index += 1
                    if escaped {
                        escaped = false
                        continue
                    }
                    if current == "\\" {
                        escaped = true
                        continue
                    }
                    if current == quote {
                        break
                    }
                    value.unicodeScalars.append(current)
                }
                append(Self.preservedIdentifiers.contains(value) ? "\"\(value)\"" : "\"<s>\"")
                continue
            }
            if Self.isIdentifierStart(scalar) {
                var identifier = ""
                identifier.unicodeScalars.append(scalar)
                index += 1
                while index < scalars.count, Self.isIdentifierContinue(scalars[index]) {
                    identifier.unicodeScalars.append(scalars[index])
                    index += 1
                }
                append(Self.preservedIdentifiers.contains(identifier) ? identifier : "v")
                continue
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                while index < scalars.count,
                      CharacterSet.decimalDigits.contains(scalars[index])
                {
                    index += 1
                }
                append("n")
                continue
            }
            append(String(scalar))
            index += 1
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "$" || scalar == "_" || CharacterSet.letters.contains(scalar)
    }

    private static func isIdentifierContinue(_ scalar: Unicode.Scalar) -> Bool {
        self.isIdentifierStart(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
}
