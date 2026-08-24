import AppKit
import Darwin
import Foundation
import Observation

// MARK: - DiscordLocalIPCService

/// Native Swift Discord Rich Presence client over local Unix Domain Sockets (`discord-ipc-0`...`discord-ipc-9`).
/// Adheres strictly to Swift Concurrency, zero third-party dependencies, and App Sandbox.
@MainActor
@Observable
final class DiscordLocalIPCService: DiscordPresenceServiceProtocol {
    nonisolated static let defaultClientID = "1541148589269454989"
    nonisolated static let maxRetries = 5
    nonisolated static let maxFrameSize: UInt32 = 64 * 1024

    private(set) var state: DiscordPresenceState = .disconnected

    private let clientID: String
    private let logger = DiagnosticsLogger.discord

    private var socketFD: Int32?
    private var isConnected = false
    private var isExplicitlyDisconnected = true
    private var retryCount = 0
    private var pendingPayload: DiscordPresencePayload?

    // swiftformat:disable modifierOrder
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObserverTasks: [Task<Void, Never>] = []
    // swiftformat:enable modifierOrder

    init(clientID: String = defaultClientID) {
        self.clientID = clientID
        self.setupWorkspaceObservers()
    }

    deinit {
        for task in self.workspaceObserverTasks {
            task.cancel()
        }
    }

    // MARK: - Connection

    func connect() async {
        self.isExplicitlyDisconnected = false
        guard !self.state.isConnected, !self.state.isConnecting else { return }
        self.retryCount = 0
        self.retryTask?.cancel()
        await self.attemptConnection()
    }

    func disconnect() async {
        self.isExplicitlyDisconnected = true
        self.pendingPayload = nil
        self.retryTask?.cancel()
        self.retryTask = nil
        self.readTask?.cancel()
        self.readTask = nil
        self.retryCount = 0
        self.closeConnection()
        self.state = .disconnected
    }

    private func closeConnection() {
        if let fd = self.socketFD {
            close(fd)
            self.socketFD = nil
        }
        self.isConnected = false
    }

    private func attemptConnection() async {
        self.retryCount += 1
        self.state = .connecting(attempt: self.retryCount)
        self.logger.info("Attempting local Discord IPC connection (attempt \(self.retryCount)/\(Self.maxRetries))")

        guard let (fd, socketPath) = self.discoverAndConnectSocket() else {
            self.logger.warning("No working Discord IPC socket found")
            await self.handleConnectionFailure(reason: "Discord desktop app not running")
            return
        }

        self.socketFD = fd

        do {
            try await self.sendHandshake(fd: fd)
            self.isConnected = true
            self.state = .connected
            self.retryCount = 0
            self.logger.info("Connected to Discord IPC successfully on socket \(socketPath)")
            self.startReadLoop(fd: fd)

            if let pending = self.pendingPayload {
                try await self.updatePresence(pending)
            }
        } catch {
            self.logger.error("Discord Handshake failed: \(error.localizedDescription)")
            self.closeConnection()
            await self.handleConnectionFailure(reason: error.localizedDescription)
        }
    }

