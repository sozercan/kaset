// swiftlint:disable file_length
import Darwin
import Foundation
@preconcurrency import Network

// MARK: - LocalControlServer

/// HTTP API for local automation and remote-control companions.
@MainActor
final class LocalControlServer {
    static let shared = LocalControlServer()

    private let logger = DiagnosticsLogger.network
    private var listener: NWListener?
    private weak var playerService: PlayerService?
    private var activePort: UInt16?
    private var activeAllowsLAN = false

    private init() {}

    func configure(playerService: PlayerService) {
        self.playerService = playerService
        self.applySettings()
    }

    func applySettings() {
        guard let playerService else { return }
        let settings = SettingsManager.shared

        guard settings.localControlServerEnabled else {
            self.stop()
            return
        }

        let port = UInt16(min(max(settings.localControlServerPort, 1024), 65535))
        let allowsLAN = settings.localControlServerAllowsLAN
        if self.listener != nil, self.activePort == port, self.activeAllowsLAN == allowsLAN {
            return
        }

        self.stop()
        self.start(port: port, allowsLAN: allowsLAN, playerService: playerService)
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
        self.activePort = nil
        self.activeAllowsLAN = false
    }

    private func start(port: UInt16, allowsLAN: Bool, playerService: PlayerService) {
        let hostAddress = allowsLAN ? "0.0.0.0" : "127.0.0.1"

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            if !allowsLAN {
                if let bindAddress = IPv4Address("127.0.0.1") {
                    parameters.requiredLocalEndpoint = .hostPort(
                        host: .ipv4(bindAddress),
                        port: NWEndpoint.Port(rawValue: port) ?? .any
                    )
                }
            }

            let listener = try NWListener(
                using: parameters,
                on: NWEndpoint.Port(rawValue: port) ?? .any
            )
            if allowsLAN {
                listener.service = NWListener.Service(name: "kaset", type: "_http._tcp")
            } else {
                listener.service = nil
            }
            listener.newConnectionHandler = { [weak self, weak playerService] connection in
                Task { @MainActor in
                    guard let self, let playerService else {
                        connection.cancel()
                        return
                    }
                    self.handleConnection(connection, playerService: playerService)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.logger.info("Local control server listening on \(hostAddress):\(port)")
                    case let .failed(error):
                        self.logger.error("Local control server failed: \(error.localizedDescription)")
                        self.stop()
                    case .cancelled:
                        self.logger.info("Local control server stopped")
                    default:
                        break
                    }
                }
            }

            self.listener = listener
            self.activePort = port
            self.activeAllowsLAN = allowsLAN
            listener.start(queue: .main)
        } catch {
            self.logger.error("Local control server could not start: \(error.localizedDescription)")
        }
    }
}

// MARK: - LocalControlServer Connections

extension LocalControlServer {
    private func handleConnection(_ connection: NWConnection, playerService: PlayerService) {
        guard SettingsManager.shared.localControlServerAllowsLAN || self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }

        connection.start(queue: .main)
        self.readRequest(connection: connection, accumulatedData: Data()) { [weak self, weak playerService] data in
            Task { @MainActor in
                guard let self, let playerService else {
                    connection.cancel()
                    return
                }

                let response: HTTPResponse = if let data, let request = HTTPRequest(data: data) {
                    await self.response(for: request, playerService: playerService)
                } else {
                    .badRequest(message: "Invalid HTTP request")
                }

                connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func readRequest(
        connection: NWConnection,
        accumulatedData: Data,
        completion: @escaping @MainActor @Sendable (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }

                if error != nil {
                    completion(nil)
                    return
                }

                var newAccumulated = accumulatedData
                if let data {
                    newAccumulated.append(data)
                }

                if self.isRequestComplete(newAccumulated) {
                    completion(newAccumulated)
                } else if isComplete {
                    completion(newAccumulated.isEmpty ? nil : newAccumulated)
                } else {
                    self.readRequest(connection: connection, accumulatedData: newAccumulated, completion: completion)
                }
            }
        }
    }

