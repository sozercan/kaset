import CoreFoundation
import Foundation

// MARK: - WebPlaybackTrackedNavigation

struct WebPlaybackTrackedNavigation: Equatable {
    let generation: UInt64
    var pendingSeek: Double?
    var didCommit = false
    var didActivatePlaybackOrigin = false

    init(generation: UInt64, pendingSeek: Double? = nil) {
        self.generation = generation
        self.pendingSeek = pendingSeek
    }
}

// MARK: - WebPlaybackCancelledNavigation

struct WebPlaybackCancelledNavigation {
    let generation: UInt64
    let shouldReportFailure: Bool
}

// MARK: - WebPlaybackNavigationFailure

enum WebPlaybackNavigationFailure {
    private static let webKitErrorDomain = "WebKitErrorDomain"
    private static let frameLoadInterruptedByPolicyChange = 102

    static func isRetryableCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == URLError.cancelled.rawValue {
            return true
        }
        return error.domain == Self.webKitErrorDomain
            && error.code == Self.frameLoadInterruptedByPolicyChange
    }
}

// MARK: - WebPlaybackDocumentGeneration

/// Tracks which WebView document is allowed to mutate native playback state.
///
/// Reserving or starting a navigation suppresses bridge events from the outgoing
/// document. The new generation becomes current only after WebKit commits that
/// document. Cancelling or failing before commit restores the last committed
/// document. Teardown invalidates every previously issued generation.
struct WebPlaybackDocumentGeneration: Equatable {
    static let urlQueryKey = "kasetDocumentGeneration"
    static let blankURLFragmentKey = "kasetBlankGeneration"
    private static let trustedRedirectHosts: Set<String> = [
        "accounts.google.com",
        "consent.google.com",
        "consent.youtube.com",
    ]

    static let mediaSuppressionScript = """
    (function() {
        window.__kasetPlaybackSuppressed = true;
        if (!window.__kasetPlaybackSuppressionInstalled) {
            window.__kasetPlaybackSuppressionInstalled = true;
            document.addEventListener('play', function(event) {
                if (!window.__kasetPlaybackSuppressed) return;
                const media = event.target;
                if (media && typeof media.pause === 'function') media.pause();
            }, true);
        }
        document.querySelectorAll('video, audio').forEach(function(media) {
            try { media.pause(); } catch (e) {}
        });
    })();
    """

    private(set) var currentGeneration: UInt64 = 0
    private(set) var pendingGeneration: UInt64?
    private(set) var inFlightGeneration: UInt64?
    private(set) var committedIntermediaryGeneration: UInt64?
    private(set) var blankNavigationGeneration: UInt64?
    private var nextGeneration: UInt64 = 0
    private var startedGenerations: Set<UInt64> = []
    private var validatedPlaybackResponse: ValidatedPlaybackResponse?

    private struct ValidatedPlaybackResponse: Equatable {
        let generation: UInt64
        let videoID: String
    }

    /// Generation that should be injected into the next document-start scripts.
    var userScriptGeneration: UInt64 {
        self.pendingGeneration ?? self.inFlightGeneration ?? self.currentGeneration
    }

    /// Reserves a generation for the next document and suppresses the currently
    /// committed document until this request commits, fails, or is cancelled.
    mutating func beginNavigation() -> UInt64 {
        self.nextGeneration &+= 1
        self.pendingGeneration = self.nextGeneration
        self.committedIntermediaryGeneration = nil
        self.blankNavigationGeneration = nil
        self.validatedPlaybackResponse = nil
        return self.nextGeneration
    }

    /// Marks a still-current reserved generation as provisionally loading.
    /// This intentionally does not replace `currentGeneration`; WebKit may keep
    /// the previous document alive if the provisional navigation is cancelled.
    @discardableResult
    mutating func startNavigation(_ generation: UInt64) -> Bool {
        guard self.pendingGeneration == generation else { return false }
        self.startedGenerations.insert(generation)
        self.inFlightGeneration = generation
        self.pendingGeneration = nil
        return true
    }