    private func handleConnectionFailure(reason _: String) async {
        self.closeConnection()

        if self.retryCount < Self.maxRetries {
            let backoffSeconds = pow(2.0, Double(self.retryCount - 1))
            self.logger.info("Discord IPC retry in \(backoffSeconds)s...")

            self.retryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(backoffSeconds))
                guard let self, !Task.isCancelled else { return }
                await self.attemptConnection()
            }
        } else {
            self.state = .error("Discord not detected. Please make sure Discord is running.")
            self.logger.warning("Reached max connection retries for Discord IPC")
        }
    }

    // MARK: - Handshake & Framing

    /// Opcode 0 = Handshake, 1 = Frame, 2 = Close, 3 = Ping, 4 = Pong
    private func sendHandshake(fd: Int32) async throws {
        let handshakeJSON: [String: Any] = [
            "v": 1,
            "client_id": self.clientID,
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: handshakeJSON)
        try Self.writePacket(fd: fd, opcode: 0, data: jsonData)

        // Read handshake response frame (Opcode 1 / DISPATCH READY)
        let (opcode, data) = try Self.readPacket(fd: fd)
        guard opcode == 1 else {
            throw NSError(
                domain: "DiscordIPC",
                code: Int(opcode),
                userInfo: [NSLocalizedDescriptionKey: "Unexpected handshake response opcode \(opcode)"]
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let evt = json["evt"] as? String,
              evt == "READY"
        else {
            throw NSError(
                domain: "DiscordIPC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid handshake response from Discord"]
            )
        }
    }

    nonisolated static func writePacket(fd: Int32, opcode: UInt32, data: Data) throws {
        var header = Data(capacity: 8)
        var op = opcode.littleEndian
        var length = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &op) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }

        let packet = header + data
        try packet.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < packet.count {
                let written = write(fd, base.advanced(by: totalWritten), packet.count - totalWritten)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw NSError(
                        domain: "DiscordIPC",
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                    )
                }
                if written == 0 {
                    throw NSError(
                        domain: "DiscordIPC",
                        code: Int(EPIPE),
                        userInfo: [NSLocalizedDescriptionKey: "Socket closed unexpectedly"]
                    )
                }
                totalWritten += written
            }
        }
    }

    nonisolated static func readPacket(fd: Int32) throws -> (opcode: UInt32, data: Data) {
        var header = [UInt8](repeating: 0, count: 8)
        var headerRead = 0
        while headerRead < 8 {
            let n = read(fd, &header[headerRead], 8 - headerRead)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                throw NSError(
                    domain: "DiscordIPC",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
            if n == 0 {
                throw NSError(
                    domain: "DiscordIPC",
                    code: Int(ECONNRESET),
                    userInfo: [NSLocalizedDescriptionKey: "Socket closed before header read"]
                )
            }
            headerRead += n
        }

        let opcode = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let length = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }

        guard length <= self.maxFrameSize else {
            throw NSError(
                domain: "DiscordIPC",
                code: Int(EMSGSIZE),
                userInfo: [NSLocalizedDescriptionKey: "Frame length \(length) exceeds maximum allowed size"]
            )
        }

        var body = [UInt8](repeating: 0, count: Int(length))
        var totalRead = 0
        while totalRead < Int(length) {
            let n = read(fd, &body[totalRead], Int(length) - totalRead)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                throw NSError(
                    domain: "DiscordIPC",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
            if n == 0 {
                throw NSError(
                    domain: "DiscordIPC",
                    code: Int(ECONNRESET),
                    userInfo: [NSLocalizedDescriptionKey: "Socket closed before frame body read complete"]
                )
            }
            totalRead += n
        }

        return (opcode, Data(body))
    }

    private func startReadLoop(fd: Int32) {
        self.readTask?.cancel()
        self.readTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let (opcode, data) = try DiscordLocalIPCService.readPacket(fd: fd)
                    if opcode == 2 { // Close
                        await self?.handleDisconnect(for: fd)
                        break
                    } else if opcode == 3 { // Ping -> respond with Pong (opcode 4)
                        await self?.sendPong(fd: fd, data: data)
                    } else if opcode == 1 { // Frame responses
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let evt = json["evt"] as? String, evt == "ERROR"
                        {
                            let errorData = json["data"] as? [String: Any]
                            let errorMsg = errorData?["message"] as? String ?? "Unknown Discord error"
                            await self?.handleDiscordError(errorMsg)
                        }
                    }
                } catch {
                    await self?.handleDisconnect(for: fd)
                    break
                }
            }
        }
    }

    private func sendPong(fd: Int32, data: Data) {
        guard self.socketFD == fd, self.isConnected else { return }
        try? Self.writePacket(fd: fd, opcode: 4, data: data)
    }

    private func handleDiscordError(_ message: String) {
        self.logger.error("Discord IPC error frame: \(message, privacy: .public)")
    }

    private func handleDisconnect(for fd: Int32) async {
        guard self.socketFD == fd else { return }
        self.closeConnection()
        self.state = .disconnected
        if !self.isExplicitlyDisconnected, self.pendingPayload != nil {
            await self.attemptConnection()
        }
    }

    // MARK: - Workspace Observers

    private func setupWorkspaceObservers() {
        let launchTask = Task { @MainActor [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await notification in center.notifications(named: NSWorkspace.didLaunchApplicationNotification) {
                guard !Task.isCancelled else { break }
                self?.handleApplicationLaunched(notification)
            }
        }
        let terminateTask = Task { @MainActor [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await notification in center.notifications(named: NSWorkspace.didTerminateApplicationNotification) {
                guard !Task.isCancelled else { break }
                self?.handleApplicationTerminated(notification)
            }
        }
        self.workspaceObserverTasks = [launchTask, terminateTask]
    }

    nonisolated static func isDiscordApplication(bundleID: String?, localizedName: String?) -> Bool {
        if let bundleID = bundleID?.lowercased() {
            if bundleID == "com.hnc.discord" ||
                bundleID == "com.hammerandchisel.discord" ||
                bundleID == "com.hnc.discordptb" ||
                bundleID == "com.hnc.discordcanary" ||
                bundleID == "com.hnc.discorddevelopment" ||
                bundleID.contains("discord")
            {
                return true
            }
        }
        if let localizedName = localizedName?.lowercased(), localizedName.contains("discord") {
            return true
        }
        return false
    }

    private func handleApplicationLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Self.isDiscordApplication(bundleID: app.bundleIdentifier, localizedName: app.localizedName)
        else { return }

        self.logger.info("Detected Discord application launch (\(app.bundleIdentifier ?? app.localizedName ?? "Discord", privacy: .public)); initiating connection")
        guard !self.isExplicitlyDisconnected else { return }
        guard !self.state.isConnected, !self.state.isConnecting else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.isExplicitlyDisconnected else { return }
            self.retryCount = 0
            self.retryTask?.cancel()
            await self.attemptConnection()
        }
    }

    private func handleApplicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Self.isDiscordApplication(bundleID: app.bundleIdentifier, localizedName: app.localizedName)
        else { return }

        self.logger.info("Detected Discord application termination (\(app.bundleIdentifier ?? app.localizedName ?? "Discord", privacy: .public)); disconnecting cleanly")
        self.retryTask?.cancel()
        self.retryTask = nil
        self.readTask?.cancel()
        self.readTask = nil
        self.retryCount = 0
        self.closeConnection()
        self.state = .disconnected
    }

    // MARK: - Presence Updates

    func updatePresence(_ payload: DiscordPresencePayload?) async throws {
        self.pendingPayload = payload

        guard let fd = self.socketFD, self.isConnected else {
            // Only auto-reconnect if not explicitly disconnected and payload is active
            if !self.isExplicitlyDisconnected, payload != nil, !self.state.isConnected, !self.state.isConnecting {
                await self.connect()
            }
            return
        }

        let nonce = UUID().uuidString

        var args: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]

        if let payload {
            var activity: [String: Any] = [
                "type": payload.type,
            ]
            if let details = payload.details {
                activity["details"] = details
            }
            if let state = payload.state {
                activity["state"] = state
            }

            if let timestamps = payload.timestamps {
                var ts: [String: Any] = [:]
                if let start = timestamps.start {
                    ts["start"] = start
                }
                if let end = timestamps.end {
                    ts["end"] = end
                }
                activity["timestamps"] = ts
            }

            if let assets = payload.assets {
                var ast: [String: Any] = [:]
                if let largeImage = assets.large_image {
                    ast["large_image"] = largeImage
                }
                if let largeText = assets.large_text {
                    ast["large_text"] = largeText
                }
                if let smallImage = assets.small_image {
                    ast["small_image"] = smallImage
                }
                if let smallText = assets.small_text {
                    ast["small_text"] = smallText
                }
                activity["assets"] = ast
            }

            if let buttons = payload.buttons, !buttons.isEmpty {
                activity["buttons"] = buttons.map { ["label": $0.label, "url": $0.url] }
            }

            args["activity"] = activity
        }

        let frameJSON: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": args,
            "nonce": nonce,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: frameJSON)
        try Self.writePacket(fd: fd, opcode: 1, data: jsonData)
    }

    func clearPresence() async {
        self.pendingPayload = nil
        guard self.isConnected, self.socketFD != nil else { return }
        try? await self.updatePresence(nil)
    }

    // MARK: - Socket Discovery & Connection

    private func discoverAndConnectSocket() -> (fd: Int32, path: String)? {
        let fileManager = FileManager.default

        var searchDirs: [String] = [
            "/tmp",
            "/private/tmp",
            NSTemporaryDirectory(),
        ]

        if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] {
            searchDirs.append(tmpdir)
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] {
            searchDirs.append(xdg)
        }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if len > 0 {
            let darwinTmp = buffer.withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress else { return "" }
                return String(cString: base)
            }
            if !darwinTmp.isEmpty {
                searchDirs.append(darwinTmp)
            }
        }

        var visitedPaths = Set<String>()
        for dir in searchDirs {
            for i in 0 ..< 10 {
                let path = (dir as NSString).appendingPathComponent("discord-ipc-\(i)")
                guard !visitedPaths.contains(path), fileManager.fileExists(atPath: path) else {
                    continue
                }
                visitedPaths.insert(path)

                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }

                var nosigpipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = path.utf8CString
                let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
                withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
                    for (idx, byte) in pathBytes.enumerated() where idx < maxLen {
                        ptr[idx] = byte
                    }
                }

                let connectResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }

                if connectResult == 0 {
                    var peerUID: uid_t = 0
                    var peerGID: gid_t = 0
                    if getpeereid(fd, &peerUID, &peerGID) != 0 || peerUID != getuid() {
                        self.logger.warning("Rejected Discord socket at \(path): peer UID does not match current user UID")
                        close(fd)
                        continue
                    }
                    self.logger.info("Connected to Discord socket at \(path)")
                    return (fd, path)
                } else {
                    close(fd)
                }
            }
        }

        return nil
    }
}
