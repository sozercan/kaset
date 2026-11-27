import AppKit
import Foundation

@MainActor
@Observable
final class LastFMService: ScrobbleServiceProtocol {
    let serviceName = "Last.fm"

    private(set) var authState: ScrobbleAuthState = .disconnected

    private let credentialStore: KeychainCredentialStore
    private let session: URLSession
    private let logger = DiagnosticsLogger.scrobbling

    private let workerBaseURL: URL

    private var sessionKey: String?

    // swiftformat:disable modifierOrder
    @ObservationIgnored private var authPollingTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    init(
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        workerBaseURL: URL? = nil,
        session: URLSession = .shared
    ) {
        self.credentialStore = credentialStore
        self.session = session

        if let url = workerBaseURL {
            self.workerBaseURL = url
        } else if let envURL = ProcessInfo.processInfo.environment["KASET_LASTFM_WORKER_URL"],
                  let url = URL(string: envURL)
        {
            self.workerBaseURL = url
        } else if let bundleURL = Bundle.main.object(forInfoDictionaryKey: "LastFMWorkerURL") as? String,
                  let url = URL(string: bundleURL)
        {
            self.workerBaseURL = url
        } else {
            self.workerBaseURL = URL(string: "https://kaset-lastfm.sozercan.workers.dev")!
        }
    }

    deinit {
        authPollingTask?.cancel()
    }

    func restoreSession() {
        if let sessionKey = self.credentialStore.getLastFMSessionKey(),
           let username = self.credentialStore.getLastFMUsername()
        {
            self.sessionKey = sessionKey
            self.authState = .connected(username: username)
            self.logger.info("Restored Last.fm session for user: \(username)")
        }
    }