    /// Promotes a provisionally loading generation after WebKit commits it.
    @discardableResult
    mutating func commitNavigation(
        _ generation: UInt64,
        expectedVideoID: String? = nil
    ) -> Bool {
        if let expectedVideoID {
            guard self.validatedPlaybackResponse == ValidatedPlaybackResponse(
                generation: generation,
                videoID: expectedVideoID
            ) else { return false }
        }
        guard self.startedGenerations.remove(generation) != nil else { return false }
        let didAdvance = generation > self.currentGeneration
        let didCommitCurrentProvisional = self.inFlightGeneration == generation
        if didAdvance {
            self.currentGeneration = generation
        }
        if didCommitCurrentProvisional {
            self.inFlightGeneration = nil
        }
        self.committedIntermediaryGeneration = nil
        self.blankNavigationGeneration = nil
        self.validatedPlaybackResponse = nil
        return didAdvance || didCommitCurrentProvisional
    }

    /// Records a committed trusted auth/consent document as the explicit owner
    /// of subsequent tokenless continuations for this one in-flight generation.
    @discardableResult
    mutating func commitIntermediaryNavigation(_ generation: UInt64) -> Bool {
        guard self.startedGenerations.contains(generation),
              self.inFlightGeneration == generation,
              self.pendingGeneration == nil
        else { return false }
        self.committedIntermediaryGeneration = generation
        self.validatedPlaybackResponse = nil
        return true
    }

    /// Records the successful expected playback response observed before commit.
    @discardableResult
    mutating func recordSuccessfulPlaybackResponse(
        url: URL?,
        host expectedHost: String,
        videoID: String
    ) -> Bool {
        guard let generation = self.inFlightGeneration,
              Self.generation(from: url) == generation,
              Self.isExpectedPlaybackURL(
                  url,
                  host: expectedHost,
                  videoID: videoID
              )
        else { return false }
        self.validatedPlaybackResponse = ValidatedPlaybackResponse(
            generation: generation,
            videoID: videoID
        )
        return true
    }

    /// Cancels a request before `WKWebView.load` starts, allowing the existing
    /// committed document to publish bridge events again.
    mutating func cancelPendingNavigation() {
        self.pendingGeneration = nil
        self.committedIntermediaryGeneration = nil
        self.validatedPlaybackResponse = nil
    }

    /// Cancels or fails a tracked provisional navigation before commit. Returns
    /// `true` only when it was the newest provisional navigation whose failure
    /// changes which generation should be installed for the next document.
    @discardableResult
    mutating func cancelInFlightNavigation(_ generation: UInt64) -> Bool {
        guard self.startedGenerations.remove(generation) != nil else { return false }
        let didCancelCurrentProvisional = self.inFlightGeneration == generation
        if didCancelCurrentProvisional {
            self.inFlightGeneration = nil
            self.committedIntermediaryGeneration = nil
            self.validatedPlaybackResponse = nil
        }
        return didCancelCurrentProvisional
    }

    /// Invalidates all documents issued before teardown or WebView replacement.
    mutating func invalidate() {
        self.nextGeneration &+= 1
        self.currentGeneration = self.nextGeneration
        self.pendingGeneration = nil
        self.inFlightGeneration = nil
        self.committedIntermediaryGeneration = nil
        self.blankNavigationGeneration = nil
        self.startedGenerations.removeAll()
        self.validatedPlaybackResponse = nil
    }

    /// Invalidates playback documents and grants one exact internal blank URL
    /// permission for explicit teardown/recovery blanking.
    mutating func beginBlankNavigation() -> UInt64 {
        self.invalidate()
        self.blankNavigationGeneration = self.currentGeneration
        return self.currentGeneration
    }

    func ownsBlankNavigation(_ url: URL?) -> Bool {
        guard let blankNavigationGeneration else { return false }
        return Self.blankGeneration(from: url) == blankNavigationGeneration
    }

    /// Returns whether a bridge payload belongs to the one committed document.
    /// While a newer navigation is reserved or provisionally loading, all
    /// outgoing-document messages are suppressed.
    func accepts(generation: UInt64) -> Bool {
        self.pendingGeneration == nil
            && self.inFlightGeneration == nil
            && generation == self.currentGeneration
    }

    /// Media-key commands may arrive from the still-current committed document
    /// while its replacement is pending/provisional. Accept only commands issued
    /// after that replacement began; a delayed older event must not overwrite the
    /// newer native selection intent.
    func acceptsUserCommand(
        generation: UInt64,
        issuedAtMilliseconds: Double?,
        navigationStartedAtMilliseconds: Double?
    ) -> Bool {
        guard generation == self.currentGeneration else { return false }
        guard self.pendingGeneration != nil || self.inFlightGeneration != nil else {
            return true
        }
        guard let issuedAtMilliseconds,
              issuedAtMilliseconds.isFinite,
              let navigationStartedAtMilliseconds,
              navigationStartedAtMilliseconds.isFinite
        else { return false }
        return issuedAtMilliseconds >= navigationStartedAtMilliseconds
    }

