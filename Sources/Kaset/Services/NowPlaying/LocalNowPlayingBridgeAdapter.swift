import AppKit
import CryptoKit
import Foundation
import Network

// MARK: - LocalNowPlayingBridgeApprovalGate

@MainActor
final class LocalNowPlayingBridgeApprovalGate {
    private let approvalPrompt: @MainActor () async -> Bool
    private var isApproved = false

    init(approvalPrompt: @escaping @MainActor () async -> Bool = LocalNowPlayingBridgeApprovalGate.showApprovalPrompt) {
        self.approvalPrompt = approvalPrompt
    }

    func approveIfNeeded() async -> Bool {
        guard !self.isApproved else { return true }
        guard await self.approvalPrompt() else { return false }
        self.isApproved = true
        return true
    }

    func reset() {
        self.isApproved = false
    }

    private static func showApprovalPrompt() async -> Bool {
        guard !UITestConfig.isRunningUnitTests else { return false }

        let alert = NSAlert()
        alert.messageText = "Allow Boring Notch to Control Kaset?"
        alert.informativeText = "Kaset received a local bridge request for playback access. Only approve this if you just enabled or opened Boring Notch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - LocalNowPlayingBridgeAdapter

@MainActor
final class LocalNowPlayingBridgeAdapter: NowPlayingSurfaceAdapter {
    private enum Constants {
        static let port: UInt16 = 26538
        static let wsPath = "/api/v1/ws"
        static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        static let maxHTTPBodyBytes = 1_048_576
        static let maxWebSocketPayloadBytes = 65536
    }

    let descriptor = NowPlayingSurfaceDescriptor.boringNotchBridge

    struct HTTPRequest {
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

    private enum HTTPRequestAction {
        case response(data: Data, keepAlive: Bool)
        case upgradedToWebSocket
    }

    enum HTTPParseResult {
        case incomplete
        case invalid
        case request(HTTPRequest)
    }

    enum WebSocketParseResult {
        case incomplete
        case invalid
        case frame(WebSocketFrame)
    }

    private let logger = DiagnosticsLogger.network
    private let token = UUID().uuidString
    // Network.framework's NWListener/NWConnection require a DispatchQueue; there is no async/await alternative.
    private let queue = DispatchQueue(label: "com.kaset.now-playing-bridge", qos: .userInitiated)
    private let approvalGate: LocalNowPlayingBridgeApprovalGate

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var monitorTask: Task<Void, Never>?
    private var context: NowPlayingSurfaceContext?
    private var lastSnapshot: NowPlayingSnapshot?

    var isRunning: Bool {
        self.listener != nil
    }

    init(approvalGate: LocalNowPlayingBridgeApprovalGate = LocalNowPlayingBridgeApprovalGate()) {
        self.approvalGate = approvalGate
    }

    func start(context: NowPlayingSurfaceContext) async -> Bool {
        self.context = context
        guard self.listener == nil else {
            self.logger.debug("Local now-playing bridge start requested while already running")
            return true
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Bind to the loopback interface so the port is never exposed on
            // external interfaces; this covers both 127.0.0.1 and ::1.
            parameters.requiredInterfaceType = .loopback
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
            self.logger.info("Local now-playing bridge listening on port \(Constants.port, privacy: .public)")
            return true
        } catch {
            self.logger.error("Failed to start local now-playing bridge: \(error.localizedDescription, privacy: .public)")
            self.listener = nil
            return false
        }
    }

    func stop() async {
        self.monitorTask?.cancel()
        self.monitorTask = nil
        self.listener?.cancel()
        self.listener = nil
        for state in self.connections.values {
            state.connection.cancel()
        }
        self.connections.removeAll()
        self.context = nil
        self.lastSnapshot = nil
        self.approvalGate.reset()
        self.logger.info("Local now-playing bridge stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            self.logger.info("Local now-playing bridge listener is ready")
        case let .waiting(error):
            self.logger.error("Local now-playing bridge listener waiting: \(error.localizedDescription, privacy: .public)")
        case let .failed(error):
            self.logger.error("Local now-playing bridge listener failed: \(error.localizedDescription, privacy: .public)")
            self.listener?.cancel()
            self.listener = nil
        case .cancelled:
            self.logger.info("Local now-playing bridge listener cancelled")
        default:
            break
        }
    }

    private func accept(connection: NWConnection) {
        guard Self.isLoopbackEndpoint(connection.endpoint) else {
            self.logger.warning("Rejected non-loopback now-playing bridge connection")
            connection.cancel()
            return
        }

        let id = ObjectIdentifier(connection)
        self.connections[id] = ConnectionState(connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed = state {
                    self?.connections[id] = nil
                } else if case .cancelled = state {
                    self?.connections[id] = nil
                }
            }
        }

        connection.start(queue: self.queue)
        self.scheduleReceive(for: id)
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
        if let data, !data.isEmpty {
            state.buffer.append(data)
        }

        if state.isWebSocket {
            guard self.handleWebSocketFrames(id: id, state: &state) else {
                self.closeConnection(id)
                return
            }
            self.connections[id] = state
        } else {
            let parseResult = Self.parseHTTPRequestResult(from: &state.buffer)
            guard case let .request(request) = parseResult else {
                if case .invalid = parseResult {
                    self.sendHTTPResponse(id: id, Self.plainResponse(status: 400, body: "Bad Request"), closeAfterSend: true)
                    return
                }

                self.connections[id] = state
                if error != nil || isComplete {
                    self.closeConnection(id)
                    return
                }
                self.scheduleReceive(for: id)
                return
            }

            switch await self.handleHTTPRequest(request, connectionID: id) {
            case let .response(data, keepAlive):
                self.sendHTTPResponse(id: id, data, closeAfterSend: !keepAlive)
                self.connections[id] = state
                if !keepAlive {
                    return
                }
            case .upgradedToWebSocket:
                state.isWebSocket = true
                self.connections[id] = state
                self.sendPlayerInfo(to: id, type: "PLAYER_INFO")
            }
        }

        if error != nil || isComplete {
            self.closeConnection(id)
            return
        }

        if self.connections[id] != nil {
            self.scheduleReceive(for: id)
        }
    }

    private func handleHTTPRequest(_ request: HTTPRequest, connectionID: ObjectIdentifier) async -> HTTPRequestAction {
        guard Self.isAllowedHostHeader(request.headers["host"]) else {
            return .response(data: Self.jsonResponse(status: 403, body: ["error": "Forbidden host"]), keepAlive: false)
        }

        guard Self.isAllowedOriginHeader(request.headers["origin"]) else {
            return .response(data: Self.jsonResponse(status: 403, body: ["error": "Forbidden origin"]), keepAlive: false)
        }

        if request.method == "POST", request.path == "/auth/boringNotch" {
            guard await self.approvalGate.approveIfNeeded() else {
                return .response(data: Self.jsonResponse(status: 403, body: ["error": "Bridge approval denied"]), keepAlive: false)
            }
            return .response(data: Self.jsonResponse(status: 200, body: ["accessToken": self.token]), keepAlive: false)
        }

        guard self.isAuthorized(request.headers) else {
            return .response(data: Self.jsonResponse(status: 401, body: ["error": "Unauthorized"]), keepAlive: false)
        }

        guard let context else {
            return .response(data: Self.jsonResponse(status: 503, body: ["error": "Bridge unavailable"]), keepAlive: false)
        }

        context.snapshots.refresh()
        let snapshot = context.snapshots.snapshot

        switch (request.method, request.path) {
        case ("GET", "/api/v1/song"):
            return .response(data: Self.jsonResponse(status: 200, body: BoringNotchCodec.songPayload(snapshot: snapshot)), keepAlive: false)
        case ("GET", "/api/v1/like-state"):
            return .response(data: Self.jsonResponse(status: 200, body: BoringNotchCodec.likeStatePayload(snapshot: snapshot)), keepAlive: false)
        case ("GET", "/api/v1/shuffle"):
            return .response(data: Self.jsonResponse(status: 200, body: ["state": snapshot.shuffleEnabled]), keepAlive: false)
        case ("GET", "/api/v1/repeat-mode"):
            return .response(data: Self.jsonResponse(status: 200, body: ["mode": BoringNotchCodec.repeatModeString(snapshot.repeatMode)]), keepAlive: false)
        case ("GET", Constants.wsPath):
            guard Self.isWebSocketUpgrade(request.headers),
                  let key = request.headers["sec-websocket-key"]
            else {
                return .response(data: Self.plainResponse(status: 400, body: "Bad WebSocket request"), keepAlive: false)
            }
            self.sendHTTPResponse(id: connectionID, Self.webSocketHandshakeResponse(secWebSocketKey: key))
            return .upgradedToWebSocket
        default:
            if let command = BoringNotchCodec.command(method: request.method, path: request.path, body: request.body) {
                await context.commands.handle(command)
                context.snapshots.refresh()
                await self.pushImmediateUpdates(positionOnly: command.isPositionOnly)
                return .response(data: Self.emptyResponse(), keepAlive: false)
            }
            return .response(data: Self.plainResponse(status: 404, body: "Not Found"), keepAlive: false)
        }
    }

    private func isAuthorized(_ headers: [String: String]) -> Bool {
        guard let authorization = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authorization.isEmpty
        else {
            return false
        }

        return authorization == self.token || authorization == "Bearer \(self.token)"
    }

    private func startMonitoringLoop() {
        self.monitorTask?.cancel()
        self.monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pushImmediateUpdates()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pushImmediateUpdates(positionOnly: Bool = false) async {
        guard let context,
              self.connections.contains(where: \.value.isWebSocket)
        else {
            return
        }

        context.snapshots.refresh()
        let snapshot = context.snapshots.snapshot
        let previous = self.lastSnapshot
        self.lastSnapshot = snapshot

        if positionOnly {
            self.broadcastPosition(snapshot)
            return
        }

        if previous == nil {
            self.broadcastWebSocketJSON(BoringNotchCodec.playerInfoPayload(type: "PLAYER_INFO", snapshot: snapshot))
        }

        if previous?.track?.videoID != snapshot.track?.videoID {
            self.broadcastWebSocketJSON(BoringNotchCodec.playerInfoPayload(type: "VIDEO_CHANGED", snapshot: snapshot))
            self.broadcastWebSocketJSON(BoringNotchCodec.playerInfoPayload(type: "PLAYER_INFO", snapshot: snapshot))
        }

        if previous?.playbackState != snapshot.playbackState {
            self.broadcastWebSocketJSON(BoringNotchCodec.playerInfoPayload(type: "PLAYER_STATE_CHANGED", snapshot: snapshot))
        }

        if previous?.track != snapshot.track {
            self.broadcastWebSocketJSON(BoringNotchCodec.playerInfoPayload(type: "PLAYER_INFO", snapshot: snapshot))
        }

        self.broadcastPosition(snapshot)

        if previous?.volume != snapshot.volume {
            self.broadcastWebSocketJSON(["type": "VOLUME_CHANGED", "volume": snapshot.volume * 100])
        }

        if previous?.repeatMode != snapshot.repeatMode {
            self.broadcastWebSocketJSON(["type": "REPEAT_CHANGED", "repeat": BoringNotchCodec.repeatModeString(snapshot.repeatMode)])
        }

        if previous?.shuffleEnabled != snapshot.shuffleEnabled {
            self.broadcastWebSocketJSON(["type": "SHUFFLE_CHANGED", "shuffle": snapshot.shuffleEnabled, "isShuffled": snapshot.shuffleEnabled])
        }
    }

    private func broadcastPosition(_ snapshot: NowPlayingSnapshot) {
        guard let elapsedSeconds = snapshot.elapsedSeconds else { return }
        self.broadcastWebSocketJSON([
            "type": "POSITION_CHANGED",
            "position": elapsedSeconds,
            "elapsedSeconds": elapsedSeconds,
        ])
    }

    private func sendPlayerInfo(to id: ObjectIdentifier, type: String) {
        guard let context else { return }
        context.snapshots.refresh()
        self.sendWebSocketJSON(to: id, body: BoringNotchCodec.playerInfoPayload(type: type, snapshot: context.snapshots.snapshot))
    }

    private func handleWebSocketFrames(id: ObjectIdentifier, state: inout ConnectionState) -> Bool {
        while true {
            let parseResult = Self.parseWebSocketFrameResult(from: &state.buffer)
            guard case let .frame(frame) = parseResult else {
                if case .invalid = parseResult {
                    return false
                }
                return true
            }

            switch frame.opcode {
            case 0x8:
                self.sendWebSocketFrame(to: id, opcode: 0x8, payload: Data())
                self.closeConnection(id)
                return true
            case 0x9:
                self.sendWebSocketFrame(to: id, opcode: 0xA, payload: frame.payload)
            default:
                continue
            }
        }
    }

    private func sendHTTPResponse(id: ObjectIdentifier, _ payload: Data, closeAfterSend: Bool = false) {
        guard let state = self.connections[id] else { return }
        state.connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                if error != nil || closeAfterSend {
                    self?.closeConnection(id)
                }
            }
        })
    }

