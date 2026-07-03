import Foundation
import Network
import Testing
@testable import Kaset

// MARK: - NowPlayingSurfaceTests

@Suite(.serialized, .tags(.service))
@MainActor
struct NowPlayingSurfaceTests {
    @Test("snapshot derives canonical track, playback, and lyric state")
    func snapshotDerivesCanonicalState() {
        let player = PlayerService()
        let lyrics = SyncedLyricsService(providers: [])
        let store = NowPlayingSnapshotStore(playerService: player, lyricsService: lyrics)

        player.currentTrack = Song(
            id: "video-1",
            title: "Test Song",
            artists: [Artist(id: "artist-1", name: "Test Artist")],
            album: Album(
                id: "album-1",
                title: "Test Album",
                artists: nil,
                thumbnailURL: nil,
                year: nil,
                trackCount: nil
            ),
            duration: 180,
            thumbnailURL: URL(string: "https://example.com/art.jpg"),
            videoId: "video-1"
        )
        player.state = .playing
        player.progress = 42
        player.currentTimeMs = 42000
        player.duration = 180
        player.volume = 0.7
        player.shuffleEnabled = true
        player.cycleRepeatMode()
        player.updateLikeStatus(.like)
        lyrics.currentLyrics = .synced(SyncedLyrics(lines: [
            SyncedLyricLine(timeInMs: 40000, duration: 3000, text: "Current line", words: nil),
            SyncedLyricLine(timeInMs: 45000, duration: 3000, text: "Next line", words: nil),
        ], source: "Test Provider"))

        store.refresh()

        #expect(store.snapshot.track?.title == "Test Song")
        #expect(store.snapshot.track?.artist == "Test Artist")
        #expect(store.snapshot.track?.albumTitle == "Test Album")
        #expect(store.snapshot.playbackState == .playing)
        #expect(store.snapshot.elapsedSeconds == 42)
        #expect(store.snapshot.durationSeconds == 180)
        #expect(store.snapshot.volume == 0.7)
        #expect(store.snapshot.shuffleEnabled)
        #expect(store.snapshot.repeatMode == .all)
        #expect(store.snapshot.likeStatus == .like)
        #expect(store.snapshot.currentLyricLine?.text == "Current line")
    }

    @Test("command router clamps external values before mutating playback")
    func commandRouterClampsExternalValues() async {
        let player = MockPlayerService()
        let router = PlayerNowPlayingCommandRouter(playerService: player)

        await router.handle(.setVolume(1.5))
        #expect(player.volume == 1)

        await router.handle(.setVolume(-0.2))
        #expect(player.volume == 0)

        await router.handle(.seek(seconds: -12))
        #expect(player.progress == 0)

        await router.handle(.toggleShuffle)
        #expect(player.shuffleEnabled)
    }

    @Test("lyrics demand coordinator reference-counts polling by consumer")
    func lyricsDemandReferenceCountsPolling() {
        let poller = SpyLyricsPoller()
        let coordinator = LyricsDemandCoordinator(poller: poller)

        coordinator.setDemand(for: .init("sidebar"), isActive: true)
        coordinator.setDemand(for: .init("musicIsland"), isActive: true)
        coordinator.setDemand(for: .init("sidebar"), isActive: false)
        coordinator.setDemand(for: .init("musicIsland"), isActive: false)

        #expect(poller.startCallCount == 1)
        #expect(poller.stopCallCount == 1)
    }

    @Test("lyrics demand keeps polling until every same-id consumer releases")
    func lyricsDemandKeepsPollingForSameIDConsumers() {
        let poller = SpyLyricsPoller()
        let coordinator = LyricsDemandCoordinator(poller: poller)
        let consumer = NowPlayingSurfaceID("lyrics")

        coordinator.setDemand(for: consumer, isActive: true)
        coordinator.setDemand(for: consumer, isActive: true)
        coordinator.setDemand(for: consumer, isActive: false)

        #expect(poller.startCallCount == 1)
        #expect(poller.stopCallCount == 0)

        coordinator.setDemand(for: consumer, isActive: false)

        #expect(poller.stopCallCount == 1)
    }

