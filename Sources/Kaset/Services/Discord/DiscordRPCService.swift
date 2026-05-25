import Darwin
import Foundation
import Observation

// MARK: - DiscordHandshake

struct DiscordHandshake: Codable {
    let v: Int
    let client_id: String
}

// MARK: - DiscordActivityTimestamps

struct DiscordActivityTimestamps: Codable {
    let start: Int64?
    let end: Int64?
}

// MARK: - DiscordActivityAssets

struct DiscordActivityAssets: Codable {
    let large_image: String?
    let large_text: String?
    let small_image: String?
    let small_text: String?
}

// MARK: - DiscordActivityButton

struct DiscordActivityButton: Codable {
    let label: String
    let url: String
}

// MARK: - DiscordActivity

struct DiscordActivity: Codable {
    let state: String?
    let details: String?
    let timestamps: DiscordActivityTimestamps?
    let assets: DiscordActivityAssets?
    let buttons: [DiscordActivityButton]?
}

// MARK: - DiscordActivityArgs

struct DiscordActivityArgs: Codable {
    let pid: Int32
    let activity: DiscordActivity?
}

// MARK: - DiscordActivityPayload

struct DiscordActivityPayload: Codable {
    let cmd: String
    let args: DiscordActivityArgs
    let nonce: String
}

// MARK: - DiscordSocketActor

