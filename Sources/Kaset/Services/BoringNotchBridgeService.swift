import CryptoKit
import Foundation
import Network

// MARK: - BoringNotchBridgeService

/// Exposes a compatibility API for boring.notch on localhost:26538.
@MainActor
final class BoringNotchBridgeService {
    private enum Constants {
        static let host = "127.0.0.1"
        static let port: UInt16 = 26538
        static let wsPath = "/api/v1/ws"
        static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    }

    private struct PlaybackSnapshot: Equatable {
        let isPaused: Bool
        let title: String?
        let artist: String?
        let album: String?
        let elapsedSeconds: Double?
        let songDuration: Double?
        let imageSrc: String?
        let repeatMode: Int
        let repeatModeString: String
        let isShuffled: Bool
        let volume: Double
        let videoId: String?
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct ConnectionState {
        let connection: NWConnection
        var buffer = Data()
        var isWebSocket = false
    }

    private enum HTTPHandlingOutcome {
        case noRequest
        case keepAlive
        case closeAfterSend
    }

    private let playerService: PlayerService
    private let logger = DiagnosticsLogger.network
    private let token = UUID().uuidString
    // NWListener and NWConnection require a DispatchQueue for thread safety
    private let queue = DispatchQueue(label: "com.kaset.boring-notch-bridge", qos: .userInitiated)

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var monitorTask: Task<Void, Never>?
    private var lastSnapshot: PlaybackSnapshot?

    init(playerService: PlayerService) {
        self.playerService = playerService
    }

    deinit {
        self.listener?.cancel()
        for state in self.connections.values {
            state.connection.cancel()
        }
        self.monitorTask?.cancel()
    }