    @Test("lyrics demand coordinator deduplicates synced lyric fetches for same track")
    func lyricsDemandCoordinatorDeduplicatesFetches() async {
        let provider = CountingLyricsProvider(result: .unavailable)
        let service = SyncedLyricsService(providers: [provider])
        let coordinator = LyricsDemandCoordinator(
            poller: SpyLyricsPoller(),
            lyricsService: service
        )
        let song = TestFixtures.makeSong(id: "lyrics-video")

        await coordinator.fetchSyncedLyricsIfNeeded(for: song)
        await coordinator.fetchSyncedLyricsIfNeeded(for: song)

        #expect(await provider.searchCount == 1)
    }

    @Test("surface settings store enabled surface ids generically")
    func surfaceSettingsStoreEnabledIDsGenerically() {
        let settings = SettingsManager.shared
        let original = settings.enabledNowPlayingSurfaces
        defer { settings.enabledNowPlayingSurfaces = original }

        settings.enabledNowPlayingSurfaces = []
        settings.setNowPlayingSurface(.musicIsland, enabled: true)
        settings.setNowPlayingSurface(.boringNotchBridge, enabled: true)
        settings.setNowPlayingSurface(.musicIsland, enabled: false)

        #expect(settings.isNowPlayingSurfaceEnabled(.musicIsland) == false)
        #expect(settings.isNowPlayingSurfaceEnabled(.boringNotchBridge) == true)
    }

    @Test("coordinator starts and stops adapters based on enabled settings")
    func coordinatorReconcilesEnabledSurfaces() async {
        let settings = SettingsManager.shared
        let original = settings.enabledNowPlayingSurfaces
        defer { settings.enabledNowPlayingSurfaces = original }

        let adapter = FakeNowPlayingSurfaceAdapter(id: .init("fake"))
        let coordinator = Self.makeCoordinator(adapters: [adapter], settings: settings)
        settings.enabledNowPlayingSurfaces = []

        await coordinator.reconcileEnabledSurfaces()
        #expect(adapter.startCount == 0)
        #expect(adapter.stopCount == 0)

        settings.enabledNowPlayingSurfaces = [.init("fake")]
        await coordinator.reconcileEnabledSurfaces()
        #expect(adapter.startCount == 1)

        // Already active: a redundant reconcile must not restart it.
        await coordinator.reconcileEnabledSurfaces()
        #expect(adapter.startCount == 1)

        settings.enabledNowPlayingSurfaces = []
        await coordinator.reconcileEnabledSurfaces()
        #expect(adapter.stopCount == 1)

        await coordinator.stop()
    }

    @Test("coordinator retries adapters that fail to start")
    func coordinatorRetriesFailedStart() async {
        let settings = SettingsManager.shared
        let original = settings.enabledNowPlayingSurfaces
        defer { settings.enabledNowPlayingSurfaces = original }

        let adapter = FakeNowPlayingSurfaceAdapter(id: .init("fake"), startResult: false)
        let coordinator = Self.makeCoordinator(adapters: [adapter], settings: settings)
        settings.enabledNowPlayingSurfaces = [.init("fake")]

        await coordinator.reconcileEnabledSurfaces()
        #expect(adapter.startCount == 1)

        // Failed start must stay inactive and be retried, never stopped.
        await coordinator.reconcileEnabledSurfaces()
        #expect(adapter.startCount == 2)
        #expect(adapter.stopCount == 0)

        await coordinator.stop()
    }