actor DiscordSocketActor {
    private var socketFD: Int32?
    private let clientID: String
    private let logger = DiagnosticsLogger.discord

    init(clientID: String) {
        self.clientID = clientID
    }

    func connectAndHandshake() -> Bool {
        if self.socketFD != nil {
            self.disconnect()
        }

        let paths = self.findPaths()
        for path in paths {
            if let fd = self.tryConnect(to: path) {
                self.socketFD = fd
                self.logger.info("Connected to Discord Unix socket at \(path) (fd=\(fd))")
                if self.sendHandshake() {
                    if let ready = self.readPacket() {
                        self.logger.info("Received initial packet after handshake: op=\(ready.op) payload=\(ready.payload)")
                    } else {
                        self.logger.warning("No READY packet received after handshake")
                    }
                    return true
                } else {
                    self.logger.error("Handshake failed after connecting to \(path)")
                    self.disconnect()
                }
            }
        }
        self.logger.info("Failed to connect to any Discord Unix sockets")
        return false
    }

    func disconnect() {
        if let fd = self.socketFD {
            _ = self.sendPacket(op: 2, payload: "{}")
            Darwin.close(fd)
            self.socketFD = nil
            self.logger.info("Disconnected from Discord Unix socket")
        }
    }

    func sendActivityUpdate(payload: String) -> Bool {
        guard self.sendPacket(op: 1, payload: payload) else { return false }
        if let response = self.readPacket() {
            self.logger.info("Discord RPC response: \(response.payload)")
            if response.payload.contains("\"evt\":\"ERROR\"") || response.payload.contains("\"error\"") {
                self.logger.error("Discord RPC returned error: \(response.payload)")
                return false
            }
            return true
        }
        return false
    }

    private func findPaths() -> [String] {
        var paths: [String] = []
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        let systemTmpDir: String
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size)
            systemTmpDir = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        } else {
            systemTmpDir = NSTemporaryDirectory()
        }
        for i in 0 ... 9 {
            paths.append("\(systemTmpDir)discord-ipc-\(i)")
            paths.append("/tmp/discord-ipc-\(i)")
        }

        // Deterministically list directories under /private/var/folders and /var/folders to find the active Discord socket
        let fm = FileManager.default
        let searchRoots = ["/private/var/folders", "/var/folders"]
        for root in searchRoots {
            guard let subDirs = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for subDir in subDirs {
                let subDirPath = "\(root)/\(subDir)"
                guard let nestedDirs = try? fm.contentsOfDirectory(atPath: subDirPath) else { continue }
                for nestedDir in nestedDirs {
                    let tPath = "\(subDirPath)/\(nestedDir)/T"
                    if fm.fileExists(atPath: tPath) {
                        for i in 0 ... 9 {
                            let socketPath = "\(tPath)/discord-ipc-\(i)"
                            if fm.fileExists(atPath: socketPath) {
                                paths.append(socketPath)
                            }
                        }
                    }
                }
            }
        }

        // Canonicalize and remove duplicates
        var resolvedPaths: [String] = []
        for path in paths {
            var canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if !canonical.hasPrefix("/private/") {
                if canonical.hasPrefix("/var/") {
                    canonical = "/private" + canonical
                } else if canonical.hasPrefix("/tmp/") {
                    canonical = "/private" + canonical
                }
            }
            resolvedPaths.append(canonical)
        }
        let uniquePaths = Array(Set(resolvedPaths))
        self.logger.debug("Found potential Discord socket paths: \(uniquePaths)")
        return uniquePaths
    }

    private func tryConnect(to path: String) -> Int32? {
        var canonicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if !canonicalPath.hasPrefix("/private/") {
            if canonicalPath.hasPrefix("/var/") {
                canonicalPath = "/private" + canonicalPath
            } else if canonicalPath.hasPrefix("/tmp/") {
                canonicalPath = "/private" + canonicalPath
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        // Set socket timeouts to prevent hanging on write/read
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        canonicalPath.withCString { cString in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
                let destPtr = UnsafeMutableRawPointer(sunPathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(destPtr, cString, maxLength)
            }
        }

        let addrSize = MemoryLayout.size(ofValue: addr)
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(addrSize))
            }
        }

        if connectResult == 0 {
            return fd
        } else {
            let err = errno
            let msg = String(cString: strerror(err))
            self.logger.debug("connect(\"\(canonicalPath, privacy: .public)\") failed: errno=\(err) (\(msg, privacy: .public))")
            Darwin.close(fd)
            return nil
        }
    }

    private func sendHandshake() -> Bool {
        let handshake = DiscordHandshake(v: 1, client_id: self.clientID)
        guard let data = try? JSONEncoder().encode(handshake),
              let jsonStr = String(data: data, encoding: .utf8)
        else {
            return false
        }
        let success = self.sendPacket(op: 0, payload: jsonStr)
        if !success {
            self.logger.error("Failed to send Discord handshake")
        }
        return success
    }

    private func sendPacket(op: Int32, payload: String) -> Bool {
        guard let fd = self.socketFD else { return false }
        guard let payloadData = payload.data(using: .utf8) else { return false }

        var opLittle = op.littleEndian
        var lenLittle = Int32(payloadData.count).littleEndian

        var data = Data()
        withUnsafeBytes(of: &opLittle) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &lenLittle) { data.append(contentsOf: $0) }
        data.append(payloadData)

        let totalSize = data.count
        var totalSent = 0

        while totalSent < totalSize {
            let result = data.withUnsafeBytes { bufferPtr in
                let baseAddress = bufferPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return Darwin.send(fd, baseAddress.advanced(by: totalSent), totalSize - totalSent, 0)
            }

            if result <= 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // transient, try again shortly
                    continue
                }
                let msg = String(cString: strerror(err))
                self.logger.error("send() failed: errno=\(err) (\(msg))")
                return false
            }
            totalSent += result
        }
        return true
    }

    private func readPacket() -> (op: Int32, payload: String)? {
        guard self.socketFD != nil else { return nil }

        guard let headerData = self.readBytes(count: 8) else { return nil }

        let op = headerData.withUnsafeBytes { $0.load(as: Int32.self) }.littleEndian
        let length = headerData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }.littleEndian

        guard length > 0 else {
            return (op, "")
        }

        guard let payloadData = self.readBytes(count: Int(length)) else {
            self.logger.debug("readPacket: failed to read payload of length \(length)")
            return nil
        }
        guard let payloadStr = String(data: payloadData, encoding: .utf8) else {
            self.logger.debug("readPacket: payload not valid UTF-8")
            return nil
        }

        return (op, payloadStr)
    }

    private func readBytes(count: Int) -> Data? {
        guard let fd = self.socketFD else { return nil }
        var data = Data()
        var totalRead = 0

        while totalRead < count {
            let remaining = count - totalRead
            var buffer = [UInt8](repeating: 0, count: remaining)
            let bytesRead = Darwin.recv(fd, &buffer, remaining, 0)
            if bytesRead <= 0 {
                let err = errno
                if bytesRead == 0 {
                    self.logger.debug("recv returned 0 (peer closed socket)")
                } else if err == EAGAIN || err == EWOULDBLOCK {
                    // Try again
                    continue
                } else {
                    let msg = String(cString: strerror(err))
                    self.logger.error("recv failed: errno=\(err) (\(msg))")
                    return nil
                }
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
            totalRead += bytesRead
        }
        return data
    }

    deinit {
        if let fd = self.socketFD {
            Darwin.close(fd)
        }
    }
}

// MARK: - DiscordRPCService

@MainActor
@Observable
final class DiscordRPCService {
    private let actor: DiscordSocketActor
    private var isConnected = false
    private var currentPayload: String?
    private var retryTask: Task<Void, Never>?
    private var currentIsPlaying = false
    private let logger = DiagnosticsLogger.discord
    @ObservationIgnored private nonisolated(unsafe) var socketWatchers: [Int32] = []
    @ObservationIgnored private nonisolated(unsafe) var socketSources: [DispatchSourceFileSystemObject] = []

