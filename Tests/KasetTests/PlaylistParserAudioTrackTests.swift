import Foundation
import Testing
@testable import Kaset

/// Tests for resolving the audio recording behind music-video album rows.
///
/// Some albums are returned with every track row typed `MUSIC_VIDEO_TYPE_OMV`.
/// YouTube Music still advertises each track's audio recording in the row's
/// credits menu, as `MPTC` + the audio video ID.
@Suite(.tags(.parser))
struct PlaylistParserAudioTrackTests {
    // MARK: - Parser

    @Test("Music-video album rows expose the audio recording from their credits entry")
    func musicVideoRowResolvesAudioTrackVideoId() {
        let data = self.makeAlbumData(rows: [
            .init(videoId: "gQlMMD8auMs", title: "Pink Venom", creditsBrowseId: "MPTCqCDPprTDkJE"),
            .init(videoId: "POe9SOEKotk", title: "Shut Down", creditsBrowseId: "MPTC950BdJKBhGo"),
        ])

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "MPREb_J7wVS5GlYZK")

        #expect(detail.tracks.map(\.videoId) == ["gQlMMD8auMs", "POe9SOEKotk"])
        #expect(detail.tracks.map(\.audioTrackVideoId) == ["qCDPprTDkJE", "950BdJKBhGo"])
        #expect(detail.tracks.allSatisfy { $0.musicVideoType == .omv })
    }

    @Test("Audio rows whose credits entry repeats the row ID carry no separate audio ID")
    func audioRowHasNoSeparateAudioTrackVideoId() {
        let data = self.makeAlbumData(rows: [
            .init(
                videoId: "qCDPprTDkJE",
                title: "Pink Venom",
                creditsBrowseId: "MPTCqCDPprTDkJE",
                musicVideoType: "MUSIC_VIDEO_TYPE_ATV"
            ),
        ])

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "MPREb_Wbh7z3ktrMG")

        #expect(detail.tracks.first?.audioTrackVideoId == nil)
        #expect(detail.tracks.first?.musicVideoType == .atv)
    }

    @Test("Rows without a credits entry parse without an audio ID")
    func rowWithoutCreditsMenuParses() {
        let data = self.makeAlbumData(rows: [
            .init(videoId: "gQlMMD8auMs", title: "Pink Venom", creditsBrowseId: nil),
        ])

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "MPREb_J7wVS5GlYZK")

        #expect(detail.tracks.count == 1)
        #expect(detail.tracks.first?.audioTrackVideoId == nil)
    }

    // MARK: - Helper

    @Test("Credits entries are matched by page type, not by menu label")
    func creditsEntryMatchedByPageTypeUnderAnyLanguage() {
        let renderer = Self.makeRowRenderer(
            videoId: "gQlMMD8auMs",
            title: "Pink Venom",
            creditsBrowseId: "MPTCqCDPprTDkJE",
            creditsLabel: "Songwriter-Credits anzeigen"
        )

        #expect(ParsingHelpers.extractTrackCreditsVideoId(from: renderer) == "qCDPprTDkJE")
    }

    @Test("Browse IDs that are not track credits are ignored")
    func nonCreditsBrowseIdsAreIgnored() {
        let renderer: [String: Any] = [
            "menu": [
                "menuRenderer": [
                    "items": [[
                        "menuNavigationItemRenderer": [
                            "text": ["runs": [["text": "Go to artist"]]],
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": "UCkbbMCA40i18i7UdjayMPAg",
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_ARTIST",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]

        #expect(ParsingHelpers.extractTrackCreditsVideoId(from: renderer) == nil)
    }

    // MARK: - Model

    @Test("Preferred audio video ID falls back to the row's own video ID")
    func preferredAudioVideoIdFallsBack() {
        let musicVideoRow = Song(
            id: "gQlMMD8auMs",
            title: "Pink Venom",
            artists: [],
            videoId: "gQlMMD8auMs",
            audioTrackVideoId: "qCDPprTDkJE"
        )
        let audioRow = Song(
            id: "qCDPprTDkJE",
            title: "Pink Venom",
            artists: [],
            videoId: "qCDPprTDkJE"
        )

        #expect(musicVideoRow.preferredAudioVideoId == "qCDPprTDkJE")
        #expect(audioRow.preferredAudioVideoId == "qCDPprTDkJE")
    }

    // MARK: - Fixtures

    private struct Row {
        let videoId: String
        let title: String
        let creditsBrowseId: String?
        var musicVideoType: String = "MUSIC_VIDEO_TYPE_OMV"
    }

    private func makeAlbumData(rows: [Row]) -> [String: Any] {
        let contents = rows.map { row in
            [
                "musicResponsiveListItemRenderer": Self.makeRowRenderer(
                    videoId: row.videoId,
                    title: row.title,
                    creditsBrowseId: row.creditsBrowseId,
                    musicVideoType: row.musicVideoType
                ),
            ]
        }

        return [
            "header": [
                "musicDetailHeaderRenderer": [
                    "title": ["runs": [["text": "BORN PINK"]]],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": contents,
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

    private static func makeRowRenderer(
        videoId: String,
        title: String,
        creditsBrowseId: String?,
        musicVideoType: String = "MUSIC_VIDEO_TYPE_OMV",
        creditsLabel: String = "View song credits"
    ) -> [String: Any] {
        // Album rows carry no top-level navigationEndpoint; the play overlay holds
        // the watch endpoint, matching live `browse` responses for MPRE albums.
        var renderer: [String: Any] = [
            "playlistItemData": ["videoId": videoId],
            "overlay": [
                "musicItemThumbnailOverlayRenderer": [
                    "content": [
                        "musicPlayButtonRenderer": [
                            "playNavigationEndpoint": [
                                "watchEndpoint": [
                                    "videoId": videoId,
                                    "watchEndpointMusicSupportedConfigs": [
                                        "watchEndpointMusicConfig": [
                                            "musicVideoType": musicVideoType,
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "flexColumns": [
                [
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": title]]],
                    ],
                ],
                [
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": "BLACKPINK"]]],
                    ],
                ],
            ],
        ]

        if let creditsBrowseId {
            renderer["menu"] = [
                "menuRenderer": [
                    "items": [[
                        "menuNavigationItemRenderer": [
                            "text": ["runs": [["text": creditsLabel]]],
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": creditsBrowseId,
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_TRACK_CREDITS",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]],
                ],
            ]
        }

        return renderer
    }
}