    @Test("coordinator retries active adapters that stop running")
    func coordinatorRetriesStoppedActiveAdapter() async {
        let settings = SettingsManager.shared
        let original = settings.enabledNowPlayingSurfaces
        defer { settings.enabledNowPlayingSurfaces = original }

        let adapter = FakeNowPlayingSurfaceAdapter(id: .init("fake"))
        let coordinator = Self.makeCoordinator(adapters: [adapter], settings: settings)
        settings.enabledNowPlayingSurfaces = [.init("fake")]

        await coordinator.reconcileEnabledSurfaces()
        #expect(adapter.startCount == 1)

        adapter.isRunning = false
        await coordinator.reconcileEnabledSurfaces()

        #expect(adapter.startCount == 2)

        await coordinator.stop()
    }

    @Test("Boring Notch codec preserves compatibility payload")
    func boringNotchCodecPreservesCompatibilityPayload() {
        let snapshot = NowPlayingSnapshot(
            playbackState: .playing,
            track: NowPlayingTrackSnapshot(
                title: "Test Song",
                artist: "Test Artist",
                albumTitle: "Test Album",
                artworkURL: URL(string: "https://example.com/art.jpg"),
                videoID: "video-1"
            ),
            elapsedSeconds: 12,
            durationSeconds: 180,
            volume: 0.42,
            shuffleEnabled: true,
            repeatMode: .one,
            likeStatus: .dislike,
            currentLyricLine: nil
        )

        let payload = BoringNotchCodec.playerInfoPayload(type: "PLAYER_INFO", snapshot: snapshot)

        #expect(payload["type"] as? String == "PLAYER_INFO")
        #expect(payload["title"] as? String == "Test Song")
        #expect(payload["artist"] as? String == "Test Artist")
        #expect(payload["album"] as? String == "Test Album")
        #expect(payload["videoId"] as? String == "video-1")
        #expect(payload["elapsedSeconds"] as? Double == 12)
        #expect(payload["songDuration"] as? Double == 180)
        #expect(payload["volume"] as? Double == 42)
        #expect(payload["isPaused"] as? Bool == false)
        #expect(payload["repeatMode"] as? Int == 2)
        #expect(payload["repeatModeString"] as? String == "ONE")
        #expect(payload["isShuffled"] as? Bool == true)
        #expect(payload["song"] is [String: Any])
    }

    @Test("local bridge only accepts loopback endpoints")
    func localBridgeOnlyAcceptsLoopbackEndpoints() {
        #expect(LocalNowPlayingBridgeAdapter.isLoopbackEndpoint(.hostPort(host: "127.0.0.1", port: 26538)))
        #expect(LocalNowPlayingBridgeAdapter.isLoopbackEndpoint(.hostPort(host: "::1", port: 26538)))
        #expect(LocalNowPlayingBridgeAdapter.isLoopbackEndpoint(.hostPort(host: "localhost", port: 26538)))
        #expect(!LocalNowPlayingBridgeAdapter.isLoopbackEndpoint(.hostPort(host: "192.168.1.42", port: 26538)))
    }

    @Test("local bridge only accepts localhost Host headers")
    func localBridgeOnlyAcceptsLocalhostHostHeaders() {
        #expect(LocalNowPlayingBridgeAdapter.isAllowedHostHeader("localhost:26538"))
        #expect(LocalNowPlayingBridgeAdapter.isAllowedHostHeader("127.0.0.1:26538"))
        #expect(LocalNowPlayingBridgeAdapter.isAllowedHostHeader("[::1]:26538"))
        #expect(LocalNowPlayingBridgeAdapter.isAllowedHostHeader("::1"))
        #expect(!LocalNowPlayingBridgeAdapter.isAllowedHostHeader("attacker.example:26538"))
        #expect(!LocalNowPlayingBridgeAdapter.isAllowedHostHeader(nil))
    }