    init(clientID: String = "463151177836658699") {
        self.actor = DiscordSocketActor(clientID: clientID)
        self.startSocketWatchers()
    }

    deinit {
        // Close any remaining file descriptors synchronously.
        for fd in self.socketWatchers {
            Darwin.close(fd)
        }
        self.socketWatchers.removeAll()
    }

    func updateActivity(song: Song?, isPlaying: Bool, currentTimeMs: Int) {
        guard SettingsManager.shared.enableDiscordRPC else {
            if self.isConnected {
                self.clearActivity()
            }
            return
        }

        self.currentIsPlaying = isPlaying
        self.logger.debug("updateActivity called - song: \(String(describing: song?.title)), playing: \(isPlaying), timeMs: \(currentTimeMs)")

        guard let song else {
            self.clearActivity()
            return
        }

        let state = "by \(song.artistsDisplay)"
        let details = song.title

        let startTimestamp: Int64?
        let endTimestamp: Int64?

        if isPlaying {
            let currentUnix = Int64(Date().timeIntervalSince1970)
            let elapsedSec = Int64(max(0, Double(currentTimeMs) / 1000.0))
            startTimestamp = currentUnix - elapsedSec
            if let duration = song.duration {
                endTimestamp = startTimestamp! + Int64(duration)
            } else {
                endTimestamp = nil
            }
        } else {
            startTimestamp = nil
            endTimestamp = nil
        }

        let thumbnailStr: String? = song.thumbnailURL?.absoluteString ?? song.fallbackThumbnailURL?.absoluteString
        let albumName = song.album?.title

        let activity = DiscordActivity(
            state: state,
            details: details,
            timestamps: isPlaying ? DiscordActivityTimestamps(start: startTimestamp, end: endTimestamp) : nil,
            assets: DiscordActivityAssets(
                large_image: thumbnailStr,
                large_text: albumName ?? "Kaset",
                small_image: nil,
                small_text: isPlaying ? "Playing" : "Paused"
            ),
            buttons: [
                DiscordActivityButton(
                    label: "Listen on YouTube Music",
                    url: "https://music.youtube.com/watch?v=\(song.videoId)"
                ),
            ]
        )

        let payload = DiscordActivityPayload(
            cmd: "SET_ACTIVITY",
            args: DiscordActivityArgs(
                pid: ProcessInfo.processInfo.processIdentifier,
                activity: activity
            ),
            nonce: UUID().uuidString
        )

        self.sendPayload(payload)
    }