    /// Returns whether post-load work still belongs to the active document.
    /// A committed navigation may finish after a newer selection has already
    /// reserved, started, or committed another generation.
    func canFinishNavigation(_ generation: UInt64) -> Bool {
        self.pendingGeneration == nil
            && self.inFlightGeneration == nil
            && generation == self.currentGeneration
    }

    func accepts(rawGeneration: Any?) -> Bool {
        guard let generation = Self.decode(rawGeneration) else { return false }
        return self.accepts(generation: generation)
    }

    static func decode(_ rawGeneration: Any?) -> UInt64? {
        guard let rawGeneration else { return nil }

        if let generation = rawGeneration as? NSNumber {
            guard CFGetTypeID(generation) != CFBooleanGetTypeID() else { return nil }
            return Self.decodeFloatingPoint(generation.doubleValue)
        }
        if let generation = rawGeneration as? UInt64 {
            return generation
        }
        if let generation = rawGeneration as? UInt {
            return UInt64(generation)
        }
        if let generation = rawGeneration as? Int {
            return generation >= 0 ? UInt64(generation) : nil
        }
        if let generation = rawGeneration as? Double {
            return Self.decodeFloatingPoint(generation)
        }
        if let generation = rawGeneration as? Float {
            return Self.decodeFloatingPoint(Double(generation))
        }
        return nil
    }

    static func generation(from url: URL?) -> UInt64? {
        let components = url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        let queryGeneration = components?.queryItems?
            .first { $0.name == Self.urlQueryKey }?.value
        let fragmentGeneration = components?.fragment.flatMap {
            URLComponents(string: "?\($0)")?.queryItems?
                .first { $0.name == Self.urlQueryKey }?.value
        }
        let rawGeneration = queryGeneration ?? fragmentGeneration
        guard let rawGeneration else { return nil }
        return UInt64(rawGeneration)
    }

    static func request(_ request: URLRequest, belongsTo generation: UInt64) -> Bool {
        let requestGeneration = Self.generation(from: request.url)
        let mainDocumentGeneration = Self.generation(from: request.mainDocumentURL)
        guard requestGeneration == nil
            || mainDocumentGeneration == nil
            || requestGeneration == mainDocumentGeneration
        else { return false }
        return (requestGeneration ?? mainDocumentGeneration) == generation
    }

    /// Returns whether a main-frame navigation can host the expected playback
    /// bridge. Generation association alone is insufficient: redirects to
    /// consent, captive-portal, or error origins cannot run Kaset's trusted
    /// bridge and would otherwise leave native playback stuck in loading.
    static func isExpectedPlaybackURL(_ url: URL?, host expectedHost: String) -> Bool {
        guard let components = url.flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == expectedHost.lowercased()
    }

    static func isExpectedPlaybackURL(
        _ url: URL?,
        host expectedHost: String,
        videoID: String
    ) -> Bool {
        guard self.isExpectedPlaybackURL(url, host: expectedHost),
              let components = url.flatMap({
                  URLComponents(url: $0, resolvingAgainstBaseURL: false)
              }),
              components.path == "/watch"
        else { return false }
        return components.queryItems?.first { $0.name == "v" }?.value == videoID
    }