    @Test("local bridge only accepts absent or localhost Origin headers")
    func localBridgeOnlyAcceptsLocalhostOriginHeaders() {
        #expect(LocalNowPlayingBridgeAdapter.isAllowedOriginHeader(nil))
        #expect(LocalNowPlayingBridgeAdapter.isAllowedOriginHeader("http://localhost:26538"))
        #expect(LocalNowPlayingBridgeAdapter.isAllowedOriginHeader("http://127.0.0.1:26538"))
        #expect(LocalNowPlayingBridgeAdapter.isAllowedOriginHeader("http://[::1]:26538"))
        #expect(!LocalNowPlayingBridgeAdapter.isAllowedOriginHeader("https://attacker.example"))
        #expect(!LocalNowPlayingBridgeAdapter.isAllowedOriginHeader("null"))
    }

    @Test("HTTP parser waits for complete body and leaves pipelined bytes")
    func httpParserWaitsForCompleteBodyAndLeavesPipelinedBytes() {
        var buffer = Data("POST /api/v1/volume HTTP/1.1\r\nHost: localhost:26538\r\nContent-Length: 14\r\n\r\n{\"volume\":10".utf8)

        guard case .incomplete = LocalNowPlayingBridgeAdapter.parseHTTPRequestResult(from: &buffer) else {
            Issue.record("Expected incomplete request while body is partial")
            return
        }

        buffer.append(Data("0}GET /api/v1/song HTTP/1.1\r\nHost: localhost:26538\r\n\r\n".utf8))

        guard case let .request(firstRequest) = LocalNowPlayingBridgeAdapter.parseHTTPRequestResult(from: &buffer) else {
            Issue.record("Expected complete first request")
            return
        }

        #expect(firstRequest.method == "POST")
        #expect(firstRequest.path == "/api/v1/volume")
        #expect(firstRequest.headers["host"] == "localhost:26538")
        #expect(String(data: firstRequest.body, encoding: .utf8) == "{\"volume\":100}")

        guard case let .request(secondRequest) = LocalNowPlayingBridgeAdapter.parseHTTPRequestResult(from: &buffer) else {
            Issue.record("Expected pipelined second request")
            return
        }
        #expect(secondRequest.method == "GET")
        #expect(secondRequest.path == "/api/v1/song")
        #expect(buffer.isEmpty)
    }

    @Test("HTTP parser rejects invalid and oversized Content-Length")
    func httpParserRejectsInvalidContentLength() {
        var negative = Data("POST /auth/boringNotch HTTP/1.1\r\nHost: localhost:26538\r\nContent-Length: -1\r\n\r\n".utf8)
        guard case .invalid = LocalNowPlayingBridgeAdapter.parseHTTPRequestResult(from: &negative) else {
            Issue.record("Expected negative Content-Length to be invalid")
            return
        }

        var oversized = Data("POST /auth/boringNotch HTTP/1.1\r\nHost: localhost:26538\r\nContent-Length: 1048577\r\n\r\n".utf8)
        guard case .invalid = LocalNowPlayingBridgeAdapter.parseHTTPRequestResult(from: &oversized) else {
            Issue.record("Expected oversized Content-Length to be invalid")
            return
        }
    }

    @Test("WebSocket parser unmasks client text frames")
    func websocketParserUnmasksClientTextFrames() {
        var buffer = Self.maskedWebSocketFrame(opcode: 0x1, payload: Data("ping".utf8), mask: [1, 2, 3, 4])

        guard case let .frame(frame) = LocalNowPlayingBridgeAdapter.parseWebSocketFrameResult(from: &buffer) else {
            Issue.record("Expected complete masked frame")
            return
        }

        #expect(frame.opcode == 0x1)
        #expect(String(data: frame.payload, encoding: .utf8) == "ping")
        #expect(buffer.isEmpty)
    }

    @Test("WebSocket parser waits for complete extended payload")
    func websocketParserWaitsForCompleteExtendedPayload() {
        let payload = Data(repeating: 0x41, count: 130)
        let frame = Self.maskedWebSocketFrame(opcode: 0x1, payload: payload, mask: [9, 8, 7, 6])
        var buffer = Data(frame.prefix(20))

        guard case .incomplete = LocalNowPlayingBridgeAdapter.parseWebSocketFrameResult(from: &buffer) else {
            Issue.record("Expected incomplete extended frame")
            return
        }

        buffer.append(frame.dropFirst(20))
        guard case let .frame(parsed) = LocalNowPlayingBridgeAdapter.parseWebSocketFrameResult(from: &buffer) else {
            Issue.record("Expected completed extended frame")
            return
        }

        #expect(parsed.opcode == 0x1)
        #expect(parsed.payload == payload)
        #expect(buffer.isEmpty)
    }

