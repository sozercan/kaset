import Foundation
import Testing
@testable import Kaset

/// Tests for the PlaylistParser.
@Suite("PlaylistParser", .tags(.parser))
struct PlaylistParserTests {
    // MARK: - Library Playlists

    @Test("Parse empty library playlists response")
    func parseLibraryPlaylistsEmpty() {
        let data: [String: Any] = [:]
        let playlists = PlaylistParser.parseLibraryPlaylists(data)
        #expect(playlists.isEmpty)
    }

    @Test("Parse library playlists from grid")
    func parseLibraryPlaylistsFromGrid() {
        let data = self.makeLibraryResponseData(playlistCount: 3)
        let playlists = PlaylistParser.parseLibraryPlaylists(data)
        #expect(playlists.count == 3)
    }

    // MARK: - Playlist Detail

    @Test("Parse playlist detail with header")
    func parsePlaylistDetailWithMusicDetailHeader() {
        let data = self.makePlaylistDetailData(
            title: "My Playlist",
            description: "A great playlist",
            author: "Test User",
            trackCount: 5
        )

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL123")

        #expect(detail.id == "VL123")
        #expect(detail.title == "My Playlist")
        #expect(detail.description == "A great playlist")
        #expect(detail.author == "Test User")
        #expect(detail.tracks.count == 5)
    }

    @Test("Parse playlist detail tracks")
    func parsePlaylistDetailWithTracks() {
        let data = self.makePlaylistDetailData(
            title: "Track Test",
            description: nil,
            author: nil,
            trackCount: 3
        )

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL456")

        #expect(detail.tracks.count == 3)
        #expect(detail.tracks[0].title == "Track 0")
        #expect(detail.tracks[0].videoId == "video0")
    }

    @Test("Parse empty playlist detail")
    func parsePlaylistDetailEmpty() {
        let data: [String: Any] = [:]
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL789")

        #expect(detail.id == "VL789")
        #expect(detail.title == "Unknown Playlist")
        #expect(detail.tracks.isEmpty)
    }

    // MARK: - Album Detection

    @Test(
        "Album detection based on ID prefix",
        arguments: [
            ("MPRE12345", true), // Album prefix
            ("VL12345", false), // Playlist prefix
            ("OLAK12345", true), // Another album prefix
            ("RDCLAK", false), // Radio prefix
        ]
    )
    func isAlbumDetection(playlistId: String, expectedIsAlbum: Bool) {
        let data = self.makePlaylistDetailData(title: "Test", description: nil, author: nil, trackCount: 1)
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: playlistId)
        #expect(detail.isAlbum == expectedIsAlbum)
    }

    // MARK: - Continuation Parsing

    @Test("Parse 2025 continuation format with onResponseReceivedActions")
    func parsePlaylistContinuation2025Format() {
        // Create mock 2025 continuation response format
        var continuationItems: [[String: Any]] = []

        for i in 0 ..< 5 {
            continuationItems.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "cont_video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Continuation Track \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        // Add continuation token at the end (for next page)
        continuationItems.append([
            "continuationItemRenderer": [
                "continuationEndpoint": [
                    "continuationCommand": [
                        "token": "next_page_token_123",
                    ],
                ],
            ],
        ])

        let data: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": continuationItems,
                ],
            ]],
        ]

        let response = PlaylistParser.parsePlaylistContinuation(data)

        #expect(response.tracks.count == 5)
        #expect(response.tracks[0].title == "Continuation Track 0")
        #expect(response.tracks[0].videoId == "cont_video0")
        #expect(response.hasMore == true)
        #expect(response.continuationToken == "next_page_token_123")
    }

    @Test("Parse 2025 continuation format without next token")
    func parsePlaylistContinuation2025FormatNoNextToken() {
        var continuationItems: [[String: Any]] = []

        for i in 0 ..< 3 {
            continuationItems.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "final_video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Final Track \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        // No continuationItemRenderer at the end - this is the last page

        let data: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": continuationItems,
                ],
            ]],
        ]

        let response = PlaylistParser.parsePlaylistContinuation(data)

        #expect(response.tracks.count == 3)
        #expect(response.hasMore == false)
        #expect(response.continuationToken == nil)
    }

    // MARK: - Helpers

    private func makeLibraryResponseData(playlistCount: Int) -> [String: Any] {
        var items: [[String: Any]] = []

        for i in 0 ..< playlistCount {
            items.append([
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Playlist \(i)"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "VL\(i)"],
                    ],
                ],
            ])
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "gridRenderer": [
                                            "items": items,
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makePlaylistDetailData(
        title: String,
        description: String?,
        author: String?,
        trackCount: Int
    ) -> [String: Any] {
        var tracks: [[String: Any]] = []

        for i in 0 ..< trackCount {
            tracks.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Track \(i)"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Artist \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        var headerRenderer: [String: Any] = [
            "title": ["runs": [["text": title]]],
        ]

        if let desc = description {
            headerRenderer["description"] = ["runs": [["text": desc]]]
        }

        if let auth = author {
            headerRenderer["subtitle"] = ["runs": [["text": auth]]]
        }

        return [
            "header": [
                "musicDetailHeaderRenderer": headerRenderer,
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": tracks,
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }
}
