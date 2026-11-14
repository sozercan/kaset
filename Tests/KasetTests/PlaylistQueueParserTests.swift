import Testing
@testable import Kaset

@Suite(.tags(.parser))
struct PlaylistQueueParserTests {
    @Test("Curated playlist queues preserve linked artists from long bylines", arguments: [false, true])
    func preservesLinkedArtists(wrapped: Bool) throws {
        // Shapes observed in Chill R&B and Country Summer via music/get_queue.
        // The short bylines are display-only, and the long bylines carry artist links.
        let chill: [String: Any] = [
            "videoId": "chill-track",
            "title": ["runs": [["text": "Chill Track"]]],
            "shortBylineText": ["runs": [["text": "COLORS & Tems"]]],
            "longBylineText": [
                "runs": [
                    Self.artistRun(name: "COLORS", id: "UC-colors"),
                    ["text": " & "],
                    Self.artistRun(name: "Tems", id: "UC-tems"),
                    ["text": " • "],
                    ["text": "12M views"],
                    ["text": " • "],
                    ["text": "191K likes"],
                ],
            ],
        ]
        let country: [String: Any] = [
            "videoId": "country-track",
            "title": ["runs": [["text": "Country Track"]]],
            "shortBylineText": ["runs": [["text": "Ella Langley"]]],
            "longBylineText": [
                "runs": [
                    Self.artistRun(name: "Ella Langley", id: "UC-ella-langley"),
                    ["text": " • "],
                    ["text": "79M views"],
                    ["text": " • "],
                    ["text": "690K likes"],
                ],
            ],
        ]

        let tracks = PlaylistParser.parseQueueTracks([
            "queueDatas": [
                Self.queueItem(chill, wrapped: wrapped),
                Self.queueItem(country, wrapped: wrapped),
            ],
        ])

        #expect(tracks.map(\.videoId) == ["chill-track", "country-track"])
        let chillTrack = try #require(tracks.first)
        #expect(chillTrack.artists.map(\.name) == ["COLORS", "Tems"])
        #expect(chillTrack.artists.map(\.id) == ["UC-colors", "UC-tems"])
        #expect(chillTrack.artists.map(\.hasNavigableId) == [true, true])
        let countryTrack = try #require(tracks.last)
        #expect(countryTrack.artists.map(\.name) == ["Ella Langley"])
        #expect(countryTrack.artists.map(\.id) == ["UC-ella-langley"])
        #expect(countryTrack.artists.map(\.hasNavigableId) == [true])
    }

    @Test("Queue artists fall back to short bylines when long bylines are absent or empty", arguments: [false, true])
    func fallsBackToShortByline(emptyLongByline: Bool) throws {
        var renderer: [String: Any] = [
            "videoId": "short-byline-track",
            "shortBylineText": ["runs": [Self.artistRun(name: "Short Artist", id: "UC-short")]],
        ]
        if emptyLongByline {
            renderer["longBylineText"] = ["runs": [] as [[String: Any]]]
        }

        let tracks = PlaylistParser.parseQueueTracks(["queueDatas": [Self.queueItem(renderer)]])

        let track = try #require(tracks.first)
        #expect(track.artists.map(\.name) == ["Short Artist"])
        #expect(track.artists.map(\.id) == ["UC-short"])
        #expect(track.artists.map(\.hasNavigableId) == [true])
    }

    @Test("Queue artists preserve plain short bylines without inventing navigation")
    func preservesPlainShortByline() throws {
        let renderer: [String: Any] = [
            "videoId": "plain-byline-track",
            "shortBylineText": ["runs": [["text": "Plain Artist"]]],
        ]

        let tracks = PlaylistParser.parseQueueTracks(["queueDatas": [Self.queueItem(renderer)]])

        let track = try #require(tracks.first)
        #expect(track.artists.map(\.name) == ["Plain Artist"])
        #expect(track.artists.allSatisfy { !$0.hasNavigableId })
    }

    @Test("Queue artists preserve the unknown artist fallback when both bylines are missing")
    func preservesUnknownArtistFallback() throws {
        let renderer: [String: Any] = ["videoId": "unknown-artist-track"]

        let tracks = PlaylistParser.parseQueueTracks(["queueDatas": [Self.queueItem(renderer)]])

        let track = try #require(tracks.first)
        #expect(track.artists.map(\.name) == ["Unknown Artist"])
        #expect(track.artists.allSatisfy { !$0.hasNavigableId })
    }

    private static func artistRun(name: String, id: String) -> [String: Any] {
        [
            "text": name,
            "navigationEndpoint": ["browseEndpoint": ["browseId": id]],
        ]
    }

    private static func queueItem(_ renderer: [String: Any], wrapped: Bool = false) -> [String: Any] {
        let content: [String: Any] = if wrapped {
            [
                "playlistPanelVideoWrapperRenderer": [
                    "primaryRenderer": ["playlistPanelVideoRenderer": renderer],
                ],
            ]
        } else {
            ["playlistPanelVideoRenderer": renderer]
        }
        return ["content": content]
    }
}