    private func sendWebSocketJSON(to id: ObjectIdentifier, body: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let textData = String(data: data, encoding: .utf8)?.data(using: .utf8)
        else {
            return
        }

        self.sendWebSocketFrame(to: id, opcode: 0x1, payload: textData)
    }

    private func broadcastWebSocketJSON(_ body: [String: Any]) {
        let ids = self.connections.filter(\.value.isWebSocket).map(\.key)
        for id in ids {
            self.sendWebSocketJSON(to: id, body: body)
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
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.closeConnection(id)
                }
            }
        })
    }

    private func closeConnection(_ id: ObjectIdentifier) {
        guard let state = self.connections[id] else { return }
        state.connection.cancel()
        self.connections[id] = nil
    }

    static func parseHTTPRequest(from buffer: inout Data) -> HTTPRequest? {
        guard case let .request(request) = parseHTTPRequestResult(from: &buffer) else {
            return nil
        }

        return request
    }

    static func parseHTTPRequestResult(from buffer: inout Data) -> HTTPParseResult {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headerString = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8)
        else {
            return .incomplete
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bodyStart = headerRange.upperBound
        let rawContentLength = headers["content-length"] ?? "0"
        guard let contentLength = Int(rawContentLength),
              contentLength >= 0,
              contentLength <= Constants.maxHTTPBodyBytes,
              bodyStart <= buffer.count
        else {
            return .invalid
        }

        guard buffer.count - bodyStart >= contentLength else { return .incomplete }

        let body = Data(buffer[bodyStart ..< bodyStart + contentLength])
        buffer.removeSubrange(0 ..< bodyStart + contentLength)
        let path = URLComponents(string: requestParts[1])?.path ?? requestParts[1]
        return .request(HTTPRequest(method: requestParts[0], path: path, headers: headers, body: body))
    }

    struct WebSocketFrame {
        let opcode: UInt8
        let payload: Data
    }

    static func parseWebSocketFrame(from buffer: inout Data) -> WebSocketFrame? {
        guard case let .frame(frame) = parseWebSocketFrameResult(from: &buffer) else {
            return nil
        }

        return frame
    }

    static func parseWebSocketFrameResult(from buffer: inout Data) -> WebSocketParseResult {
        guard buffer.count >= 2 else { return .incomplete }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.index(after: buffer.startIndex)]
        let opcode = first & 0x0F
        let masked = second & 0x80 != 0
        var payloadLength = UInt64(second & 0x7F)
        var index = 2

        if payloadLength == 126 {
            guard buffer.count >= index + 2 else { return .incomplete }
            payloadLength = UInt64(buffer[index]) << 8 | UInt64(buffer[index + 1])
            index += 2
        } else if payloadLength == 127 {
            guard buffer.count >= index + 8 else { return .incomplete }
            payloadLength = 0
            for offset in 0 ..< 8 {
                payloadLength = payloadLength << 8 | UInt64(buffer[index + offset])
            }
            index += 8
        }

        guard payloadLength <= UInt64(Constants.maxWebSocketPayloadBytes),
              payloadLength <= UInt64(Int.max)
        else {
            return .invalid
        }

        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= index + 4 else { return .incomplete }
            maskKey = Array(buffer[index ..< index + 4])
            index += 4
        }

        let payloadByteCount = Int(payloadLength)
        guard index <= buffer.count,
              buffer.count - index >= payloadByteCount
        else {
            return .incomplete
        }

        var payload = Data(buffer[index ..< index + payloadByteCount])
        if masked {
            for i in 0 ..< payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        buffer.removeSubrange(0 ..< index + payloadByteCount)
        return .frame(WebSocketFrame(opcode: opcode, payload: payload))
    }

    private static func isWebSocketUpgrade(_ headers: [String: String]) -> Bool {
        headers["upgrade"]?.lowercased() == "websocket"
    }

    static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let normalizedHost = String(describing: host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        return Self.isAllowedLocalHost(normalizedHost)
    }

    static func isAllowedHostHeader(_ hostHeader: String?) -> Bool {
        guard let hostHeader else { return false }
        guard let host = Self.normalizedLocalHost(from: hostHeader) else { return false }

        return Self.isAllowedLocalHost(host)
    }

    static func isAllowedOriginHeader(_ originHeader: String?) -> Bool {
        guard let originHeader else { return true }
        let value = originHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.lowercased() != "null",
              let components = URLComponents(string: value),
              let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        else {
            return false
        }

        return Self.isAllowedLocalHost(host)
    }

    private static func normalizedLocalHost(from hostHeader: String) -> String? {
        let value = hostHeader.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        let host: String = if value.hasPrefix("["),
                              let closingBracket = value.firstIndex(of: "]")
        {
            String(value[value.index(after: value.startIndex) ..< closingBracket])
        } else if value.count(where: { $0 == ":" }) > 1 {
            value
        } else {
            value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? value
        }

        return host
    }

    private static func isAllowedLocalHost(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }

    private static func webSocketHandshakeResponse(secWebSocketKey: String) -> Data {
        let acceptSource = secWebSocketKey + Constants.wsGUID
        let accept = Data(Insecure.SHA1.hash(data: Data(acceptSource.utf8))).base64EncodedString()

        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r
        """
        return Data(response.utf8)
    }

    private static func jsonResponse(status: Int, body: [String: Any]) -> Data {
        let data = JSONSerialization.isValidJSONObject(body)
            ? (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
            : Data("{}".utf8)
        return Self.httpResponse(status: status, contentType: "application/json", body: data)
    }

    private static func emptyResponse() -> Data {
        self.httpResponse(status: 200, contentType: "application/json", body: Data("{}".utf8))
    }

    private static func plainResponse(status: Int, body: String) -> Data {
        self.httpResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    private static func httpResponse(status: Int, contentType: String, body: Data) -> Data {
        let reason = switch status {
        case 200:
            "OK"
        case 400:
            "Bad Request"
        case 401:
            "Unauthorized"
        case 403:
            "Forbidden"
        case 404:
            "Not Found"
        case 503:
            "Service Unavailable"
        default:
            "OK"
        }
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: Authorization, Content-Type\r
        \r
        """
        var response = Data(header.utf8)
        response.append(body)
        return response
    }
}

private extension NowPlayingCommand {
    var isPositionOnly: Bool {
        if case .seek = self {
            true
        } else {
            false
        }
    }
}
