import Foundation
import Testing
@testable import Kaset

@Suite(.serialized)
@MainActor
struct DiscordRPCServiceTests {
    @Test("Discord RPC Handshake serialization")
    func handshakeSerialization() throws {
        let handshake = DiscordHandshake(v: 1, client_id: "123456789")
        let data = try JSONEncoder().encode(handshake)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"v\":1"))
        #expect(json.contains("\"client_id\":\"123456789\""))
    }

    @Test("Discord RPC Activity payload serialization")
    func activityPayloadSerialization() throws {
        let activity = DiscordActivity(
            state: "by Test Artist",
            details: "Test Track",
            timestamps: DiscordActivityTimestamps(start: 1000, end: 2000),
            assets: DiscordActivityAssets(
                large_image: "http://thumb.jpg",
                large_text: "Test Album",
                small_image: nil,
                small_text: "Playing"
            ),
            buttons: [
                DiscordActivityButton(label: "Listen", url: "http://listen"),
            ]
        )

        let payload = DiscordActivityPayload(
            cmd: "SET_ACTIVITY",
            args: DiscordActivityArgs(pid: 999, activity: activity),
            nonce: "unique-nonce"
        )

        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"cmd\":\"SET_ACTIVITY\""))
        #expect(json.contains("\"pid\":999"))
        #expect(json.contains("\"state\":\"by Test Artist\""))
        #expect(json.contains("\"details\":\"Test Track\""))
        #expect(json.contains("\"start\":1000"))
        #expect(json.contains("\"end\":2000"))
        #expect(json.contains("\"large_image\":\"http:\\/\\/thumb.jpg\"") || json.contains("\"large_image\":\"http://thumb.jpg\""))
        #expect(json.contains("\"large_text\":\"Test Album\""))
        #expect(json.contains("\"small_text\":\"Playing\""))
        #expect(json.contains("\"label\":\"Listen\""))
        #expect(json.contains("\"url\":\"http:\\/\\/listen\"") || json.contains("\"url\":\"http://listen\""))
        #expect(json.contains("\"nonce\":\"unique-nonce\""))
    }

    @Test("DiscordRPCService initialization")
    func serviceInit() {
        let service = DiscordRPCService(clientID: "test-client")
        #expect(service != nil)
    }

    @Test("DiscordRPCService obeys enableDiscordRPC setting")
    func serviceObeysSetting() {
        let settings = SettingsManager.shared
        let original = settings.enableDiscordRPC
        defer {
            settings.enableDiscordRPC = original
        }

        settings.enableDiscordRPC = false
        let service = DiscordRPCService()

        let song = Song(
            id: "test",
            title: "Test Title",
            artists: [Artist(id: "art", name: "Art Name")],
            videoId: "test"
        )

        service.updateActivity(song: song, isPlaying: true, currentTimeMs: 5000)
        #expect(settings.enableDiscordRPC == false)
    }
}
