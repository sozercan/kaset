import Foundation
import Darwin
@preconcurrency import Network

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

        let port = UInt16(min(max(settings.localControlServerPort, 1024), 65_535))
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

    private func handleConnection(_ connection: NWConnection, playerService: PlayerService) {
        guard SettingsManager.shared.localControlServerAllowsLAN || self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }

        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak playerService] data, _, _, _ in
            Task { @MainActor in
                guard let self, let playerService else {
                    connection.cancel()
                    return
                }

                let response: HTTPResponse
                if let data, let request = HTTPRequest(data: data) {
                    response = await self.response(for: request, playerService: playerService)
                } else {
                    response = .badRequest(message: "Invalid HTTP request")
                }

                connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            guard let loopbackAddress = IPv4Address("127.0.0.1") else { return false }
            return address == loopbackAddress
        case .ipv6(let address):
            guard let loopbackAddress = IPv6Address("::1") else { return false }
            return address == loopbackAddress
        case .name(let name, _):
            return name == "localhost"
        default:
            return false
        }
    }

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
        case .volume(let value):
            await playerService.setVolume(value)
            return .json(["ok": true, "action": "volume", "volume": playerService.volume])
        case .search:
            let query = request.queryItems["q"] ?? request.queryItems["query"] ?? ""
            guard !query.isEmpty else {
                return .json(["results": []])
            }
            guard let client = playerService.ytMusicClient else {
                return .json(["ok": false, "error": "API client not initialized"])
            }
            do {
                let songs = try await client.searchSongs(query: query)
                let results = songs.map { Self.trackPayload($0) }
                return .json(["results": results])
            } catch {
                return .json(["ok": false, "error": error.localizedDescription])
            }
        case .playQueueIndex(let index):
            guard index >= 0 && index < playerService.queue.count else {
                return .json(["ok": false, "error": "Index out of bounds"])
            }
            let queue = playerService.queue
            await playerService.playQueue(queue, startingAt: index)
            return .json(["ok": true, "action": "playQueueIndex", "index": index])
        case .playTrack(let videoId):
            await playerService.play(videoId: videoId)
            return .json(["ok": true, "action": "playTrack", "videoId": videoId])
        case .notFound:
            return .notFound(message: "Unknown endpoint")
        case .methodNotAllowed:
            return .methodNotAllowed(message: "Unsupported method")
        case .badRequest(let message):
            return .badRequest(message: message)
        }
    }

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
            Self.volumeRoute(request)
        case ("GET", "/search"):
            .search
        case ("POST", "/play_index"):
            Self.playIndexRoute(request)
        case ("POST", "/play_track"):
            Self.playTrackRoute(request)
        case ("GET", _), ("POST", _):
            .notFound
        default:
            .methodNotAllowed
        }
    }

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
                result[key] = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
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

            /* Search elements */
            .search-results-dropdown {
              position: absolute;
              top: 50px;
              left: 0;
              right: 0;
              background: rgba(28, 28, 30, 0.95);
              border: 1px solid rgba(255, 255, 255, 0.12);
              border-radius: 14px;
              z-index: 100;
              max-height: 280px;
              overflow-y: auto;
              box-shadow: 0 10px 25px rgba(0, 0, 0, 0.6);
              backdrop-filter: blur(15px);
              -webkit-backdrop-filter: blur(15px);
            }
            .search-result-item {
              padding: 12px 16px;
              display: flex;
              align-items: center;
              gap: 12px;
              cursor: pointer;
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
                <!-- Search Bar -->
                <div style="position: relative; margin-bottom: 20px;">
                  <input id="search-input" type="text" placeholder="Search songs..." oninput="handleSearch(this.value)" style="font-size: 15px; padding: 12px 16px; letter-spacing: 0; text-align: left; margin-bottom: 0; border-radius: 12px;">
                  <div id="search-results" class="search-results-dropdown hidden"></div>
                </div>

                <!-- Artwork -->
                <div class="artwork-container">
                  <div id="artwork-wrapper" class="artwork-placeholder" style="width: 100%; height: 100%; display: flex; align-items: center; justify-content: center;">
                    <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>
                  </div>
                </div>
                <div class="title" id="title">Loading...</div>
                <div class="artist" id="artist"></div>
                
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
                  <span>Up Next</span>
                  <span id="queue-count" style="font-size: 12px; color: #8e8e93; font-weight: 500;">0 songs</span>
                </div>
                <div id="queue-list" class="queue-list">
                  <!-- Queue items dynamically loaded -->
                </div>
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

            function handleSearch(query) {
              if (searchTimeout) clearTimeout(searchTimeout);
              if (!query || query.trim() === '') {
                document.getElementById('search-results').classList.add('hidden');
                return;
              }
              searchTimeout = setTimeout(() => performSearch(query), 400);
            }

            async function performSearch(query) {
              try {
                const res = await fetch(withToken('/search?q=' + encodeURIComponent(query)));
                if (res.status === 401) return;
                const data = await res.json();
                const resultsDiv = document.getElementById('search-results');
                resultsDiv.innerHTML = '';
                if (data.results && data.results.length > 0) {
                  data.results.forEach(song => {
                    const item = document.createElement('div');
                    item.className = 'search-result-item';
                    const artworkUrl = song.artworkURL || 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="%23888" stroke-width="1.5"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>';
                    item.innerHTML = `
                      <img src="${artworkUrl}" alt="Artwork">
                      <div class="search-result-info">
                        <div class="search-result-title">${song.title}</div>
                        <div class="search-result-artist">${song.artist}</div>
                      </div>
                    `;
                    item.onclick = () => {
                      playTrack(song.videoId);
                      resultsDiv.classList.add('hidden');
                      document.getElementById('search-input').value = '';
                    };
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
              if (searchResults && e.target !== searchResults && e.target !== searchInput) {
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
