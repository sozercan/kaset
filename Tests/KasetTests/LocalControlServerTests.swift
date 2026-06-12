import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct LocalControlServerTests {
    @Test("Routes status and transport controls")
    func routesStatusAndTransportControls() {
        #expect(LocalControlServer.route(.init(method: "GET", path: "/")) == .webInterface)
        #expect(LocalControlServer.route(.init(method: "GET", path: "/remote")) == .webInterface)
        #expect(LocalControlServer.route(.init(method: "GET", path: "/status")) == .status)
        #expect(LocalControlServer.route(.init(method: "POST", path: "/play")) == .play)
        #expect(LocalControlServer.route(.init(method: "POST", path: "/pause")) == .pause)
        #expect(LocalControlServer.route(.init(method: "POST", path: "/play-pause")) == .playPause)
        #expect(LocalControlServer.route(.init(method: "POST", path: "/toggle")) == .playPause)
        #expect(LocalControlServer.route(.init(method: "POST", path: "/next")) == .next)
        #expect(LocalControlServer.route(.init(method: "POST", path: "/previous")) == .previous)
    }

    @Test("Routes check and request_approval")
    func routesDeviceVerification() {
        #expect(LocalControlServer.route(.init(method: "GET", path: "/check")) == .check)
        #expect(LocalControlServer.route(.init(method: "POST", path: "/request_approval")) == .requestApproval)
    }

    @Test("Routes volume from query and clamps value")
    func routesVolumeFromQueryAndClampsValue() {
        #expect(LocalControlServer.route(.init(
            method: "POST",
            path: "/volume",
            queryItems: ["value": "0.42"]
        )) == .volume(0.42))

        #expect(LocalControlServer.route(.init(
            method: "POST",
            path: "/volume",
            queryItems: ["value": "2"]
        )) == .volume(1))
    }

    @Test("Routes invalid requests to errors")
    func routesInvalidRequestsToErrors() {
        #expect(LocalControlServer.route(.init(method: "GET", path: "/missing")) == .notFound)
        #expect(LocalControlServer.route(.init(method: "DELETE", path: "/status")) == .methodNotAllowed)
        #expect(LocalControlServer.route(.init(method: "POST", path: "/volume")) == .badRequest("Missing numeric volume value"))
    }

    @Test("Parses raw HTTP request target and form body")
    func parsesRawHTTPRequest() throws {
        let raw = """
        POST /volume?level=0.3 HTTP/1.1\r
        Host: 127.0.0.1\r
        Authorization: Bearer secret\r
        Content-Type: application/x-www-form-urlencoded\r
        \r
        value=0.7
        """

        let request = try #require(LocalControlServer.HTTPRequest(data: Data(raw.utf8)))

        #expect(request.method == "POST")
        #expect(request.path == "/volume")
        #expect(request.headers["authorization"] == "Bearer secret")
        #expect(request.queryItems["level"] == "0.3")
        #expect(request.formItems["value"] == "0.7")
        #expect(LocalControlServer.route(request) == .volume(0.3))
    }

    @Test("Authorizes query form and bearer tokens")
    func authorizesTokenSources() {
        let manager = RemoteDeviceManager.shared
        manager.clearAll()

        let testToken = "mock-device-token-xyz"
        manager.approvedDevices = [
            RemoteDevice(
                deviceId: "test-device",
                name: "Test Phone",
                token: testToken,
                approvedAt: Date(),
                lastActive: Date()
            ),
        ]

        #expect(LocalControlServer.isAuthorized(.init(
            method: "GET",
            path: "/status",
            queryItems: ["token": testToken]
        )))
        #expect(LocalControlServer.isAuthorized(.init(
            method: "POST",
            path: "/next",
            headers: ["Authorization": "Bearer \(testToken)"]
        )))
        #expect(LocalControlServer.isAuthorized(.init(
            method: "POST",
            path: "/volume",
            formItems: ["token": testToken]
        )))
        #expect(!LocalControlServer.isAuthorized(.init(
            method: "GET",
            path: "/status",
            queryItems: ["token": "wrong"]
        )))
    }

    @Test("Track payload includes currently playing metadata")
    func trackPayloadIncludesMetadata() {
        let track = Song(
            id: "song-id",
            title: "A Song",
            artists: [Artist(id: "UCartist", name: "Artist")],
            album: Album(
                id: "MPREalbum",
                title: "Album",
                artists: nil,
                thumbnailURL: nil,
                year: nil,
                trackCount: nil
            ),
            duration: 123,
            thumbnailURL: URL(string: "https://example.com/art.jpg"),
            videoId: "video-id",
            isExplicit: true
        )

        let payload = LocalControlServer.trackPayload(track)

        #expect(payload["id"] as? String == "song-id")
        #expect(payload["videoId"] as? String == "video-id")
        #expect(payload["title"] as? String == "A Song")
        #expect(payload["artist"] as? String == "Artist")
        #expect(payload["artists"] as? [String] == ["Artist"])
        #expect(payload["album"] as? String == "Album")
        #expect(payload["artworkURL"] as? String == "https://example.com/art.jpg")
        #expect(payload["duration"] as? TimeInterval == 123)
        #expect(payload["isExplicit"] as? Bool == true)
    }

    @Test("HTTP response serializes JSON headers and body")
    func httpResponseSerializesJSON() throws {
        let response = LocalControlServer.HTTPResponse.json(["ok": true])
        let text = try #require(String(data: response.serialized(), encoding: .utf8))

        #expect(text.contains("HTTP/1.1 200 OK"))
        #expect(text.contains("Content-Type: application/json"))
        #expect(text.contains("\"ok\":true"))
    }

    @Test("Remote control HTML contains controls and elements")
    func remoteControlHTMLContainsControlsAndElements() {
        let html = LocalControlServer.remoteControlHTML()

        #expect(html.contains("Kaset Remote"))
        #expect(html.contains("Previous"))
        #expect(html.contains("Play/Pause"))
        #expect(html.contains("Next"))
    }

    @Test("Discovers local control URLs starting with localhost")
    func discoversLocalControlURLs() {
        let settings = SettingsManager.shared
        let originalLAN = settings.localControlServerAllowsLAN
        defer {
            settings.localControlServerAllowsLAN = originalLAN
        }
        settings.localControlServerAllowsLAN = true

        let urls = LocalControlServer.localControlURLs()
        #expect(!urls.isEmpty)
        #expect(urls[0].absoluteString == "http://127.0.0.1:\(settings.localControlServerPort)/")

        for url in urls {
            #expect(url.query == nil)
        }
    }
}
