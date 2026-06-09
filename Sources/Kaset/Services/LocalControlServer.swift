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
            listener.service = nil
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
        if routed != .check, routed != .requestApproval {
            if SettingsManager.shared.localControlServerAllowsLAN, !Self.isAuthorized(request) {
                return .unauthorized(message: "Missing or invalid token")
            }
        }

        switch routed {
        case .webInterface:
            return .html(Self.remoteControlHTML(token: request.queryItems["token"] ?? ""))
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
            
            if RemoteDeviceManager.shared.requestApproval(deviceId: deviceId, deviceName: deviceName, pin: pin) {
                return .json(["status": "pending"])
            } else {
                return .json(["status": "invalid_pin"])
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
        let globalToken = SettingsManager.shared.localControlServerToken
        let requestToken: String
        if let token = request.queryItems["token"] ?? request.formItems["token"] {
            requestToken = token
        } else if let auth = request.headers["authorization"], auth.hasPrefix("Bearer ") {
            requestToken = String(auth.dropFirst(7))
        } else {
            return false
        }

        if !globalToken.isEmpty, requestToken == globalToken {
            return true
        }

        return RemoteDeviceManager.shared.approvedDevices.contains(where: { $0.token == requestToken })
    }

    static func remoteControlHTML(token: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Kaset Remote</title>
          <style>
            body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #111; color: #f6f6f6; }
            main { max-width: 520px; margin: 0 auto; padding: 24px; }
            h1 { font-size: 28px; margin: 0 0 16px; }
            .track { min-height: 120px; padding: 18px; border: 1px solid #333; border-radius: 12px; background: #1c1c1f; }
            .title { font-size: 22px; font-weight: 700; margin-bottom: 6px; }
            .artist { color: #bbb; }
            .controls { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-top: 18px; }
            button { min-height: 58px; border: 0; border-radius: 12px; background: #f6f6f6; color: #111; font-size: 18px; font-weight: 700; }
            button:active { transform: scale(0.98); }
            input { width: 100%; margin-top: 22px; }
            .status { color: #999; margin-top: 14px; font-size: 14px; }
          </style>
        </head>
        <body>
          <main>
            <h1>Kaset Remote</h1>
            <section class="track">
              <div class="title" id="title">Loading...</div>
              <div class="artist" id="artist"></div>
              <div class="status" id="status"></div>
            </section>
            <section class="controls">
              <button onclick="send('previous')">Previous</button>
              <button onclick="send('play-pause')">Play/Pause</button>
              <button onclick="send('next')">Next</button>
            </section>
            <input id="volume" type="range" min="0" max="1" step="0.01" onchange="setVolume(this.value)">
            <div class="status">Keep this page open on your phone or another device on the same Wi-Fi.</div>
          </main>
          <script>
            const token = new URLSearchParams(location.search).get('token') || '\(Self.escapeJavaScriptString(token))';
            const withToken = path => path + (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(token);
            async function send(action) {
              await fetch(withToken('/' + action), { method: 'POST' });
              refresh();
            }
            async function setVolume(value) {
              await fetch(withToken('/volume?value=' + encodeURIComponent(value)), { method: 'POST' });
              refresh();
            }
            async function refresh() {
              try {
                const res = await fetch(withToken('/status'));
                const data = await res.json();
                document.getElementById('title').textContent = data.track?.title || 'Nothing playing';
                document.getElementById('artist').textContent = data.track?.artist || '';
                document.getElementById('status').textContent = data.state + ' • volume ' + Math.round((data.volume || 0) * 100) + '%';
                document.getElementById('volume').value = data.volume || 0;
              } catch (error) {
                document.getElementById('title').textContent = 'Cannot reach Kaset';
                document.getElementById('status').textContent = String(error);
              }
            }
            refresh();
            setInterval(refresh, 2000);
          </script>
        </body>
        </html>
        """
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
        let token = settings.localControlServerToken

        var urls: [URL] = []
        if let localhostURL = URL(string: "http://127.0.0.1:\(port)/?token=\(token)") {
            urls.append(localhostURL)
        }

        if settings.localControlServerAllowsLAN {
            let ips = Self.getLocalIPAddresses()
            for ip in ips {
                if let url = URL(string: "http://\(ip):\(port)/?token=\(token)") {
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