    func start() {
        guard self.listener == nil else {
            self.logger.debug("boring.notch bridge start requested while already running")
            return
        }

        self.logger.info("Starting boring.notch bridge")

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Constrain listener to loopback interface to prevent unintended network exposure
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: Constants.port))
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection: connection)
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }

            listener.start(queue: self.queue)
            self.startMonitoringLoop()
            self.logger.info("boring.notch bridge listening on http://\(Constants.host):\(Constants.port)")
        } catch {
            self.logger.error("Failed to start boring.notch bridge: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        self.monitorTask?.cancel()
        self.monitorTask = nil
        self.listener?.cancel()
        self.listener = nil
        for state in self.connections.values {
            state.connection.cancel()
        }
        self.connections.removeAll()
        self.lastSnapshot = nil
        self.logger.info("boring.notch bridge stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            self.logger.info("boring.notch bridge listener is ready")

        case let .waiting(error):
            self.logger.error("boring.notch bridge listener waiting: \(error.localizedDescription, privacy: .public)")

        case let .failed(error):
            self.logger.error("boring.notch bridge listener failed: \(error.localizedDescription, privacy: .public)")
            self.listener?.cancel()
            self.listener = nil

        case .cancelled:
            self.logger.info("boring.notch bridge listener cancelled")

        default:
            break
        }
    }

    private func accept(connection: NWConnection) {
        // Defensively reject non-loopback connections to prevent unauthorized access
        // Check if remote endpoint is loopback (127.0.0.1 or ::1)
        let remoteEndpoint = connection.endpoint
        let isLoopback: Bool
        switch remoteEndpoint {
        case .hostPort(let host, _):
            // Check if host represents loopback
            let debugDesc = host.debugDescription
            isLoopback = debugDesc.contains("127.0.0.1") || debugDesc.contains("::1") || debugDesc.contains("localhost")
        case .unix:
            isLoopback = true
        case .url:
            // URL-based endpoints are generally unsafe, reject them
            isLoopback = false
        @unknown default:
            isLoopback = false
        }
        guard isLoopback else {
            self.logger.warning("Rejected non-loopback connection from \(remoteEndpoint.debugDescription, privacy: .public)")
            connection.cancel()
            return
        }

        let id = ObjectIdentifier(connection)
        self.connections[id] = ConnectionState(connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(id: id, state: state)
            }
        }

        connection.start(queue: self.queue)
        self.scheduleReceive(for: id)
    }

    private func handleConnectionState(id: ObjectIdentifier, state: NWConnection.State) {
        self.logger.debug("Connection \(String(describing: id), privacy: .public) state: \(String(describing: state), privacy: .public)")
        switch state {
        case .failed, .cancelled:
            self.connections[id] = nil
        default:
            break
        }
    }

    private func scheduleReceive(for id: ObjectIdentifier) {
        guard let state = self.connections[id] else { return }

        state.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                await self?.handleReceive(id: id, data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(id: ObjectIdentifier, data: Data?, isComplete: Bool, error: NWError?) async {
        guard var state = self.connections[id] else { return }
        var deferCloseAfterSend = false

        self.logger.debug(
            "Receive id=\(String(describing: id), privacy: .public), bytes=\(data?.count ?? 0, privacy: .public), isComplete=\(isComplete, privacy: .public), isWebSocket=\(state.isWebSocket, privacy: .public), error=\(error?.localizedDescription ?? "none", privacy: .public)"
        )

        if let data, !data.isEmpty {
            state.buffer.append(data)
        }

        if state.isWebSocket {
            self.handleWebSocketFrames(id: id, state: &state)
            // Mirror HTTP branch: only write back state if connection still exists after frame handling
            if self.connections[id] != nil {
                self.connections[id] = state
            }
        } else {
            let outcome = await self.handleHTTPRequests(id: id, state: &state)
            deferCloseAfterSend = outcome == .closeAfterSend
            if self.connections[id] != nil {
                self.connections[id] = state
            }
        }

        if error != nil || isComplete {
            if deferCloseAfterSend {
                return
            }
            self.closeConnection(id)
            return
        }

        if self.connections[id] != nil, !deferCloseAfterSend {
            self.scheduleReceive(for: id)
        }
    }

    private func closeConnection(_ id: ObjectIdentifier) {
        guard let state = self.connections[id] else { return }
        state.connection.cancel()
        self.connections[id] = nil
    }

    private func handleHTTPRequests(id: ObjectIdentifier, state: inout ConnectionState) async -> HTTPHandlingOutcome {
        guard let request = Self.parseHTTPRequest(from: &state.buffer) else { return .noRequest }
        self.logger.debug("Parsed HTTP request method=\(request.method, privacy: .public) path=\(request.path, privacy: .public)")

        switch await self.handleHTTPRequest(request, connectionID: id) {
        case let .response(data, keepAlive):
            self.sendHTTPResponse(id: id, data, closeAfterSend: !keepAlive)
            return keepAlive ? .keepAlive : .closeAfterSend

        case .upgradedToWebSocket:
            // Keep local state in sync so the assignment in handleReceive does not
            // overwrite websocket mode back to false.
            state.isWebSocket = true
            return .keepAlive
        }
    }

    private enum HTTPRequestAction {
        case response(data: Data, keepAlive: Bool)
        case upgradedToWebSocket
    }

    private func handleHTTPRequest(_ request: HTTPRequest, connectionID: ObjectIdentifier) async -> HTTPRequestAction {
        if request.method == "POST", request.path == "/auth/boringNotch" {
            return .response(data: Self.jsonResponse(status: 200, body: ["accessToken": self.token]), keepAlive: false)
        }

        guard self.isAuthorized(request.headers) else {
            return .response(data: Self.jsonResponse(status: 401, body: ["error": "Unauthorized"]), keepAlive: false)
        }

        return await self.routeAuthorizedRequest(request, connectionID: connectionID)
    }

    private func routeAuthorizedRequest(_ request: HTTPRequest, connectionID: ObjectIdentifier) async -> HTTPRequestAction {
        let method = request.method
        let path = request.path

        if method == "GET" { return await self.handleGETRequest(path, headers: request.headers, connectionID: connectionID) }
        if method == "POST" { return await self.handlePOSTRequest(path, body: request.body, connectionID: connectionID) }
        return .response(data: Self.plainResponse(status: 404, body: "Not Found"), keepAlive: false)
    }

    private func handleGETRequest(_ path: String, headers: [String: String], connectionID: ObjectIdentifier) async -> HTTPRequestAction {
        switch path {
        case "/api/v1/song":
            return .response(data: Self.songResponse(snapshot: self.currentSnapshot()), keepAlive: false)
        case "/api/v1/like-state":
            return await self.handleLikeStateRequest()
        case "/api/v1/shuffle":
            return .response(data: Self.jsonResponse(status: 200, body: ["state": self.playerService.shuffleEnabled]), keepAlive: false)
        case "/api/v1/repeat-mode":
            return .response(data: Self.jsonResponse(status: 200, body: ["mode": self.repeatModeString()]), keepAlive: false)
        case Constants.wsPath:
            return await self.handleWebSocketUpgrade(headers, connectionID: connectionID)
        default:
            return .response(data: Self.plainResponse(status: 404, body: "Not Found"), keepAlive: false)
        }
    }

    private func handlePOSTRequest(_ path: String, body: Data, connectionID: ObjectIdentifier) async -> HTTPRequestAction {
        switch path {
        case "/api/v1/play":
            return await self.handlePlaybackAction { await self.playerService.resume() }
        case "/api/v1/pause":
            return await self.handlePlaybackAction { await self.playerService.pause() }
        case "/api/v1/toggle-play":
            return await self.handlePlaybackAction { await self.playerService.playPause() }
        case "/api/v1/next":
            return await self.handlePlaybackAction { await self.playerService.next() }
        case "/api/v1/previous":
            return await self.handlePlaybackAction { await self.playerService.previous() }
        case "/api/v1/seek-to":
            return await self.handleSeekRequest(body)
        case "/api/v1/volume":
            return await self.handleVolumeRequest(body)
        case "/api/v1/shuffle":
            return await self.handleShuffleToggle()
        case "/api/v1/switch-repeat":
            return await self.handleRepeatToggle()
        case "/api/v1/like":
            return await self.handleLikeTrack()
        case "/api/v1/dislike":
            return await self.handleDislikeTrack()
        case Constants.wsPath:
            return await self.handleWebSocketUpgradeRequest(body, connectionID: connectionID)
        default:
            return .response(data: Self.plainResponse(status: 404, body: "Not Found"), keepAlive: false)
        }
    }

    private func handleLikeStateRequest() async -> HTTPRequestAction {
        let state: String? = switch self.playerService.currentTrackLikeStatus {
        case .like:
            "LIKE"
        case .dislike:
            "DISLIKE"
        case .indifferent:
            nil
        }
        return .response(data: Self.jsonResponse(status: 200, body: ["state": state ?? NSNull()]), keepAlive: false)
    }

    private func handlePlaybackAction(_ action: @escaping () async -> Void) async -> HTTPRequestAction {
        await action()
        await self.pushImmediateUpdates()
        return .response(data: Self.emptyResponse(), keepAlive: false)
    }

    private func handleSeekRequest(_ body: Data) async -> HTTPRequestAction {
        if let value = Self.jsonBodyValue(body, key: "seconds") {
            await self.playerService.seek(to: max(0, value))
            await self.pushImmediateUpdates(positionOnly: true)
        }
        return .response(data: Self.emptyResponse(), keepAlive: false)
    }

    private func handleVolumeRequest(_ body: Data) async -> HTTPRequestAction {
        if let value = Self.jsonBodyValue(body, key: "volume") {
            let clamped = max(0, min(100, value))
            await self.playerService.setVolume(clamped / 100)
            await self.pushImmediateUpdates()
        }
        return .response(data: Self.emptyResponse(), keepAlive: false)
    }

    private func handleShuffleToggle() async -> HTTPRequestAction {
        self.playerService.toggleShuffle()
        await self.pushImmediateUpdates()
        return .response(data: Self.jsonResponse(status: 200, body: ["state": self.playerService.shuffleEnabled]), keepAlive: false)
    }

    private func handleRepeatToggle() async -> HTTPRequestAction {
        self.playerService.cycleRepeatMode()
        await self.pushImmediateUpdates()
        return .response(data: Self.emptyResponse(), keepAlive: false)
    }

    private func handleLikeTrack() async -> HTTPRequestAction {
        self.playerService.likeCurrentTrack()
        await self.pushImmediateUpdates()
        return .response(data: Self.emptyResponse(), keepAlive: false)
    }

    private func handleDislikeTrack() async -> HTTPRequestAction {
        self.playerService.dislikeCurrentTrack()
        await self.pushImmediateUpdates()
        return .response(data: Self.emptyResponse(), keepAlive: false)
    }

    private func handleWebSocketUpgradeRequest(_ body: Data, connectionID: ObjectIdentifier) async -> HTTPRequestAction {
        .response(data: Self.plainResponse(status: 400, body: "Bad WebSocket request"), keepAlive: false)
    }

    private func handleWebSocketUpgrade(_ headers: [String: String], connectionID: ObjectIdentifier) async -> HTTPRequestAction {
        guard Self.isWebSocketUpgrade(headers),
              let secWebSocketKey = headers["sec-websocket-key"]
        else {
            return .response(data: Self.plainResponse(status: 400, body: "Bad WebSocket request"), keepAlive: false)
        }

        let response = Self.webSocketHandshakeResponse(secWebSocketKey: secWebSocketKey)
        self.sendHTTPResponse(id: connectionID, response)
        self.sendPlayerInfo(to: connectionID, type: "PLAYER_INFO")
        return .upgradedToWebSocket
    }

    private func isAuthorized(_ headers: [String: String]) -> Bool {
        guard let authorization = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authorization.isEmpty
        else {
            return false
        }

        return authorization == self.token || authorization == "Bearer \(self.token)"
    }

    private func sendHTTPResponse(id: ObjectIdentifier, _ payload: Data, closeAfterSend: Bool = false) {
        guard let state = self.connections[id] else { return }
        self.logger.debug("Sending HTTP response id=\(String(describing: id), privacy: .public), bytes=\(payload.count, privacy: .public), closeAfterSend=\(closeAfterSend, privacy: .public)")
        state.connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.logger.error("HTTP send failed: \(error.localizedDescription, privacy: .public)")
                    self?.closeConnection(id)
                    return
                }

                self?.logger.debug("HTTP response send completed id=\(String(describing: id), privacy: .public)")

                if closeAfterSend {
                    self?.closeConnection(id)
                }
            }
        })
    }

    private func handleWebSocketFrames(id: ObjectIdentifier, state: inout ConnectionState) {
        while let frame = Self.parseWebSocketFrame(from: &state.buffer) {
            switch frame.opcode {
            case 0x8:
                self.sendWebSocketFrame(to: id, opcode: 0x8, payload: Data())
                self.closeConnection(id)
                return
            case 0x9:
                self.sendWebSocketFrame(to: id, opcode: 0xA, payload: frame.payload)
            default:
                continue
            }
        }
    }

    private func sendWebSocketFrame(to id: ObjectIdentifier, opcode: UInt8, payload: Data) {
        guard let state = self.connections[id], state.isWebSocket else { return }

        var frame = Data()
        frame.append(0x80 | opcode)

        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }

        frame.append(payload)

        state.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.logger.error("WebSocket send failed: \(error.localizedDescription, privacy: .public)")
                    self?.closeConnection(id)
                }
            }
        })
    }

    private func sendWebSocketJSON(to id: ObjectIdentifier, body: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: []),
              let textData = String(data: data, encoding: .utf8)?.data(using: .utf8)
        else {
            return
        }

        self.sendWebSocketFrame(to: id, opcode: 0x1, payload: textData)
    }

    private func broadcastWebSocketJSON(_ body: [String: Any]) {
        let wsIDs = self.connections.filter(\.value.isWebSocket).map(\.key)
        for id in wsIDs {
            self.sendWebSocketJSON(to: id, body: body)
        }
    }

    private func startMonitoringLoop() {
        self.monitorTask?.cancel()
        self.monitorTask = Task {
            while !Task.isCancelled {
                await self.pushImmediateUpdates()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pushImmediateUpdates(positionOnly: Bool = false) async {
        guard self.connections.contains(where: \.value.isWebSocket) else { return }

        let snapshot = self.currentSnapshot()
        let previous = self.lastSnapshot
        self.lastSnapshot = snapshot

        if positionOnly {
            if let elapsedSeconds = snapshot.elapsedSeconds {
                self.broadcastWebSocketJSON([
                    "type": "POSITION_CHANGED",
                    "position": elapsedSeconds,
                    "elapsedSeconds": elapsedSeconds,
                ])
            }
            return
        }

        if previous == nil {
            self.broadcastWebSocketJSON(self.playerInfoPayload(type: "PLAYER_INFO", snapshot: snapshot))
        }

        if previous?.videoId != snapshot.videoId {
            self.broadcastWebSocketJSON(self.playerInfoPayload(type: "VIDEO_CHANGED", snapshot: snapshot))
            // Some clients only refresh now-playing metadata on PLAYER_INFO.
            self.broadcastWebSocketJSON(self.playerInfoPayload(type: "PLAYER_INFO", snapshot: snapshot))
        }

        if previous?.isPaused != snapshot.isPaused {
            self.broadcastWebSocketJSON(self.playerInfoPayload(type: "PLAYER_STATE_CHANGED", snapshot: snapshot))
        }

        if previous?.title != snapshot.title || previous?.artist != snapshot.artist || previous?.album != snapshot.album {
            self.broadcastWebSocketJSON(self.playerInfoPayload(type: "PLAYER_INFO", snapshot: snapshot))
        }

        if let elapsedSeconds = snapshot.elapsedSeconds {
            self.broadcastWebSocketJSON([
                "type": "POSITION_CHANGED",
                "position": elapsedSeconds,
                "elapsedSeconds": elapsedSeconds,
            ])
        }

        if previous?.volume != snapshot.volume {
            self.broadcastWebSocketJSON([
                "type": "VOLUME_CHANGED",
                "volume": snapshot.volume,
            ])
        }

        if previous?.repeatModeString != snapshot.repeatModeString {
            self.broadcastWebSocketJSON([
                "type": "REPEAT_CHANGED",
                "repeat": snapshot.repeatModeString,
            ])
        }

        if previous?.isShuffled != snapshot.isShuffled {
            self.broadcastWebSocketJSON([
                "type": "SHUFFLE_CHANGED",
                "shuffle": snapshot.isShuffled,
                "isShuffled": snapshot.isShuffled,
            ])
        }
    }

    private func sendPlayerInfo(to id: ObjectIdentifier, type: String) {
        let snapshot = self.currentSnapshot()
        self.sendWebSocketJSON(to: id, body: self.playerInfoPayload(type: type, snapshot: snapshot))
    }

    private func playerInfoPayload(type: String, snapshot: PlaybackSnapshot) -> [String: Any] {
        let snapshotDict = Self.snapshotAsPlaybackDictionary(snapshot)
        var payload: [String: Any] = ["type": type]
        payload.merge(snapshotDict) { _, new in new }
        payload["song"] = payload.filter { $0.key != "type" }
        return payload
    }

    /// Shared snapshot-to-dictionary conversion for consistent JSON serialization across endpoints
    private static func snapshotAsPlaybackDictionary(_ snapshot: PlaybackSnapshot) -> [String: Any] {
        var dict: [String: Any] = [
            "isPaused": snapshot.isPaused,
            "repeatMode": snapshot.repeatMode,
            "isShuffled": snapshot.isShuffled,
            "volume": snapshot.volume,
        ]

        if let title = snapshot.title {
            dict["title"] = title
        }
        if let artist = snapshot.artist {
            dict["artist"] = artist
        }
        if let album = snapshot.album {
            dict["album"] = album
        }
        if let elapsedSeconds = snapshot.elapsedSeconds {
            dict["elapsedSeconds"] = elapsedSeconds
        }
        if let songDuration = snapshot.songDuration {
            dict["songDuration"] = songDuration
        }
        if let imageSrc = snapshot.imageSrc {
            dict["imageSrc"] = imageSrc
        }
        if let videoId = snapshot.videoId {
            dict["videoId"] = videoId
        }
        return dict
    }

    private func currentSnapshot() -> PlaybackSnapshot {
        let track = self.playerService.currentTrack
        let artistDisplay = track?.artistsDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist: String? = if let artistDisplay, !artistDisplay.isEmpty {
            artistDisplay
        } else {
            nil
        }

        let imageSrc = track?.thumbnailURL?.absoluteString ?? track?.fallbackThumbnailURL?.absoluteString
        let elapsedSeconds = self.playerService.progress.isFinite ? self.playerService.progress : nil
        let duration = self.playerService.duration > 0 ? self.playerService.duration : nil

        return PlaybackSnapshot(
            isPaused: !self.playerService.isPlaying,
            title: track?.title,
            artist: artist,
            album: track?.album?.title,
            elapsedSeconds: elapsedSeconds,
            songDuration: duration,
            imageSrc: imageSrc,
            repeatMode: self.repeatModeValue(),
            repeatModeString: self.repeatModeString(),
            isShuffled: self.playerService.shuffleEnabled,
            volume: max(0, min(100, self.playerService.volume * 100)),
            videoId: track?.videoId ?? self.playerService.pendingPlayVideoId
        )
    }

    private func repeatModeValue() -> Int {
        switch self.playerService.repeatMode {
        case .off:
            0
        case .all:
            1
        case .one:
            2
        }
    }

    private func repeatModeString() -> String {
        switch self.playerService.repeatMode {
        case .off:
            "NONE"
        case .all:
            "ALL"
        case .one:
            "ONE"
        }
    }
}

private extension BoringNotchBridgeService {
    private static func parseHTTPRequest(from buffer: inout Data) -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: delimiter) else { return nil }

        let headerEnd = headerRange.upperBound
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            buffer.removeAll(keepingCapacity: true)
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex].lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let totalLength = headerEnd + contentLength
        guard buffer.count >= totalLength else { return nil }

        let body = buffer[headerEnd ..< totalLength]
        buffer.removeSubrange(0 ..< totalLength)

        return HTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: String(requestParts[1]),
            headers: headers,
            body: Data(body)
        )
    }

    private static func isWebSocketUpgrade(_ headers: [String: String]) -> Bool {
        let upgrade = headers["upgrade"]?.lowercased() == "websocket"
        let connection = headers["connection"]?.lowercased().contains("upgrade") == true
        return upgrade && connection
    }

    private static func webSocketHandshakeResponse(secWebSocketKey: String) -> Data {
        let accept = Data(Insecure.SHA1.hash(data: Data("\(secWebSocketKey)\(Constants.wsGUID)".utf8))).base64EncodedString()
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "\r\n",
        ].joined(separator: "\r\n")
        return Data(response.utf8)
    }

    private static func parseWebSocketFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }

        let byte1 = buffer[0]
        let byte2 = buffer[1]
        let opcode = byte1 & 0x0F
        let masked = (byte2 & 0x80) != 0

        var index = 2
        var payloadLength = Int(byte2 & 0x7F)

        if payloadLength == 126 {
            guard buffer.count >= index + 2 else { return nil }
            payloadLength = Int(buffer[index]) << 8 | Int(buffer[index + 1])
            index += 2
        } else if payloadLength == 127 {
            guard buffer.count >= index + 8 else { return nil }
            var value: UInt64 = 0
            for offset in 0 ..< 8 {
                value = (value << 8) | UInt64(buffer[index + offset])
            }
            guard value <= UInt64(Int.max) else { return nil }
            payloadLength = Int(value)
            index += 8
        }

        var maskKey = Data()
        if masked {
            guard buffer.count >= index + 4 else { return nil }
            maskKey = buffer[index ..< (index + 4)]
            index += 4
        }

        guard buffer.count >= index + payloadLength else { return nil }

        var payload = Data(buffer[index ..< (index + payloadLength)])
        if masked {
            for i in payload.indices {
                payload[i] ^= maskKey[maskKey.startIndex + i % 4]
            }
        }

        buffer.removeSubrange(0 ..< (index + payloadLength))
        return (opcode, payload)
    }

    private static func jsonBodyValue(_ data: Data, key: String) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            return nil
        }

        if let value = dict[key] as? Double {
            return value
        }
        if let value = dict[key] as? Int {
            return Double(value)
        }
        if let value = dict[key] as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func songResponse(snapshot: PlaybackSnapshot) -> Data {
        let body = snapshotAsPlaybackDictionary(snapshot)
        return Self.jsonResponse(status: 200, body: body)
    }

    private static func emptyResponse() -> Data {
        let response = [
            "HTTP/1.1 200 OK",
            "Content-Length: 0",
            "Connection: close",
            "\r\n",
        ].joined(separator: "\r\n")
        return Data(response.utf8)
    }

    private static func plainResponse(status: Int, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let response = [
            "HTTP/1.1 \(status) \(Self.statusText(status))",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "\r\n",
        ].joined(separator: "\r\n")

        var data = Data(response.utf8)
        data.append(bodyData)
        return data
    }

    private static func jsonResponse(status: Int, body: [String: Any]) -> Data {
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
        let response = [
            "HTTP/1.1 \(status) \(Self.statusText(status))",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "\r\n",
        ].joined(separator: "\r\n")

        var data = Data(response.utf8)
        data.append(bodyData)
        return data
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 101:
            "Switching Protocols"
        case 200:
            "OK"
        case 400:
            "Bad Request"
        case 401:
            "Unauthorized"
        case 404:
            "Not Found"
        default:
            "Status"
        }
    }
}