    func authenticate() async throws {
        self.authState = .authenticating
        self.logger.info("Starting Last.fm authentication")

        do {
            let token = try await self.getAuthToken()
            self.logger.debug("Received auth token")

            let authURL = try await self.getAuthURL(token: token)
            NSWorkspace.shared.open(authURL)
            self.logger.info("Opened Last.fm authorization page in browser")

            self.authPollingTask?.cancel()
            self.authPollingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.pollForSession(token: token)
            }
        } catch {
            self.authState = .error(error.localizedDescription)
            self.logger.error("Authentication failed: \(error.localizedDescription)")
            throw error
        }
    }

    func disconnect() async {
        self.authPollingTask?.cancel()
        self.authPollingTask = nil
        self.sessionKey = nil
        self.credentialStore.removeLastFMCredentials()
        self.authState = .disconnected
        self.logger.info("Disconnected from Last.fm")
    }

    func updateNowPlaying(_ track: ScrobbleTrack) async throws {
        guard let sessionKey = self.sessionKey else {
            throw ScrobbleError.sessionExpired
        }

        var body: [String: Any] = [
            "sk": sessionKey,
            "artist": track.artist,
            "track": track.title,
        ]
        if let album = track.album {
            body["album"] = album
        }
        if let duration = track.duration {
            body["duration"] = Int(duration)
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = try await self.postJSON(endpoint: "nowplaying", bodyData: bodyData, baseURL: self.workerBaseURL)
        try self.checkForErrors(response)

        self.logger.debug("Now playing: \(track.title) by \(track.artist)")
    }

    func scrobble(_ tracks: [ScrobbleTrack]) async throws -> [ScrobbleResult] {
        guard let sessionKey = self.sessionKey else {
            throw ScrobbleError.sessionExpired
        }

        guard !tracks.isEmpty else {
            return []
        }

        let scrobblePayloads: [[String: Any]] = tracks.map { track in
            var payload: [String: Any] = [
                "artist": track.artist,
                "track": track.title,
                "timestamp": Int(track.timestamp.timeIntervalSince1970),
            ]
            if let album = track.album {
                payload["album"] = album
            }
            if let duration = track.duration {
                payload["duration"] = Int(duration)
            }
            return payload
        }

        let body: [String: Any] = [
            "sk": sessionKey,
            "scrobbles": scrobblePayloads,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = try await self.postJSON(endpoint: "scrobble", bodyData: bodyData, baseURL: self.workerBaseURL)
        try self.checkForErrors(response)

        self.logger.info("Scrobbled \(tracks.count) track(s)")

        return Self.parseScrobbleResponse(response, tracks: tracks)
    }

    func validateSession() async throws -> Bool {
        guard let sessionKey = self.sessionKey else {
            return false
        }

        let body: [String: Any] = ["sk": sessionKey]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        do {
            let response = try await self.postJSON(endpoint: "auth/validate", bodyData: bodyData, baseURL: self.workerBaseURL)
            if response["error"] != nil {
                self.logger.warning("Session validation failed")
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func getAuthToken() async throws -> String {
        let url = self.workerBaseURL.appendingPathComponent("auth/token")
        let (data, _) = try await self.session.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String
        else {
            throw ScrobbleError.invalidResponse("Missing auth token in response")
        }

        return token
    }

    private func getAuthURL(token: String) async throws -> URL {
        let url = self.workerBaseURL
            .appendingPathComponent("auth/url")
            .appending(queryItems: [URLQueryItem(name: "token", value: token)])

        let (data, _) = try await self.session.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String,
              let authURL = URL(string: urlString)
        else {
            throw ScrobbleError.invalidResponse("Missing auth URL in response")
        }

        return authURL
    }

    private func pollForSession(token: String) async {
        let maxAttempts = 60
        var attempts = 0

        while !Task.isCancelled, attempts < maxAttempts {
            attempts += 1

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            do {
                let url = self.workerBaseURL
                    .appendingPathComponent("auth/session")
                    .appending(queryItems: [URLQueryItem(name: "token", value: token)])

                let (data, _) = try await self.session.data(from: url)

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let errorCode = json["error"] as? Int, errorCode == 14 {
                    continue
                }

                if let session = json["session"] as? [String: Any],
                   let key = session["key"] as? String,
                   let name = session["name"] as? String
                {
                    try self.credentialStore.saveLastFMSessionKey(key)
                    try self.credentialStore.saveLastFMUsername(name)
                    self.sessionKey = key
                    self.authState = .connected(username: name)
                    self.logger.info("Successfully authenticated as: \(name)")
                    return
                }

                if let errorMsg = json["message"] as? String {
                    self.authState = .error(errorMsg)
                    self.logger.error("Auth session error: \(errorMsg)")
                    return
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                self.logger.debug("Auth polling attempt \(attempts) failed: \(error.localizedDescription)")
            }
        }

        if !Task.isCancelled {
            self.authState = .error("Authorization timed out. Please try again.")
            self.logger.warning("Auth polling timed out after \(maxAttempts) attempts")
        }
    }

    // swiftformat:disable modifierOrder
    nonisolated private func postJSON(endpoint: String, bodyData: Data, baseURL: URL) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, httpResponse) = try await self.session.data(for: request)

        guard let response = httpResponse as? HTTPURLResponse else {
            throw ScrobbleError.invalidResponse("Non-HTTP response")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScrobbleError.invalidResponse("Invalid JSON response (status \(response.statusCode))")
        }

        return json
    }

    // swiftformat:disable modifierOrder
    nonisolated private func checkForErrors(_ response: [String: Any]) throws {
        if let errorCode = response["error"] as? Int {
            let message = response["message"] as? String ?? "Unknown error"

            switch errorCode {
            case 4:
                throw ScrobbleError.sessionExpired
            case 9:
                throw ScrobbleError.invalidCredentials
            case 11, 16:
                throw ScrobbleError.serviceUnavailable
            case 17:
                throw ScrobbleError.serviceUnavailable
            case 29:
                throw ScrobbleError.rateLimited(retryAfter: nil)
            default:
                throw ScrobbleError.invalidResponse("Last.fm error \(errorCode): \(message)")
            }
        }

        if let errorMessage = response["error"] as? String {
            throw ScrobbleError.invalidResponse("Worker error: \(errorMessage)")
        }
    }

    // swiftformat:disable modifierOrder
    nonisolated static func parseScrobbleResponse(
        _ response: [String: Any],
        tracks: [ScrobbleTrack]
    ) -> [ScrobbleResult] {
        guard let scrobblesWrapper = response["scrobbles"] as? [String: Any] else {
            return tracks.map { ScrobbleResult(track: $0, accepted: false, errorMessage: "Malformed response: missing scrobbles key") }
        }

        let scrobbleEntries: [[String: Any]]
        if let single = scrobblesWrapper["scrobble"] as? [String: Any] {
            scrobbleEntries = [single]
        } else if let array = scrobblesWrapper["scrobble"] as? [[String: Any]] {
            scrobbleEntries = array
        } else {
            return tracks.map { ScrobbleResult(track: $0, accepted: true) }
        }

        var results: [ScrobbleResult] = []
        for (index, track) in tracks.enumerated() {
            if index < scrobbleEntries.count {
                let entry = scrobbleEntries[index]
                let ignoredObj = entry["ignoredMessage"] as? [String: Any]
                let ignoredCode = ignoredObj?["code"] as? String
                let ignoredText = ignoredObj?["#text"] as? String
                let accepted = ignoredCode == nil || ignoredCode == "0"

                let correctedArtistFlag = (entry["artist"] as? [String: Any])?["corrected"] as? String
                let correctedTrackFlag = (entry["track"] as? [String: Any])?["corrected"] as? String
                let correctedArtist = correctedArtistFlag == "1"
                    ? (entry["artist"] as? [String: Any])?["#text"] as? String
                    : nil
                let correctedTrack = correctedTrackFlag == "1"
                    ? (entry["track"] as? [String: Any])?["#text"] as? String
                    : nil

                results.append(ScrobbleResult(
                    track: track,
                    accepted: accepted,
                    correctedArtist: correctedArtist,
                    correctedTrack: correctedTrack,
                    errorMessage: accepted ? nil : (ignoredText?.isEmpty == false ? ignoredText : "Ignored (code \(ignoredCode ?? "unknown"))")
                ))
            } else {
                results.append(ScrobbleResult(track: track, accepted: true))
            }
        }

        return results
    }
}