    private func isRequestComplete(_ data: Data) -> Bool {
        // Look for the end of headers: \r\n\r\n
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            // Also check for \n\n just in case
            if let lfRange = data.range(of: Data("\n\n".utf8)) {
                return self.isRequestComplete(data, headerBoundaryEnd: lfRange.upperBound)
            }
            return false
        }
        return self.isRequestComplete(data, headerBoundaryEnd: range.upperBound)
    }

    private func isRequestComplete(_ data: Data, headerBoundaryEnd: Data.Index) -> Bool {
        let headersData = data.subdata(in: 0 ..< headerBoundaryEnd)
        guard let headersText = String(data: headersData, encoding: .utf8) else {
            return true // Cannot parse as UTF-8, stop reading
        }

        let lines = headersText.components(separatedBy: "\r\n")
        var contentLength: Int?

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "content-length", let length = Int(value) {
                contentLength = length
                break
            }
        }

        if let contentLength {
            let bodySize = data.count - headerBoundaryEnd
            return bodySize >= contentLength
        }

        return true
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            guard let loopbackAddress = IPv4Address("127.0.0.1") else { return false }
            return address == loopbackAddress
        case let .ipv6(address):
            guard let loopbackAddress = IPv6Address("::1") else { return false }
            return address == loopbackAddress
        case let .name(name, _):
            return name == "localhost"
        default:
            return false
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private func response(for request: HTTPRequest, playerService: PlayerService) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return .empty()
        }

        let routed = Self.route(request)
        if routed != .webInterface, routed != .check, routed != .requestApproval {
            if SettingsManager.shared.localControlServerAllowsLAN, !Self.isAuthorized(request) {
                return .unauthorized(message: "Missing or invalid token")
            }
        }

        switch routed {
        case .webInterface:
            return .html(Self.remoteControlHTML())
        case .check:
            let deviceId = request.queryItems["device_id"] ?? ""
            if RemoteDeviceManager.shared.isDeviceApproved(deviceId: deviceId) {
                RemoteDeviceManager.shared.updateDeviceActivity(deviceId: deviceId)
                let token = RemoteDeviceManager.shared.deviceToken(deviceId: deviceId)
                return .json(["status": "approved", "token": token])
            } else if RemoteDeviceManager.shared.pendingRequests.contains(where: { $0.deviceId == deviceId }) {
                return .json(["status": "pending"])
            } else {
                return .json(["status": "unauthorized"])
            }
        case .requestApproval:
            let deviceId = request.formItems["device_id"] ?? request.queryItems["device_id"] ?? ""
            let deviceName = request.formItems["device_name"] ?? request.queryItems["device_name"] ?? "Remote Web Browser"
            let pin = request.formItems["pin"] ?? request.queryItems["pin"] ?? ""

            if !pin.isEmpty {
                if let token = RemoteDeviceManager.shared.verifyPinAndApprove(deviceId: deviceId, deviceName: deviceName, pin: pin) {
                    return .json(["status": "approved", "token": token])
                } else {
                    return .json(["status": "invalid_pin"])
                }
            } else {
                RemoteDeviceManager.shared.requestApproval(deviceId: deviceId, deviceName: deviceName)
                return .json(["status": "pending"])
            }
        case .status:
            return .json(self.statusPayload(playerService: playerService))
        case .play:
            await playerService.resume()
            return .json(["ok": true, "action": "play"])
        case .pause:
            await playerService.pause()
            return .json(["ok": true, "action": "pause"])
        case .playPause:
            await playerService.playPause()
            return .json(["ok": true, "action": "play-pause"])
        case .next:
            await playerService.next()
            return .json(["ok": true, "action": "next"])
        case .previous:
            await playerService.previous()
            return .json(["ok": true, "action": "previous"])
        case let .volume(value):
            await playerService.setVolume(value)
            return .json(["ok": true, "action": "volume", "volume": playerService.volume])
        case .search:
            let query = request.queryItems["q"] ?? request.queryItems["query"] ?? ""
            let filter = request.queryItems["filter"] ?? "all"
            guard !query.isEmpty else {
                return .json(["results": [], "type": filter])
            }
            guard let client = playerService.ytMusicClient else {
                return .json(["ok": false, "error": "API client not initialized"])
            }
            do {
                if filter == "songs" {
                    let songs = try await client.searchSongs(query: query)
                    let results = songs.map { Self.trackPayload($0) }
                    return .json(["results": results, "type": "songs"])
                } else if filter == "albums" {
                    let response = try await client.searchAlbums(query: query)
                    let results = response.albums.map { Self.albumPayload($0) }
                    return .json(["results": results, "type": "albums"])
                } else if filter == "playlists" {
                    let response = try await client.searchCommunityPlaylists(query: query)
                    let results = response.playlists.map { Self.playlistPayload($0) }
                    return .json(["results": results, "type": "playlists"])
                } else {
                    let response = try await client.search(query: query)
                    var items: [[String: Any]] = []
                    for item in response.allItems {
                        switch item {
                        case let .song(song):
                            var p = Self.trackPayload(song)
                            p["type"] = "song"
                            items.append(p)
                        case let .album(album):
                            var p = Self.albumPayload(album)
                            p["type"] = "album"
                            items.append(p)
                        case let .playlist(playlist):
                            var p = Self.playlistPayload(playlist)
                            p["type"] = "playlist"
                            items.append(p)
                        default:
                            break
                        }
                    }
                    return .json(["results": items, "type": "all"])
                }
            } catch {
                return .json(["ok": false, "error": error.localizedDescription])
            }
        case let .playQueueIndex(index):
            guard index >= 0, index < playerService.queue.count else {
                return .json(["ok": false, "error": "Index out of bounds"])
            }
            let queue = playerService.queue
            await playerService.playQueue(queue, startingAt: index)
            return .json(["ok": true, "action": "playQueueIndex", "index": index])
        case let .playTrack(videoId):
            let song = Song(
                id: videoId,
                title: "Loading...",
                artists: [],
                album: nil,
                duration: nil,
                thumbnailURL: nil,
                videoId: videoId
            )
            await playerService.playWithRadio(song: song)
            return .json(["ok": true, "action": "playTrack", "videoId": videoId])
        case let .playNext(videoId, playlistId, song):
            if let song {
                playerService.insertNextInQueue([song])
                return .json(["ok": true, "action": "playNext", "videoId": videoId ?? ""])
            } else if let playlistId {
                guard let client = playerService.ytMusicClient else {
                    return .json(["ok": false, "error": "API client not initialized"])
                }
                do {
                    let tracks = try await client.getPlaylistAllTracks(playlistId: playlistId)
                    playerService.insertNextInQueue(tracks)
                    return .json(["ok": true, "action": "playNext", "playlistId": playlistId])
                } catch {
                    return .json(["ok": false, "error": error.localizedDescription])
                }
            }
            return .badRequest(message: "Missing parameters")
        case let .addToQueue(videoId, playlistId, song):
            if let song {
                playerService.appendToQueue([song])
                return .json(["ok": true, "action": "addToQueue", "videoId": videoId ?? ""])
            } else if let playlistId {
                guard let client = playerService.ytMusicClient else {
                    return .json(["ok": false, "error": "API client not initialized"])
                }
                do {
                    let tracks = try await client.getPlaylistAllTracks(playlistId: playlistId)
                    playerService.appendToQueue(tracks)
                    return .json(["ok": true, "action": "addToQueue", "playlistId": playlistId])
                } catch {
                    return .json(["ok": false, "error": error.localizedDescription])
                }
            }
            return .badRequest(message: "Missing parameters")
        case let .playPlaylist(playlistId):
            guard let client = playerService.ytMusicClient else {
                return .json(["ok": false, "error": "API client not initialized"])
            }
            do {
                let tracks = try await client.getPlaylistAllTracks(playlistId: playlistId)
                await playerService.playQueue(tracks, startingAt: 0)
                return .json(["ok": true, "action": "playPlaylist", "playlistId": playlistId])
            } catch {
                return .json(["ok": false, "error": error.localizedDescription])
            }
        case let .playlistTracks(playlistId):
            guard let client = playerService.ytMusicClient else {
                return .json(["ok": false, "error": "API client not initialized"])
            }
            do {
                let response = try await client.getPlaylist(id: playlistId)
                let tracks = response.detail.tracks.map { Self.trackPayload($0) }
                return .json(["ok": true, "tracks": tracks, "title": response.detail.title, "playlistId": playlistId])
            } catch {
                return .json(["ok": false, "error": error.localizedDescription])
            }
        case .clearQueue:
            playerService.clearQueueEntirely()
            return .json(["ok": true, "action": "clearQueue"])
        case .notFound:
            return .notFound(message: "Unknown endpoint")
        case .methodNotAllowed:
            return .methodNotAllowed(message: "Unsupported method")
        case let .badRequest(message):
            return .badRequest(message: message)
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    private func statusPayload(playerService: PlayerService) -> [String: Any] {
        var payload: [String: Any] = [
            "state": playerService.state.apiValue,
            "isPlaying": playerService.isPlaying,
            "progress": playerService.progress,
            "duration": playerService.duration,
            "volume": playerService.volume,
            "isMuted": playerService.isMuted,
            "shuffleEnabled": playerService.shuffleEnabled,
            "queueIndex": playerService.currentIndex,
            "queueCount": playerService.queue.count,
        ]

        if let track = playerService.currentTrack {
            payload["track"] = Self.trackPayload(track)
        } else {
            payload["track"] = NSNull()
        }

        payload["queue"] = playerService.queue.map { Self.trackPayload($0) }

        return payload
    }

    static func trackPayload(_ track: Song) -> [String: Any] {
        var payload: [String: Any] = [
            "id": track.id,
            "videoId": track.videoId,
            "title": track.title,
            "artists": track.artists.map(\.name),
            "artist": track.artistsDisplay,
        ]

        if let album = track.album?.title {
            payload["album"] = album
        }
        if let artworkURL = (track.thumbnailURL ?? track.fallbackThumbnailURL)?.absoluteString {
            payload["artworkURL"] = artworkURL
        }
        if let duration = track.duration {
            payload["duration"] = duration
        }
        if let isExplicit = track.isExplicit {
            payload["isExplicit"] = isExplicit
        }

        return payload
    }

    static func albumPayload(_ album: Album) -> [String: Any] {
        var payload: [String: Any] = [
            "id": album.id,
            "title": album.title,
            "artist": album.artistsDisplay,
        ]
        if let artworkURL = album.thumbnailURL?.absoluteString {
            payload["artworkURL"] = artworkURL
        }
        return payload
    }

    static func playlistPayload(_ playlist: Playlist) -> [String: Any] {
        var payload: [String: Any] = [
            "id": playlist.id,
            "title": playlist.title,
            "artist": playlist.author?.name ?? playlist.description ?? "",
        ]
        if let artworkURL = playlist.thumbnailURL?.absoluteString {
            payload["artworkURL"] = artworkURL
        }
        return payload
    }

    // swiftlint:disable cyclomatic_complexity
    static func route(_ request: HTTPRequest) -> Route {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/remote"):
            .webInterface
        case ("GET", "/check"):
            .check
        case ("POST", "/request_approval"):
            .requestApproval
        case ("GET", "/status"):
            .status
        case ("POST", "/play"):
            .play
        case ("POST", "/pause"):
            .pause
        case ("POST", "/play-pause"), ("POST", "/toggle"):
            .playPause
        case ("POST", "/next"):
            .next
        case ("POST", "/previous"):
            .previous
        case ("POST", "/volume"):
            self.volumeRoute(request)
        case ("GET", "/search"):
            .search
        case ("POST", "/play_index"):
            self.playIndexRoute(request)
        case ("POST", "/play_track"):
            self.playTrackRoute(request)
        case ("POST", "/play_next"):
            self.playNextRoute(request)
        case ("POST", "/add_to_queue"):
            self.addToQueueRoute(request)
        case ("POST", "/play_playlist"):
            self.playPlaylistRoute(request)
        case ("GET", "/playlist_tracks"):
            self.playlistTracksRoute(request)
        case ("POST", "/clear_queue"):
            .clearQueue
        case ("GET", _), ("POST", _):
            .notFound
        default:
            .methodNotAllowed
        }
    }

    // swiftlint:enable cyclomatic_complexity

    private static func volumeRoute(_ request: HTTPRequest) -> Route {
        let queryValue = request.queryItems["value"] ?? request.queryItems["level"]
        let bodyValue = request.formItems["value"] ?? request.formItems["level"]
        guard let rawValue = queryValue ?? bodyValue, let value = Double(rawValue) else {
            return .badRequest("Missing numeric volume value")
        }
        return .volume(max(0, min(1, value)))
    }

    private static func playIndexRoute(_ request: HTTPRequest) -> Route {
        let queryValue = request.queryItems["index"] ?? request.formItems["index"]
        guard let rawValue = queryValue, let index = Int(rawValue) else {
            return .badRequest("Missing integer index value")
        }
        return .playQueueIndex(index)
    }

    private static func playTrackRoute(_ request: HTTPRequest) -> Route {
        let queryValue = request.queryItems["videoId"] ?? request.queryItems["video_id"] ??
            request.formItems["videoId"] ?? request.formItems["video_id"]
        guard let videoId = queryValue, !videoId.isEmpty else {
            return .badRequest("Missing videoId parameter")
        }
        return .playTrack(videoId)
    }

    private static func playNextRoute(_ request: HTTPRequest) -> Route {
        let videoId = request.queryItems["videoId"] ?? request.queryItems["video_id"] ?? request.formItems["videoId"] ?? request.formItems["video_id"]
        let playlistId = request.queryItems["playlistId"] ?? request.queryItems["playlist_id"] ?? request.formItems["playlistId"] ?? request.formItems["playlist_id"]

        if let videoId, !videoId.isEmpty {
            let title = request.queryItems["title"] ?? request.formItems["title"] ?? "Loading..."
            let artist = request.queryItems["artist"] ?? request.formItems["artist"] ?? ""
            let artworkURL = request.queryItems["artworkURL"] ?? request.formItems["artworkURL"] ?? request.queryItems["artwork_url"] ?? request.formItems["artwork_url"]
            let artists = artist.isEmpty ? [] : [Artist(id: UUID().uuidString, name: artist, thumbnailURL: nil)]

            let song = Song(
                id: videoId,
                title: title,
                artists: artists,
                album: nil,
                duration: nil,
                thumbnailURL: artworkURL.flatMap { URL(string: $0) },
                videoId: videoId
            )
            return .playNext(videoId: videoId, playlistId: nil, song: song)
        } else if let playlistId, !playlistId.isEmpty {
            return .playNext(videoId: nil, playlistId: playlistId, song: nil)
        } else {
            return .badRequest("Missing videoId or playlistId parameter")
        }
    }

    private static func addToQueueRoute(_ request: HTTPRequest) -> Route {
        let videoId = request.queryItems["videoId"] ?? request.queryItems["video_id"] ?? request.formItems["videoId"] ?? request.formItems["video_id"]
        let playlistId = request.queryItems["playlistId"] ?? request.queryItems["playlist_id"] ?? request.formItems["playlistId"] ?? request.formItems["playlist_id"]

        if let videoId, !videoId.isEmpty {
            let title = request.queryItems["title"] ?? request.formItems["title"] ?? "Loading..."
            let artist = request.queryItems["artist"] ?? request.formItems["artist"] ?? ""
            let artworkURL = request.queryItems["artworkURL"] ?? request.formItems["artworkURL"] ?? request.queryItems["artwork_url"] ?? request.formItems["artwork_url"]
            let artists = artist.isEmpty ? [] : [Artist(id: UUID().uuidString, name: artist, thumbnailURL: nil)]

            let song = Song(
                id: videoId,
                title: title,
                artists: artists,
                album: nil,
                duration: nil,
                thumbnailURL: artworkURL.flatMap { URL(string: $0) },
                videoId: videoId
            )
            return .addToQueue(videoId: videoId, playlistId: nil, song: song)
        } else if let playlistId, !playlistId.isEmpty {
            return .addToQueue(videoId: nil, playlistId: playlistId, song: nil)
        } else {
            return .badRequest("Missing videoId or playlistId parameter")
        }
    }

    private static func playPlaylistRoute(_ request: HTTPRequest) -> Route {
        let playlistId = request.queryItems["playlistId"] ?? request.queryItems["playlist_id"] ?? request.formItems["playlistId"] ?? request.formItems["playlist_id"]
        guard let id = playlistId, !id.isEmpty else {
            return .badRequest("Missing playlistId parameter")
        }
        return .playPlaylist(playlistId: id)
    }

    private static func playlistTracksRoute(_ request: HTTPRequest) -> Route {
        let playlistId = request.queryItems["playlistId"] ?? request.queryItems["playlist_id"] ?? request.formItems["playlistId"] ?? request.formItems["playlist_id"] ?? request.queryItems["id"] ?? request.formItems["id"]
        guard let id = playlistId, !id.isEmpty else {
            return .badRequest("Missing playlistId parameter")
        }
        return .playlistTracks(playlistId: id)
    }

    enum Route: Equatable {
        case webInterface
        case check
        case requestApproval
        case status
        case play
        case pause
        case playPause
        case next
        case previous
        case volume(Double)
        case search
        case playQueueIndex(Int)
        case playTrack(String)
        case playNext(videoId: String?, playlistId: String?, song: Song?)
        case addToQueue(videoId: String?, playlistId: String?, song: Song?)
        case playPlaylist(playlistId: String)
        case playlistTracks(playlistId: String)
        case clearQueue
        case notFound
        case methodNotAllowed
        case badRequest(String)
    }

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let queryItems: [String: String]
        let formItems: [String: String]

        init?(data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let parts = text.components(separatedBy: "\r\n\r\n")
            let head = parts.first ?? ""
            let body = parts.dropFirst().joined(separator: "\r\n\r\n")
            let headLines = head.components(separatedBy: "\r\n")
            guard let requestLine = headLines.first else { return nil }
            let tokens = requestLine.split(separator: " ")
            guard tokens.count >= 2 else { return nil }

            self.method = tokens[0].uppercased()
            let target = String(tokens[1])
            let splitTarget = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            self.path = splitTarget.first.map(String.init) ?? "/"
            self.headers = Self.parseHeaders(Array(headLines.dropFirst()))
            self.queryItems = splitTarget.count > 1 ? Self.parseFormEncoded(String(splitTarget[1])) : [:]
            self.formItems = Self.parseFormEncoded(body)
        }

        init(
            method: String,
            path: String,
            headers: [String: String] = [:],
            queryItems: [String: String] = [:],
            formItems: [String: String] = [:]
        ) {
            self.method = method.uppercased()
            self.path = path
            self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
            self.queryItems = queryItems
            self.formItems = formItems
        }

        private static func parseHeaders(_ lines: [String]) -> [String: String] {
            var headers: [String: String] = [:]
            for line in lines {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    headers[key] = value
                }
            }
            return headers
        }

        private static func parseFormEncoded(_ value: String) -> [String: String] {
            var result: [String: String] = [:]
            for pair in value.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let firstPart = parts.first,
                      let key = String(firstPart).removingPercentEncoding,
                      !key.isEmpty
                else { continue }
                let rawValue = parts.count > 1 ? String(parts[1]) : ""
                let decodedValue = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
                result[key] = decodedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return result
        }
    }

    struct HTTPResponse {
        let statusCode: Int
        let reason: String
        let body: Data
        let contentType: String

        static func json(_ payload: [String: Any], statusCode: Int = 200, reason: String = "OK") -> HTTPResponse {
            let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            return HTTPResponse(
                statusCode: statusCode,
                reason: reason,
                body: body,
                contentType: "application/json; charset=utf-8"
            )
        }

        static func html(_ html: String) -> HTTPResponse {
            HTTPResponse(
                statusCode: 200,
                reason: "OK",
                body: Data(html.utf8),
                contentType: "text/html; charset=utf-8"
            )
        }

        static func empty() -> HTTPResponse {
            HTTPResponse(statusCode: 204, reason: "No Content", body: Data(), contentType: "text/plain; charset=utf-8")
        }

        static func badRequest(message: String) -> HTTPResponse {
            .json(["ok": false, "error": message], statusCode: 400, reason: "Bad Request")
        }

        static func unauthorized(message: String) -> HTTPResponse {
            .json(["ok": false, "error": message], statusCode: 401, reason: "Unauthorized")
        }

        static func notFound(message: String) -> HTTPResponse {
            .json(["ok": false, "error": message], statusCode: 404, reason: "Not Found")
        }

        static func methodNotAllowed(message: String) -> HTTPResponse {
            .json(["ok": false, "error": message], statusCode: 405, reason: "Method Not Allowed")
        }

        func serialized() -> Data {
            var data = Data()
            let header = [
                "HTTP/1.1 \(self.statusCode) \(self.reason)",
                "Content-Type: \(self.contentType)",
                "Content-Length: \(self.body.count)",
                "Cache-Control: no-store",
                "Connection: close",
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, POST, OPTIONS",
                "Access-Control-Allow-Headers: Authorization, Content-Type",
                "",
                "",
            ].joined(separator: "\r\n")
            data.append(Data(header.utf8))
            data.append(self.body)
            return data
        }
    }

    static func isAuthorized(_ request: HTTPRequest) -> Bool {
        let requestToken: String
        if let token = request.queryItems["token"] ?? request.formItems["token"] {
            requestToken = token
        } else if let auth = request.headers["authorization"], auth.hasPrefix("Bearer ") {
            requestToken = String(auth.dropFirst(7))
        } else {
            return false
        }

        return RemoteDeviceManager.shared.approvedDevices.contains(where: { $0.token == requestToken })
    }
}