    /// Start dispatch-based watchers on possible Discord IPC directories so we can
    /// react immediately when Discord creates the socket file (instead of waiting
    /// for the polling retry loop).
    private func startSocketWatchers() {
        Task.detached { [weak self] in
            guard let self else { return }
            var paths = ["/tmp", "/private/tmp"]

            let fm = FileManager.default
            let searchRoots = ["/private/var/folders", "/var/folders"]
            for root in searchRoots {
                guard let subDirs = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for subDir in subDirs {
                    let subDirPath = "\(root)/\(subDir)"
                    guard let nestedDirs = try? fm.contentsOfDirectory(atPath: subDirPath) else { continue }
                    for nestedDir in nestedDirs {
                        let tPath = "\(subDirPath)/\(nestedDir)/T"
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: tPath, isDirectory: &isDir), isDir.boolValue {
                            paths.append(tPath)
                        }
                    }
                }
            }

            let resolvedPaths = Array(Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }))

            for path in resolvedPaths {
                // Open directory descriptor
                let fd = open(path, O_EVTONLY)
                if fd >= 0 {
                    // Record the fd on the main actor to keep `socketWatchers` isolated
                    await MainActor.run {
                        self.socketWatchers.append(fd)
                    }

                    // swiftlint:disable:next no_dispatch_queue
                    let queue = DispatchQueue(label: "discord.socketwatch.")
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
                    source.setEventHandler { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            self.logger.info("Detected filesystem change in \(path) — attempting immediate Discord connect")
                            if let payload = self.currentPayload {
                                // Try to connect and send current payload immediately
                                let connected = await self.actor.connectAndHandshake()
                                self.isConnected = connected
                                if connected {
                                    let success = await self.actor.sendActivityUpdate(payload: payload)
                                    if success {
                                        self.logger.info("Sent Discord payload after socket appeared")
                                        self.retryTask?.cancel()
                                        self.retryTask = nil
                                    }
                                }
                            } else {
                                // No payload yet — just attempt handshake to register client
                                _ = await self.actor.connectAndHandshake()
                            }
                        }
                    }
                    source.setCancelHandler {
                        Darwin.close(fd)
                    }

                    await MainActor.run {
                        self.socketSources.append(source)
                    }
                    source.resume()
                    self.logger.debug("Watching directory \(path) for Discord socket creation")
                } else {
                    self.logger.debug("Unable to open directory for Discord socket watcher: \(path)")
                }
            }
        }
    }

    func clearActivity() {
        self.currentPayload = nil
        self.retryTask?.cancel()
        self.retryTask = nil
        guard self.isConnected else { return }

        let payload = DiscordActivityPayload(
            cmd: "SET_ACTIVITY",
            args: DiscordActivityArgs(
                pid: ProcessInfo.processInfo.processIdentifier,
                activity: nil
            ),
            nonce: UUID().uuidString
        )

        if let data = try? JSONEncoder().encode(payload),
           let jsonStr = String(data: data, encoding: .utf8)
        {
            Task {
                _ = await self.actor.sendActivityUpdate(payload: jsonStr)
                await self.actor.disconnect()
                self.isConnected = false
            }
        }
    }

    private func sendPayload(_ payload: DiscordActivityPayload) {
        guard let data = try? JSONEncoder().encode(payload),
              let jsonStr = String(data: data, encoding: .utf8)
        else {
            return
        }

        if self.currentPayload == jsonStr, self.isConnected {
            return
        }

        self.currentPayload = jsonStr

        self.sendCurrentPayload(jsonStr)
    }

    private func sendCurrentPayload(_ jsonStr: String) {
        Task {
            guard self.currentPayload == jsonStr else { return }

            if !self.isConnected {
                let connected = await self.actor.connectAndHandshake()
                self.isConnected = connected
                guard connected else {
                    self.scheduleRetry(for: jsonStr)
                    return
                }
            }

            let success = await self.actor.sendActivityUpdate(payload: jsonStr)
            if !success {
                self.logger.warning("Failed to send Discord RPC payload, attempting reconnection")
                await self.actor.disconnect()
                self.isConnected = false

                let reconnected = await self.actor.connectAndHandshake()
                self.isConnected = reconnected
                if reconnected {
                    let retrySuccess = await self.actor.sendActivityUpdate(payload: jsonStr)
                    if retrySuccess {
                        self.retryTask?.cancel()
                        self.retryTask = nil
                        self.logger.info("Successfully resent Discord RPC payload after reconnection")
                    } else {
                        self.logger.error("Failed to resend Discord RPC payload after reconnection")
                        self.scheduleRetry(for: jsonStr)
                    }
                } else {
                    self.scheduleRetry(for: jsonStr)
                }
            } else {
                self.retryTask?.cancel()
                self.retryTask = nil
            }
        }
    }

    private func scheduleRetry(for jsonStr: String) {
        guard self.currentPayload == jsonStr else { return }
        guard self.retryTask == nil || self.retryTask?.isCancelled == true else { return }

        // Don't start a retry loop when playback is paused/idle — this prevents
        // burning CPU and battery scanning for a Discord socket that may not exist.
        // The socket file-system watchers will trigger an immediate connect if
        // Discord appears later, and the next updateActivity call will retry.
        guard self.currentIsPlaying else {
            self.logger.info("Skipping Discord RPC retry loop — playback is paused")
            return
        }

        // Keep attempting to connect every 15 seconds (was 5s) until we succeed or the payload/state changes.
        self.retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let strongSelf = self, strongSelf.currentPayload == jsonStr else {
                    break
                }

                // Bail out if playback stopped while we were sleeping
                guard strongSelf.currentIsPlaying else {
                    strongSelf.logger.info("Discord RPC retry cancelled — playback paused")
                    break
                }

                strongSelf.logger.info("Retrying Discord RPC connection")

                // Try to establish socket connection and handshake
                let connected = await strongSelf.actor.connectAndHandshake()
                if connected {
                    strongSelf.isConnected = true
                    let success = await strongSelf.actor.sendActivityUpdate(payload: jsonStr)
                    if success {
                        strongSelf.logger.info("Successfully sent Discord RPC payload after retry")
                        break
                    } else {
                        strongSelf.logger.warning("Connected but failed to send payload; disconnecting and retrying")
                        await strongSelf.actor.disconnect()
                        strongSelf.isConnected = false
                        // continue loop and retry after delay
                    }
                }
                // otherwise loop again and sleep before next attempt
            }
            await MainActor.run { [weak self] in
                self?.retryTask = nil
            }
        }
    }
}