    static func isAllowedPlaybackNavigationURL(_ url: URL?, playbackHost: String) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == playbackHost.lowercased() || Self.trustedRedirectHosts.contains(host)
    }

    static func isTrustedIntermediaryURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return Self.trustedRedirectHosts.contains(host)
    }

    static func requestBelongsToNavigationChain(
        _ request: URLRequest,
        currentURL: URL?,
        generation: UInt64,
        playbackHost: String,
        committedIntermediaryGeneration: UInt64? = nil
    ) -> Bool {
        let requestGeneration = Self.generation(from: request.url)
        let mainDocumentGeneration = Self.generation(from: request.mainDocumentURL)
        guard requestGeneration == nil
            || mainDocumentGeneration == nil
            || requestGeneration == mainDocumentGeneration
        else { return false }
        guard Self.isAllowedPlaybackNavigationURL(
            request.url,
            playbackHost: playbackHost
        ) else { return false }
        if let explicitGeneration = requestGeneration ?? mainDocumentGeneration {
            return explicitGeneration == generation
        }
        return committedIntermediaryGeneration == generation
            && Self.isAllowedPlaybackNavigationURL(currentURL, playbackHost: playbackHost)
    }

    static func requestByBindingGeneration(
        _ request: URLRequest,
        generation: UInt64
    ) -> URLRequest? {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == Self.urlQueryKey }
        queryItems.append(URLQueryItem(name: Self.urlQueryKey, value: String(generation)))
        components.queryItems = queryItems
        components.fragment = "\(Self.urlQueryKey)=\(generation)"
        guard let boundURL = components.url else { return nil }
        var boundRequest = request
        boundRequest.url = boundURL
        boundRequest.mainDocumentURL = boundURL
        return boundRequest
    }

    static func javaScriptStringLiteral(_ value: String?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let literal = String(data: data, encoding: .utf8)
        else { return "null" }
        return literal
    }

    static func isFragmentOnlyNavigation(from currentURL: URL?, to proposedURL: URL?) -> Bool {
        guard var current = currentURL.flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }),
            var proposed = proposedURL.flatMap({
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            })
        else { return false }
        let currentFragment = current.fragment
        let proposedFragment = proposed.fragment
        current.fragment = nil
        proposed.fragment = nil
        return current == proposed && currentFragment != proposedFragment
    }

    static func isInternalBlankNavigation(_ url: URL?) -> Bool {
        guard let components = url.flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }) else { return true }
        if components.scheme?.lowercased() == "data" {
            return true
        }
        guard components.scheme?.lowercased() == "about",
              let decodedURL = url?.absoluteString.removingPercentEncoding?.lowercased()
        else { return false }
        return decodedURL == "about:blank" || decodedURL.hasPrefix("about:blank#")
    }

    static func blankURL(generation: UInt64) -> URL? {
        URL(string: "about:blank#\(self.blankURLFragmentKey)=\(generation)")
    }

    static func shouldSuppressCancelledNavigationCommit(
        cancelledGeneration: UInt64,
        committedURL: URL?,
        pendingGeneration: UInt64?,
        inFlightGeneration: UInt64?,
        currentGeneration: UInt64
    ) -> Bool {
        if self.generation(from: committedURL) == cancelledGeneration {
            return true
        }
        let replacementGeneration = pendingGeneration
            ?? inFlightGeneration
            ?? currentGeneration
        if self.generation(from: committedURL) == replacementGeneration {
            return false
        }
        return true
    }

    static func blankGeneration(from url: URL?) -> UInt64? {
        guard self.isInternalBlankNavigation(url),
              let fragment = self.internalBlankFragment(from: url),
              let rawGeneration = URLComponents(string: "?\(fragment)")?.queryItems?
              .first(where: { $0.name == Self.blankURLFragmentKey })?.value
        else { return nil }
        return UInt64(rawGeneration)
    }

    private static func internalBlankFragment(from url: URL?) -> String? {
        if let fragment = url.flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })?.fragment {
            return fragment
        }
        guard let decodedURL = url?.absoluteString.removingPercentEncoding,
              let fragmentStart = decodedURL.firstIndex(of: "#")
        else { return nil }
        return String(decodedURL[decodedURL.index(after: fragmentStart)...])
    }

    static func acceptsMainFrameResponse(_ url: URL?, expectedHost: String) -> Bool {
        guard !self.isInternalBlankNavigation(url) else { return false }
        return self.isAllowedPlaybackNavigationURL(url, playbackHost: expectedHost)
    }

    static func acceptsMainFrameResponse(
        _ response: URLResponse,
        expectedHost: String,
        expectedVideoID: String?,
        allowsInternalBlank: Bool
    ) -> Bool {
        if self.isInternalBlankNavigation(response.url) {
            return allowsInternalBlank
        }
        guard self.isAllowedPlaybackNavigationURL(
            response.url,
            playbackHost: expectedHost
        ),
            let httpResponse = response as? HTTPURLResponse,
            (200 ..< 300).contains(httpResponse.statusCode),
            let responseHost = response.url?.host?.lowercased()
        else { return false }
        if responseHost == expectedHost.lowercased() {
            guard let expectedVideoID else { return false }
            return Self.isExpectedPlaybackURL(
                response.url,
                host: expectedHost,
                videoID: expectedVideoID
            )
        }
        return true
    }

    private static func decodeFloatingPoint(_ value: Double) -> UInt64? {
        guard value.isFinite,
              value >= 0,
              value.rounded(.towardZero) == value,
              value < Double(UInt64.max)
        else { return nil }
        return UInt64(value)
    }
}