// MARK: - LocalControlServer Helpers

extension LocalControlServer {
    // swiftlint:disable function_body_length trailing_whitespace
    static func remoteControlHTML() -> String {
        #"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Kaset Remote</title>
          <link rel="preconnect" href="https://fonts.googleapis.com">
          <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
          <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
          <style>
            body {
              margin: 0;
              font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
              background: radial-gradient(circle at top, #2b0d11 0%, #0c0c0e 70%, #050505 100%);
              color: #f6f6f6;
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
            }
            main {
              width: 100%;
              max-width: 440px;
              padding: 24px;
              box-sizing: border-box;
              position: relative;
            }
            h1 {
              font-size: 24px;
              font-weight: 800;
              margin: 0 0 24px;
              text-align: center;
              letter-spacing: -0.5px;
              background: linear-gradient(135deg, #fff 0%, #a1a1a6 100%);
              -webkit-background-clip: text;
              -webkit-text-fill-color: transparent;
            }
            .card {
              padding: 32px 24px;
              border: 1px solid rgba(255, 255, 255, 0.08);
              border-radius: 24px;
              background: rgba(28, 28, 30, 0.55);
              backdrop-filter: blur(20px);
              -webkit-backdrop-filter: blur(20px);
              box-shadow: 0 16px 40px rgba(0, 0, 0, 0.5);
              transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
              position: relative;
            }
            .title {
              font-size: 20px;
              font-weight: 700;
              margin-bottom: 6px;
              color: #fff;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
              text-align: center;
            }
            .artist {
              font-size: 15px;
              color: #a1a1a6;
              margin-bottom: 24px;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
              text-align: center;
            }
            .share-btn {
              position: absolute;
              right: 8px;
              top: 0;
              background: none;
              border: none;
              color: #a1a1a6;
              cursor: pointer;
              padding: 8px;
              border-radius: 50%;
              transition: all 0.2s ease;
              display: flex;
              align-items: center;
              justify-content: center;
            }
            .share-btn:hover {
              color: #fff !important;
              background: rgba(255, 255, 255, 0.08) !important;
            }
            
            /* Toast Message */
            .toast {
              position: fixed;
              bottom: 32px;
              left: 50%;
              transform: translate(-50%, 100px);
              background: rgba(28, 28, 30, 0.95);
              border: 1px solid rgba(255, 255, 255, 0.15);
              border-radius: 16px;
              padding: 12px 20px;
              color: #fff;
              font-size: 14px;
              font-weight: 600;
              box-shadow: 0 12px 32px rgba(0, 0, 0, 0.6);
              display: flex;
              align-items: center;
              gap: 8px;
              z-index: 9999;
              transition: transform 0.4s cubic-bezier(0.16, 1, 0.3, 1);
              pointer-events: none;
            }
            .toast.show {
              transform: translate(-50%, 0);
            }
            .controls {
              display: flex;
              justify-content: center;
              align-items: center;
              gap: 24px;
              margin-top: 12px;
            }
            .control-btn {
              display: flex;
              align-items: center;
              justify-content: center;
              border: 0;
              border-radius: 50%;
              background: rgba(255, 255, 255, 0.08);
              color: #fff;
              cursor: pointer;
              transition: all 0.2s ease;
              outline: none;
            }
            .control-btn:hover {
              background: rgba(255, 255, 255, 0.15);
              transform: scale(1.05);
            }
            .control-btn:active {
              transform: scale(0.95);
            }
            .control-btn.prev, .control-btn.next {
              width: 54px;
              height: 54px;
            }
            .control-btn.play-pause {
              width: 72px;
              height: 72px;
              background: #fff;
              color: #000;
              box-shadow: 0 4px 16px rgba(255, 255, 255, 0.2);
            }
            .control-btn.play-pause:hover {
              background: #f0f0f5;
              transform: scale(1.05);
              box-shadow: 0 6px 20px rgba(255, 255, 255, 0.3);
            }
            .control-btn.play-pause:active {
              transform: scale(0.95);
            }
            .volume-container {
              display: flex;
              align-items: center;
              gap: 12px;
              margin-top: 28px;
            }
            .volume-icon {
              color: #8e8e93;
              display: flex;
              align-items: center;
            }
            input[type="range"] {
              -webkit-appearance: none;
              width: 100%;
              height: 4px;
              border-radius: 2px;
              background: rgba(255, 255, 255, 0.15);
              outline: none;
              margin: 0;
              cursor: pointer;
            }
            input[type="range"]::-webkit-slider-thumb {
              -webkit-appearance: none;
              width: 14px;
              height: 14px;
              border-radius: 50%;
              background: #fff;
              cursor: pointer;
              box-shadow: 0 2px 6px rgba(0, 0, 0, 0.4);
              transition: transform 0.1s ease;
            }
            input[type="range"]::-webkit-slider-thumb:hover {
              transform: scale(1.25);
            }
            
            /* Input & Forms */
            input[type="text"] {
              width: 100%;
              padding: 16px;
              font-size: 22px;
              font-weight: 700;
              letter-spacing: 6px;
              border-radius: 16px;
              border: 1px solid rgba(255, 255, 255, 0.12);
              background: rgba(255, 255, 255, 0.05);
              color: #fff;
              box-sizing: border-box;
              text-align: center;
              margin-bottom: 20px;
              outline: none;
              transition: all 0.25s ease;
            }
            input[type="text"]:focus {
              border-color: #ff3b30;
              background: rgba(255, 255, 255, 0.08);
              box-shadow: 0 0 0 4px rgba(255, 59, 48, 0.2);
            }
            button.action-btn {
              width: 100%;
              min-height: 56px;
              border: 0;
              border-radius: 16px;
              background: linear-gradient(135deg, #ff2d55 0%, #ff3b30 100%);
              color: #fff;
              font-size: 16px;
              font-weight: 600;
              cursor: pointer;
              box-shadow: 0 4px 16px rgba(255, 45, 85, 0.35);
              transition: all 0.2s ease;
              outline: none;
            }
            button.action-btn:hover {
              transform: translateY(-1px);
              box-shadow: 0 6px 20px rgba(255, 45, 85, 0.45);
            }
            button.action-btn:active {
              transform: translateY(1px) scale(0.99);
            }
            .link-btn {
              display: inline-block;
              margin-top: 20px;
              color: rgba(255, 255, 255, 0.5);
              text-decoration: none;
              font-size: 14px;
              font-weight: 500;
              transition: color 0.2s ease;
              cursor: pointer;
            }
            .link-btn:hover {
              color: #fff;
              text-decoration: underline;
            }
            
            .status-container {
              margin-top: 20px;
              padding: 12px;
              border-radius: 12px;
              background: rgba(255, 255, 255, 0.03);
              font-size: 13px;
              color: #8e8e93;
              text-align: center;
            }
            .status-pending {
              color: #ff9500;
              font-weight: 600;
              animation: pulse 2s infinite ease-in-out;
              display: flex;
              align-items: center;
              justify-content: center;
              gap: 6px;
            }
            @keyframes pulse {
              0% { opacity: 0.6; }
              50% { opacity: 1; }
              100% { opacity: 0.6; }
            }
            
            .hidden { display: none !important; }
            .error { color: #ff453a; font-size: 14px; font-weight: 600; margin-bottom: 12px; text-align: center; }
            
            /* Artwork design */
            .artwork-container {
              width: 100%;
              aspect-ratio: 1;
              border-radius: 20px;
              background: rgba(255, 255, 255, 0.03);
              margin-bottom: 24px;
              display: flex;
              align-items: center;
              justify-content: center;
              overflow: hidden;
              border: 1px solid rgba(255, 255, 255, 0.06);
              box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5);
            }
            .artwork-image {
              width: 100%;
              height: 100%;
              object-fit: cover;
            }
            .artwork-placeholder {
              color: rgba(255, 255, 255, 0.15);
              display: flex;
              flex-direction: column;
              align-items: center;
              gap: 12px;
            }
            
            /* Search tabs */
            .search-tabs {
              display: flex;
              gap: 6px;
              margin-top: 8px;
              margin-bottom: 8px;
            }
            .search-tab {
              flex: 1;
              padding: 8px 4px;
              border: 1px solid rgba(255, 255, 255, 0.1);
              background: rgba(255, 255, 255, 0.04);
              color: #a1a1a6;
              border-radius: 8px;
              font-size: 11px;
              font-weight: 600;
              cursor: pointer;
              transition: all 0.2s ease;
              outline: none;
            }
            .search-tab:hover {
              background: rgba(255, 255, 255, 0.1);
              color: #fff;
            }
            .search-tab.active {
              background: #ff2d55;
              border-color: #ff2d55;
              color: #fff;
              box-shadow: 0 2px 8px rgba(255, 45, 85, 0.3);
            }

            /* Search elements */
            .search-results-dropdown {
              position: absolute;
              top: 96px;
              left: 0;
              right: 0;
              background: rgba(28, 28, 30, 0.96);
              border: 1px solid rgba(255, 255, 255, 0.14);
              border-radius: 14px;
              z-index: 100;
              max-height: 280px;
              overflow-y: auto;
              box-shadow: 0 12px 32px rgba(0, 0, 0, 0.75);
              backdrop-filter: blur(20px);
              -webkit-backdrop-filter: blur(20px);
            }
            .search-result-item {
              padding: 10px 14px;
              display: flex;
              align-items: center;
              gap: 12px;
              border-bottom: 1px solid rgba(255, 255, 255, 0.05);
              transition: background 0.2s ease;
              text-align: left;
            }
            .search-result-item:hover {
              background: rgba(255, 255, 255, 0.08);
            }
            .search-result-item img {
              width: 40px;
              height: 40px;
              border-radius: 6px;
              object-fit: cover;
            }
            .search-result-info {
              flex: 1;
              min-width: 0;
            }
            .search-result-title {
              font-size: 14px;
              font-weight: 600;
              color: #fff;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .search-result-artist {
              font-size: 12px;
              color: #8e8e93;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            
            /* Action Buttons inside items */
            .result-actions {
              display: flex;
              gap: 6px;
            }
            .result-act-btn {
              background: rgba(255, 255, 255, 0.06);
              border: none;
              color: #a1a1a6;
              border-radius: 6px;
              width: 28px;
              height: 28px;
              display: flex;
              align-items: center;
              justify-content: center;
              cursor: pointer;
              transition: all 0.2s ease;
            }
            .result-act-btn:hover {
              background: rgba(255, 255, 255, 0.16);
              color: #fff;
            }

            /* Playlist Details Panel */
            .playlist-details-pane {
              position: absolute;
              top: 50px;
              left: 24px;
              right: 24px;
              bottom: 24px;
              background: rgba(18, 18, 20, 0.98);
              border: 1px solid rgba(255, 255, 255, 0.12);
              border-radius: 20px;
              z-index: 110;
              display: flex;
              flex-direction: column;
              box-shadow: 0 16px 40px rgba(0, 0, 0, 0.85);
              backdrop-filter: blur(24px);
              -webkit-backdrop-filter: blur(24px);
              padding: 20px;
              box-sizing: border-box;
            }
            .playlist-details-header {
              margin-bottom: 14px;
              flex-shrink: 0;
            }
            .back-btn {
              background: none;
              border: none;
              color: #ff2d55;
              display: flex;
              align-items: center;
              gap: 6px;
              font-size: 14px;
              font-weight: 600;
              cursor: pointer;
              padding: 0;
              margin-bottom: 10px;
            }
            .playlist-title {
              font-size: 16px;
              font-weight: 800;
              color: #fff;
              margin-bottom: 12px;
              text-align: left;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .playlist-actions {
              display: flex;
              gap: 8px;
              margin-bottom: 4px;
            }
            .playlist-act-btn {
              flex: 1;
              padding: 8px;
              border: 1px solid rgba(255, 255, 255, 0.08);
              background: rgba(255, 255, 255, 0.04);
              color: #fff;
              border-radius: 8px;
              font-size: 12px;
              font-weight: 600;
              cursor: pointer;
              transition: all 0.2s ease;
            }
            .playlist-act-btn.play {
              background: #ff2d55;
              border-color: #ff2d55;
            }
            .playlist-act-btn:hover {
              background: rgba(255, 255, 255, 0.12);
            }
            .playlist-act-btn.play:hover {
              background: #ff3b30;
            }
            .playlist-tracks-list {
              flex: 1;
              overflow-y: auto;
              display: flex;
              flex-direction: column;
              gap: 4px;
            }
            
            /* Queue elements */
            .queue-list {
              display: flex;
              flex-direction: column;
              gap: 4px;
              max-height: 320px;
              overflow-y: auto;
              padding-right: 4px;
            }
            .queue-item {
              padding: 10px 12px;
              display: flex;
              align-items: center;
              gap: 12px;
              border-radius: 10px;
              cursor: pointer;
              transition: all 0.2s ease;
              text-align: left;
            }
            .queue-item:hover {
              background: rgba(255, 255, 255, 0.06);
            }
            .queue-item.active {
              background: rgba(255, 45, 85, 0.12);
              border: 1px solid rgba(255, 45, 85, 0.3);
            }
            .queue-item img {
              width: 36px;
              height: 36px;
              border-radius: 4px;
              object-fit: cover;
            }
            .queue-item-info {
              flex: 1;
              min-width: 0;
            }
            .queue-item-title {
              font-size: 13.5px;
              font-weight: 600;
              color: #fff;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .queue-item-title.active {
              color: #ff2d55;
            }
            .queue-item-artist {
              font-size: 11.5px;
              color: #8e8e93;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
          </style>
        </head>
        <body>
          <div id="toast" class="toast">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline></svg>
            <span id="toast-message"></span>
          </div>
          <main>
            <h1>Kaset Remote</h1>

            <!-- Auth Screen: Enter PIN / Request Access -->
            <section id="screen-auth" class="card hidden">
              <div class="title" style="margin-bottom: 8px;">Access Required</div>
              <p style="color: #a1a1a6; font-size: 14px; line-height: 1.5; margin: 0 0 24px; text-align: center;">
                Enter the global PIN shown in Kaset settings on your Mac, or request access directly.
              </p>
              
              <div id="auth-error" class="error hidden">Invalid PIN, please try again.</div>
              
              <input id="pin-input" type="text" maxlength="6" placeholder="••••">
              
              <button class="action-btn" onclick="requestAccess()">Login with PIN</button>
              
              <div style="text-align: center;">
                <a id="request-link" href="#" onclick="requestHostAccess(); return false;" class="link-btn">Request Access from Host</a>
              </div>
              
              <div id="status-container" class="status-container hidden"></div>
            </section>

            <!-- Controller Screen: Music Player -->
            <section id="screen-player" class="hidden">
              <div class="card">
                <!-- Search Bar and Tabs -->
                <div style="position: relative; margin-bottom: 20px;">
                  <div class="search-input-wrapper" style="position: relative; display: flex; align-items: center; width: 100%;">
                    <input id="search-input" type="text" placeholder="Search..." oninput="handleSearch(this.value)" onfocus="handleSearchFocus(this)" onblur="handleSearchBlur()" style="font-size: 15px; padding: 12px 40px 12px 16px; letter-spacing: 0; text-align: left; margin-bottom: 0; border-radius: 12px;">
                    <button id="clear-search-btn" onclick="clearSearch()" style="position: absolute; right: 12px; background: none; border: none; color: #8e8e93; cursor: pointer; padding: 4px; display: none; align-items: center; justify-content: center; outline: none;">
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
                    </button>
                  </div>
                  
                  <div class="search-tabs">
                    <button class="search-tab active" onclick="setSearchFilter(this, 'all')">All</button>
                    <button class="search-tab" onclick="setSearchFilter(this, 'songs')">Songs</button>
                    <button class="search-tab" onclick="setSearchFilter(this, 'albums')">Albums</button>
                    <button class="search-tab" onclick="setSearchFilter(this, 'playlists')">Playlists</button>
                  </div>
                  
                  <div id="search-results" class="search-results-dropdown hidden"></div>
                </div>

                <!-- Artwork -->
                <div class="artwork-container">
                  <div id="artwork-wrapper" class="artwork-placeholder" style="width: 100%; height: 100%; display: flex; align-items: center; justify-content: center;">
                    <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>
                  </div>
                </div>
                
                <!-- Title & Artist & Share -->
                <div style="display: flex; align-items: center; justify-content: center; position: relative; margin-bottom: 12px;">
                  <div style="flex: 1; min-width: 0; padding-left: 32px; padding-right: 32px;">
                    <div class="title" id="title">Loading...</div>
                    <div class="artist" id="artist" style="margin-bottom: 0;"></div>
                  </div>
                  <button id="share-btn" class="share-btn" onclick="shareCurrentSong()" aria-label="Share">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"></path><polyline points="16 6 12 2 8 6"></polyline><line x1="12" y1="2" x2="12" y2="15"></line></svg>
                  </button>
                </div>
                
                <div class="controls">
                  <button class="control-btn prev" onclick="send('previous')" aria-label="Previous">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M6 6h2v12H6zm3.5 6l8.5 6V6z"/></svg>
                  </button>
                  <button id="play-pause-btn" class="control-btn play-pause" onclick="send('play-pause')" aria-label="Play/Pause">
                    <svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>
                  </button>
                  <button class="control-btn next" onclick="send('next')" aria-label="Next">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z"/></svg>
                  </button>
                </div>
                
                <div class="volume-container">
                  <span class="volume-icon">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M18.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM5 9v6h4l5 5V4L9 9H5z"/></svg>
                  </span>
                  <input id="volume" type="range" min="0" max="1" step="0.01" onchange="setVolume(this.value)">
                  <span class="volume-icon">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>
                  </span>
                </div>
                
                <div class="status-container" id="status" style="margin-top: 24px;"></div>
              </div>

              <!-- Queue Panel -->
              <div class="card" style="margin-top: 20px; padding: 20px 16px;">
                <div style="font-size: 16px; font-weight: 700; text-align: left; margin-bottom: 12px; display: flex; justify-content: space-between; align-items: center;">
                  <span style="display: flex; align-items: center; gap: 8px;">
                    <span>Up Next</span>
                    <button id="clear-queue-btn" onclick="clearQueue()" style="background: none; border: 1px solid rgba(255, 45, 85, 0.4); color: #ff2d55; font-size: 11px; font-weight: 600; padding: 3px 8px; border-radius: 6px; cursor: pointer; outline: none; transition: all 0.2s ease;">Clear</button>
                  </span>
                  <span id="queue-count" style="font-size: 12px; color: #8e8e93; font-weight: 500;">0 songs</span>
                </div>
                <div id="queue-list" class="queue-list">
                  <!-- Queue items dynamically loaded -->
                </div>
              </div>
            </section>

            <!-- Album / Playlist Track Detail Panel -->
            <section id="playlist-details" class="playlist-details-pane hidden">
              <div class="playlist-details-header">
                <button class="back-btn" onclick="closePlaylistDetails()">
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="19" y1="12" x2="5" y2="12"></line><polyline points="12 19 5 12 12 5"></polyline></svg>
                  <span>Back</span>
                </button>
                <div class="playlist-title" id="p-title">Playlist Details</div>
                <div class="playlist-actions">
                  <button class="playlist-act-btn play" onclick="playlistAction('play')">Play</button>
                  <button class="playlist-act-btn" onclick="playlistAction('next')">Play Next</button>
                  <button class="playlist-act-btn" onclick="playlistAction('queue')">Add Queue</button>
                </div>
              </div>
              <div id="playlist-tracks-list" class="playlist-tracks-list">
                <!-- Tracks dynamically loaded -->
              </div>
            </section>
          </main>

          <script>
            let deviceId = localStorage.getItem('kaset_device_id');
            if (!deviceId) {
              deviceId = 'device_' + Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);
              localStorage.setItem('kaset_device_id', deviceId);
            }

            const deviceName = /iPad|iPhone|iPod/.test(navigator.userAgent) ? 'iOS Device' : 
                               /Android/.test(navigator.userAgent) ? 'Android Device' : 'Web Remote';

            let activeToken = localStorage.getItem('kaset_active_token') || '';
            let checkInterval = null;
            let refreshInterval = null;
            let searchTimeout = null;
            let currentSearchFilter = 'all';
            let currentPlaylistId = '';
            let currentPlaylistTitle = '';
            let currentVideoId = '';

            function showScreen(id) {
              document.getElementById('screen-auth').classList.add('hidden');
              document.getElementById('screen-player').classList.add('hidden');
              document.getElementById(id).classList.remove('hidden');
            }

            async function startup() {
              if (activeToken) {
                const valid = await checkToken(activeToken);
                if (valid) {
                  startPlayer();
                  return;
                }
              }
              pollApproval();
            }

            async function checkToken(token) {
              try {
                const res = await fetch('/status?token=' + encodeURIComponent(token));
                return res.status === 200;
              } catch (e) {
                return false;
              }
            }

            async function pollApproval() {
              if (checkInterval) clearInterval(checkInterval);

              async function runCheck() {
                try {
                  const res = await fetch('/check?device_id=' + encodeURIComponent(deviceId) + '&device_name=' + encodeURIComponent(deviceName));
                  const data = await res.json();
                  if (data.status === 'approved') {
                    activeToken = data.token;
                    localStorage.setItem('kaset_active_token', activeToken);
                    clearInterval(checkInterval);
                    startPlayer();
                  } else if (data.status === 'pending') {
                    showScreen('screen-auth');
                    const statusDiv = document.getElementById('status-container');
                    statusDiv.innerHTML = '<div class="status-pending"><span style="width:8px; height:8px; background:#ff9500; border-radius:50%; display:inline-block; animation: pulse 1s infinite ease-in-out;"></span>Access requested. Please approve on your Mac.</div>';
                    statusDiv.classList.remove('hidden');
                    
                    const requestLink = document.getElementById('request-link');
                    requestLink.style.pointerEvents = 'none';
                    requestLink.style.opacity = '0.5';
                    requestLink.innerText = 'Request Sent (Waiting...)';
                  } else {
                    showScreen('screen-auth');
                    const statusDiv = document.getElementById('status-container');
                    statusDiv.innerHTML = '';
                    statusDiv.classList.add('hidden');
                    
                    const requestLink = document.getElementById('request-link');
                    requestLink.style.pointerEvents = 'auto';
                    requestLink.style.opacity = '1';
                    requestLink.innerText = 'Request Access from Host';
                  }
                } catch (e) {
                  showScreen('screen-auth');
                }
              }

              await runCheck();
              checkInterval = setInterval(runCheck, 2000);
            }

            async function requestAccess() {
              const pin = document.getElementById('pin-input').value;
              if (!pin) return;
              document.getElementById('auth-error').classList.add('hidden');
              try {
                const body = 'device_id=' + encodeURIComponent(deviceId) + 
                             '&device_name=' + encodeURIComponent(deviceName) + 
                             '&pin=' + encodeURIComponent(pin);
                const res = await fetch('/request_approval', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                  body: body
                });
                const data = await res.json();
                if (data.status === 'approved') {
                  activeToken = data.token;
                  localStorage.setItem('kaset_active_token', activeToken);
                  if (checkInterval) clearInterval(checkInterval);
                  startPlayer();
                } else {
                  document.getElementById('auth-error').classList.remove('hidden');
                }
              } catch (e) {
                document.getElementById('auth-error').classList.remove('hidden');
              }
            }

            async function requestHostAccess() {
              document.getElementById('auth-error').classList.add('hidden');
              try {
                const body = 'device_id=' + encodeURIComponent(deviceId) + 
                             '&device_name=' + encodeURIComponent(deviceName);
                const res = await fetch('/request_approval', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                  body: body
                });
                const data = await res.json();
                if (data.status === 'pending') {
                  pollApproval();
                }
              } catch (e) {
                // Ignore
              }
            }

            function startPlayer() {
              showScreen('screen-player');
              refresh();
              if (refreshInterval) clearInterval(refreshInterval);
              refreshInterval = setInterval(refresh, 2000);
            }

            const withToken = path => path + (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(activeToken);

            async function send(action) {
              await fetch(withToken('/' + action), { method: 'POST' });
              refresh();
            }

            async function setVolume(value) {
              await fetch(withToken('/volume?value=' + encodeURIComponent(value)), { method: 'POST' });
              refresh();
            }

            async function playQueueIndex(index) {
              await fetch(withToken('/play_index?index=' + index), { method: 'POST' });
              refresh();
            }

            async function playTrack(videoId) {
              await fetch(withToken('/play_track?videoId=' + encodeURIComponent(videoId)), { method: 'POST' });
              refresh();
            }

            async function playNext(videoId, title, artist, artworkURL) {
              const body = 'videoId=' + encodeURIComponent(videoId) +
                           '&title=' + encodeURIComponent(title) +
                           '&artist=' + encodeURIComponent(artist) +
                           '&artworkURL=' + encodeURIComponent(artworkURL);
              await fetch(withToken('/play_next'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: body
              });
              showToast('"' + title + '" will play next');
              refresh();
            }

            async function addToQueue(videoId, title, artist, artworkURL) {
              const body = 'videoId=' + encodeURIComponent(videoId) +
                           '&title=' + encodeURIComponent(title) +
                           '&artist=' + encodeURIComponent(artist) +
                           '&artworkURL=' + encodeURIComponent(artworkURL);
              await fetch(withToken('/add_to_queue'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: body
              });
              showToast('Added "' + title + '" to queue');
              refresh();
            }

            function showToast(message) {
              const toast = document.getElementById('toast');
              const toastMsg = document.getElementById('toast-message');
              toastMsg.textContent = message;
              toast.classList.add('show');
              setTimeout(() => {
                toast.classList.remove('show');
              }, 2500);
            }

            async function clearQueue() {
              if (confirm('Are you sure you want to clear the queue?')) {
                await fetch(withToken('/clear_queue'), { method: 'POST' });
                showToast('Queue cleared');
                refresh();
              }
            }

            function escapeJS(str) {
              if (!str) return '';
              return str.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/"/g, '\\"');
            }

            function shareCurrentSong() {
              if (currentVideoId) {
                const shareUrl = "https://music.youtube.com/watch?v=" + currentVideoId;
                window.open(shareUrl, '_blank');
              }
            }

            function setSearchFilter(element, filter) {
              currentSearchFilter = filter;
              document.querySelectorAll('.search-tab').forEach(tab => {
                tab.classList.remove('active');
              });
              element.classList.add('active');
              
              const query = document.getElementById('search-input').value;
              if (query && query.trim() !== '') {
                performSearch(query);
              }
            }

            async function openPlaylistDetails(id, title) {
              currentPlaylistId = id;
              currentPlaylistTitle = title;
              
              const pane = document.getElementById('playlist-details');
              const list = document.getElementById('playlist-tracks-list');
              document.getElementById('p-title').innerText = title;
              list.innerHTML = '<div style="color:#8e8e93; font-size:13px; text-align:center; padding:40px 0;">Loading tracks...</div>';
              pane.classList.remove('hidden');
              
              try {
                const res = await fetch(withToken('/playlist_tracks?id=' + encodeURIComponent(id)));
                if (res.status === 401) return;
                const data = await res.json();
                if (data.ok && data.tracks) {
                  list.innerHTML = '';
                  data.tracks.forEach(song => {
                    const item = document.createElement('div');
                    item.className = 'search-result-item';
                    const artworkUrl = song.artworkURL || 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="%23888" stroke-width="1.5"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>';
                    item.innerHTML = `
                      <img src="${artworkUrl}" alt="Artwork" onclick="playTrack('${song.videoId}')" style="cursor:pointer;">
                      <div class="search-result-info" onclick="playTrack('${song.videoId}')" style="cursor:pointer;">
                        <div class="search-result-title">${song.title}</div>
                        <div class="search-result-artist">${song.artist}</div>
                      </div>
                      <div class="result-actions">
                        <button class="result-act-btn" onclick="playNext('${song.videoId}', '${escapeJS(song.title)}', '${escapeJS(song.artist)}', '${song.artworkURL || ''}')" title="Play Next">
                          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="5 4 15 12 5 20"></polyline><line x1="19" y1="5" x2="19" y2="19"></line></svg>
                        </button>
                        <button class="result-act-btn" onclick="addToQueue('${song.videoId}', '${escapeJS(song.title)}', '${escapeJS(song.artist)}', '${song.artworkURL || ''}')" title="Add to Queue">
                          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
                        </button>
                      </div>
                    `;
                    list.appendChild(item);
                  });
                } else {
                  list.innerHTML = '<div style="color:#ff453a; font-size:13px; text-align:center; padding:40px 0;">Failed to load tracks.</div>';
                }
              } catch (e) {
                list.innerHTML = '<div style="color:#ff453a; font-size:13px; text-align:center; padding:40px 0;">Error loading tracks.</div>';
              }
            }

            function closePlaylistDetails() {
              document.getElementById('playlist-details').classList.add('hidden');
            }

            async function playlistAction(action) {
              if (!currentPlaylistId) return;
              
              let endpoint = '';
              let msg = '';
              if (action === 'play') {
                endpoint = '/play_playlist?playlistId=' + encodeURIComponent(currentPlaylistId);
                msg = 'Playing "' + currentPlaylistTitle + '"';
              } else if (action === 'next') {
                endpoint = '/play_next?playlistId=' + encodeURIComponent(currentPlaylistId);
                msg = '"' + currentPlaylistTitle + '" will play next';
              } else if (action === 'queue') {
                endpoint = '/add_to_queue?playlistId=' + encodeURIComponent(currentPlaylistId);
                msg = 'Added "' + currentPlaylistTitle + '" to queue';
              }
              
              await fetch(withToken(endpoint), { method: 'POST' });
              if (msg) showToast(msg);
              closePlaylistDetails();
              refresh();
            }

            let searchInputFocused = false;

            function handleSearchFocus(input) {
              if (!searchInputFocused) {
                setTimeout(() => input.select(), 50);
                searchInputFocused = true;
              }
            }

            function handleSearchBlur() {
              searchInputFocused = false;
            }

            function clearSearch() {
              const input = document.getElementById('search-input');
              input.value = '';
              input.focus();
              document.getElementById('clear-search-btn').style.display = 'none';
              document.getElementById('search-results').classList.add('hidden');
              if (searchTimeout) clearTimeout(searchTimeout);
            }

            function handleSearch(query) {
              const clearBtn = document.getElementById('clear-search-btn');
              if (query && query.length > 0) {
                clearBtn.style.display = 'flex';
              } else {
                clearBtn.style.display = 'none';
              }

              if (searchTimeout) clearTimeout(searchTimeout);
              if (!query || query.trim() === '') {
                document.getElementById('search-results').classList.add('hidden');
                return;
              }
              searchTimeout = setTimeout(() => performSearch(query), 400);
            }

            async function performSearch(query) {
              try {
                const res = await fetch(withToken('/search?q=' + encodeURIComponent(query) + '&filter=' + currentSearchFilter));
                if (res.status === 401) return;
                const data = await res.json();
                const resultsDiv = document.getElementById('search-results');
                resultsDiv.innerHTML = '';
                if (data.results && data.results.length > 0) {
                  data.results.forEach(song => {
                    const item = document.createElement('div');
                    item.className = 'search-result-item';
                    const artworkUrl = song.artworkURL || 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="%23888" stroke-width="1.5"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>';
                    
                    const isSong = song.type === 'song' || data.type === 'songs';
                    
                    if (isSong) {
                      item.innerHTML = `
                        <img src="${artworkUrl}" alt="Artwork" onclick="playTrack('${song.videoId}')" style="cursor:pointer;">
                        <div class="search-result-info" onclick="playTrack('${song.videoId}')" style="cursor:pointer;">
                          <div class="search-result-title">${song.title}</div>
                          <div class="search-result-artist">${song.artist}</div>
                        </div>
                        <div class="result-actions">
                          <button class="result-act-btn" onclick="playNext('${song.videoId}', '${escapeJS(song.title)}', '${escapeJS(song.artist)}', '${song.artworkURL || ''}')" title="Play Next">
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="5 4 15 12 5 20"></polyline><line x1="19" y1="5" x2="19" y2="19"></line></svg>
                          </button>
                          <button class="result-act-btn" onclick="addToQueue('${song.videoId}', '${escapeJS(song.title)}', '${escapeJS(song.artist)}', '${song.artworkURL || ''}')" title="Add to Queue">
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
                          </button>
                        </div>
                      `;
                    } else {
                      const typeLabel = song.type === 'album' ? 'Album' : 'Playlist';
                      item.innerHTML = `
                        <img src="${artworkUrl}" alt="Artwork" onclick="openPlaylistDetails('${song.id}', '${escapeJS(song.title)}')" style="cursor:pointer;">
                        <div class="search-result-info" onclick="openPlaylistDetails('${song.id}', '${escapeJS(song.title)}')" style="cursor:pointer;">
                          <div class="search-result-title">${song.title}</div>
                          <div class="search-result-artist">${song.artist || typeLabel}</div>
                        </div>
                        <div class="result-actions">
                          <button class="result-act-btn" onclick="openPlaylistDetails('${song.id}', '${escapeJS(song.title)}')" title="View Tracks">
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="8" y1="6" x2="21" y2="6"></line><line x1="8" y1="12" x2="21" y2="12"></line><line x1="8" y1="18" x2="21" y2="18"></line><line x1="3" y1="6" x2="3.01" y2="6"></line><line x1="3" y1="12" x2="3.01" y2="12"></line><line x1="3" y1="18" x2="3.01" y2="18"></line></svg>
                          </button>
                        </div>
                      `;
                    }
                    resultsDiv.appendChild(item);
                  });
                  resultsDiv.classList.remove('hidden');
                } else {
                  resultsDiv.classList.add('hidden');
                }
              } catch (e) {
                console.error(e);
              }
            }

            document.addEventListener('click', (e) => {
              const searchResults = document.getElementById('search-results');
              const searchInput = document.getElementById('search-input');
              if (searchResults && e.target !== searchResults && e.target !== searchInput && !searchResults.contains(e.target)) {
                searchResults.classList.add('hidden');
              }
            });

            async function refresh() {
              try {
                const res = await fetch(withToken('/status'));
                if (res.status === 401) {
                  localStorage.removeItem('kaset_active_token');
                  activeToken = '';
                  clearInterval(refreshInterval);
                  pollApproval();
                  return;
                }
                const data = await res.json();
                document.getElementById('title').textContent = data.track?.title || 'Nothing playing';
                document.getElementById('artist').textContent = data.track?.artist || '';
                
                if (data.track) {
                  currentVideoId = data.track.videoId || '';
                } else {
                  currentVideoId = '';
                }

                if (data.track && data.track.artworkURL) {
                  document.getElementById('artwork-wrapper').innerHTML = '<img class="artwork-image" src="' + data.track.artworkURL + '" alt="Artwork">';
                } else {
                  document.getElementById('artwork-wrapper').innerHTML = '<svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>';
                }

                const playPauseBtn = document.getElementById('play-pause-btn');
                if (data.isPlaying) {
                  playPauseBtn.innerHTML = '<svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>';
                } else {
                  playPauseBtn.innerHTML = '<svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>';
                }

                document.getElementById('status').textContent = data.state.toUpperCase() + ' • VOLUME ' + Math.round((data.volume || 0) * 100) + '%';
                document.getElementById('volume').value = data.volume || 0;

                // Render queue
                const queueList = document.getElementById('queue-list');
                const queueCount = document.getElementById('queue-count');
                if (data.queue && data.queue.length > 0) {
                  queueCount.textContent = data.queue.length + ' songs';
                  queueList.innerHTML = '';
                  data.queue.forEach((song, idx) => {
                    const isActive = idx === data.queueIndex;
                    const item = document.createElement('div');
                    item.className = 'queue-item' + (isActive ? ' active' : '');
                    const artworkUrl = song.artworkURL || 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="%23888" stroke-width="1.5"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>';
                    item.innerHTML = `
                      <img src="${artworkUrl}" alt="Artwork">
                      <div class="queue-item-info">
                        <div class="queue-item-title${isActive ? ' active' : ''}">${song.title}</div>
                        <div class="queue-item-artist">${song.artist}</div>
                      </div>
                    `;
                    item.onclick = () => playQueueIndex(idx);
                    queueList.appendChild(item);
                  });
                } else {
                  queueCount.textContent = '0 songs';
                  queueList.innerHTML = '<div style="color:#8e8e93; font-size:13px; text-align:center; padding:20px 0;">Queue is empty</div>';
                }
              } catch (error) {
                document.getElementById('title').textContent = 'Cannot reach Kaset';
                document.getElementById('artist').textContent = '';
                document.getElementById('status').textContent = String(error);
              }
            }

            startup();
          </script>
        </body>
        </html>
        """#
    }

    // swiftlint:enable function_body_length trailing_whitespace

    static func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let interface = ptr {
            defer { ptr = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)

            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            guard let addrPointer = interface.pointee.ifa_addr else {
                continue
            }

            let addr = addrPointer.pointee
            if Int32(addr.sa_family) == AF_INET {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addrPointer,
                    socklen_t(addr.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    hostname.withUnsafeBufferPointer { buffer in
                        if let baseAddress = buffer.baseAddress {
                            let ip = String(cString: baseAddress)
                            if !ip.isEmpty {
                                addresses.append(ip)
                            }
                        }
                    }
                }
            }
        }
        return addresses
    }

    static func localControlURLs() -> [URL] {
        let settings = SettingsManager.shared
        let port = settings.localControlServerPort

        var urls: [URL] = []
        if let localhostURL = URL(string: "http://127.0.0.1:\(port)/") {
            urls.append(localhostURL)
        }

        if settings.localControlServerAllowsLAN {
            // 1. System mDNS URL using the computer's local hostname
            let hostName = ProcessInfo.processInfo.hostName
            let cleanHost = hostName.hasSuffix(".local") ? hostName : "\(hostName).local"
            if let hostLocal = URL(string: "http://\(cleanHost):\(port)/") {
                urls.append(hostLocal)
            }

            // 2. Fallback raw local IP URLs
            let ips = Self.getLocalIPAddresses()
            for ip in ips {
                if let url = URL(string: "http://\(ip):\(port)/") {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func escapeJavaScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

private extension PlayerService.PlaybackState {
    var apiValue: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .buffering: "buffering"
        case .ended: "ended"
        case .error: "error"
        }
    }
}