    @Test("WebSocket parser rejects oversized 64-bit payload lengths")
    func websocketParserRejectsOversizedPayloadLength() {
        var buffer = Data([0x81, 0xFF])
        buffer.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        buffer.append(contentsOf: [1, 2, 3, 4])

        guard case .invalid = LocalNowPlayingBridgeAdapter.parseWebSocketFrameResult(from: &buffer) else {
            Issue.record("Expected oversized WebSocket frame to be invalid")
            return
        }
    }

    @Test("bridge approval gate denies token until user approval and remembers approval")
    func bridgeApprovalGateDeniesUntilApprovalAndRemembersApproval() async {
        var approvals = [false, true, false]
        let gate = LocalNowPlayingBridgeApprovalGate {
            approvals.removeFirst()
        }

        #expect(await gate.approveIfNeeded() == false)
        #expect(await gate.approveIfNeeded() == true)
        #expect(await gate.approveIfNeeded() == true)
        #expect(approvals == [false])
    }

    private static func makeCoordinator(
        adapters: [any NowPlayingSurfaceAdapter],
        settings: SettingsManager
    ) -> NowPlayingSurfaceCoordinator {
        NowPlayingSurfaceCoordinator(
            adapters: adapters,
            settingsManager: settings,
            snapshotStore: NowPlayingSnapshotStore(
                playerService: MockPlayerService(),
                lyricsService: SyncedLyricsService(providers: [])
            ),
            commandRouter: PlayerNowPlayingCommandRouter(playerService: MockPlayerService()),
            lyricsDemandCoordinator: LyricsDemandCoordinator(poller: SpyLyricsPoller()),
            openMainWindow: {}
        )
    }

    private static func maskedWebSocketFrame(opcode: UInt8, payload: Data, mask: [UInt8]) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)

        if payload.count <= 125 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }

        frame.append(contentsOf: mask)
        for index in 0 ..< payload.count {
            frame.append(payload[index] ^ mask[index % 4])
        }
        return frame
    }
}

// MARK: - SpyLyricsPoller

@MainActor
private final class SpyLyricsPoller: LyricsPolling {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func startLyricsPoll() {
        self.startCallCount += 1
    }

    func stopLyricsPoll() {
        self.stopCallCount += 1
    }
}

// MARK: - CountingLyricsProvider

private actor CountingLyricsProvider: LyricsProvider {
    nonisolated let name = "Counting"
    private let result: LyricResult
    private(set) var searchCount = 0

    init(result: LyricResult) {
        self.result = result
    }

    func search(info _: LyricsSearchInfo) async -> LyricResult {
        self.searchCount += 1
        return self.result
    }
}

// MARK: - FakeNowPlayingSurfaceAdapter

@MainActor
private final class FakeNowPlayingSurfaceAdapter: NowPlayingSurfaceAdapter {
    let descriptor: NowPlayingSurfaceDescriptor
    private let startResult: Bool
    var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(id: NowPlayingSurfaceID, requiresSyncedLyrics: Bool = false, startResult: Bool = true) {
        self.descriptor = NowPlayingSurfaceDescriptor(
            id: id,
            displayName: id.rawValue,
            helpText: "",
            requiresSyncedLyrics: requiresSyncedLyrics
        )
        self.startResult = startResult
    }

    func start(context _: NowPlayingSurfaceContext) async -> Bool {
        self.startCount += 1
        self.isRunning = self.startResult
        return self.startResult
    }

    func stop() async {
        self.isRunning = false
        self.stopCount += 1
    }
}
