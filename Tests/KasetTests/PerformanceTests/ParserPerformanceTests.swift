import XCTest
@testable import Kaset

final class ParserPerformanceTests: XCTestCase {
    func testHomeParsingPerformance() {
        let data = self.makeHomeResponseData(sectionCount: 10, itemsPerSection: 20)

        measure {
            _ = HomeResponseParser.parse(data)
        }
    }

    func testHomeSectionParsingPerformance() {
        let sectionData = self.makeCarouselSectionData(itemCount: 50)

        measure {
            _ = HomeResponseParser.parseHomeSection(sectionData)
        }
    }

    func testSearchParsingPerformance() {
        let data = self.makeSearchResponseData(songs: 20, albums: 10, artists: 10, playlists: 10)

        measure {
            _ = SearchResponseParser.parse(data)
        }
    }

    func testSearchSongsOnlyPerformance() {
        let data = self.makeSearchResponseData(songs: 100, albums: 0, artists: 0, playlists: 0)

        measure {
            _ = SearchResponseParser.parse(data)
        }
    }

    func testPlaylistDetailParsingPerformance() {
        let data = self.makePlaylistDetailData(trackCount: 100)

        measure {
            _ = PlaylistParser.parsePlaylistDetail(data, playlistId: "VLTestPlaylist")
        }
    }

    func testLibraryPlaylistsParsingPerformance() {
        let data = self.makeLibraryResponseData(playlistCount: 50)

        measure {
            _ = PlaylistParser.parseLibraryPlaylists(data)
        }
    }

    func testArtistDetailParsingPerformance() {
        let data = self.makeArtistDetailData(songCount: 50, albumCount: 20)

        measure {
            _ = ArtistParser.parseArtistDetail(data, artistId: "UCTestArtist")
        }
    }

    func testAccessibilityDurationFallbackPerformance() {
        let rows = self.makeAccessibilityDurationRows(count: 1000)
        _ = ParsingHelpers.extractDurationFromFlexColumns(rows[0])

        measure {
            var total: TimeInterval = 0
            for row in rows {
                total += ParsingHelpers.extractDurationFromFlexColumns(row) ?? 0
            }
            XCTAssertGreaterThan(total, 0)
        }
    }

    func testLRCParsingPerformance() {
        let raw = self.makeLRCData(lineCount: 600)
        XCTAssertNotNil(LRCParser.parse(raw))

        measure {
            XCTAssertNotNil(LRCParser.parse(raw))
        }
    }

    private func makeHomeResponseData(sectionCount: Int, itemsPerSection: Int) -> [String: Any] {
        var sections: [[String: Any]] = []

        for i in 0 ..< sectionCount {
            var items: [[String: Any]] = []
            for j in 0 ..< itemsPerSection {
                items.append([
                    "musicResponsiveListItemRenderer": [
                        "playlistItemData": ["videoId": "video\(i)_\(j)"],
                        "flexColumns": [
                            [
                                "musicResponsiveListItemFlexColumnRenderer": [
                                    "text": ["runs": [["text": "Song \(i)_\(j)"]]],
                                ],
                            ],
                            [
                                "musicResponsiveListItemFlexColumnRenderer": [
                                    "text": ["runs": [["text": "Artist \(i)"]]],
                                ],
                            ],
                        ],
                        "thumbnail": [
                            "musicThumbnailRenderer": [
                                "thumbnail": [
                                    "thumbnails": [
                                        ["url": "https://example.com/thumb\(i)_\(j).jpg"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ])
            }

            sections.append([
                "musicShelfRenderer": [
                    "title": ["runs": [["text": "Section \(i)"]]],
                    "contents": items,
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
                                    "contents": sections,
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeCarouselSectionData(itemCount: Int) -> [String: Any] {
        var items: [[String: Any]] = []

        for i in 0 ..< itemCount {
            items.append([
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Album \(i)"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": [
                            "browseId": "MPRE\(i)",
                            "browseEndpointContextSupportedConfigs": [
                                "browseEndpointContextMusicConfig": [
                                    "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                                ],
                            ],
                        ],
                    ],
                    "thumbnail": [
                        "musicThumbnailRenderer": [
                            "thumbnail": [
                                "thumbnails": [
                                    ["url": "https://example.com/album\(i).jpg"],
                                ],
                            ],
                        ],
                    ],
                    "subtitle": ["runs": [["text": "Artist \(i)"]]],
                ],
            ])
        }

        return [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "New Releases"]]],
                    ],
                ],
                "contents": items,
            ],
        ]
    }

    private func makeSearchResponseData(songs: Int, albums: Int, artists: Int, playlists: Int) -> [String: Any] {
        var contents: [[String: Any]] = []

        if songs > 0 {
            contents.append(["musicShelfRenderer": ["contents": self.makeSongItems(count: songs)]])
        }
        if albums > 0 {
            contents.append(["musicShelfRenderer": ["contents": self.makeAlbumItems(count: albums)]])
        }
        if artists > 0 {
            contents.append(["musicShelfRenderer": ["contents": self.makeArtistItems(count: artists)]])
        }
        if playlists > 0 {
            contents.append(["musicShelfRenderer": ["contents": self.makePlaylistItems(count: playlists)]])
        }

        return [
            "contents": [
                "tabbedSearchResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": contents,
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeSongItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song \(i)"]]]]],
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist \(i)"]]]]],
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Album \(i)"]]]]],
                    ],
                    "thumbnail": [
                        "musicThumbnailRenderer": [
                            "thumbnail": [
                                "thumbnails": [["url": "https://example.com/song\(i).jpg"]],
                            ],
                        ],
                    ],
                ],
            ]
        }
    }

    private func makeAlbumItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "MPRE\(i)"]],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Album \(i)"]]]]],
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist \(i)"]]]]],
                    ],
                ],
            ]
        }
    }

    private func makeArtistItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UC\(i)"]],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist \(i)"]]]]],
                    ],
                ],
            ]
        }
    }

    private func makePlaylistItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "VL\(i)"]],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Playlist \(i)"]]]]],
                    ],
                ],
            ]
        }
    }

    private func makePlaylistDetailData(trackCount: Int) -> [String: Any] {
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
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Album \(i)"]]],
                            ],
                        ],
                    ],
                    "thumbnail": [
                        "musicThumbnailRenderer": [
                            "thumbnail": [
                                "thumbnails": [["url": "https://example.com/track\(i).jpg"]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        return [
            "header": [
                "musicDetailHeaderRenderer": [
                    "title": ["runs": [["text": "Test Playlist"]]],
                    "description": ["runs": [["text": "A performance test playlist"]]],
                    "subtitle": ["runs": [["text": "Test User"]]],
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

    private func makeLibraryResponseData(playlistCount: Int) -> [String: Any] {
        var items: [[String: Any]] = []

        for i in 0 ..< playlistCount {
            items.append([
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Playlist \(i)"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "VL\(i)"],
                    ],
                    "thumbnail": [
                        "musicThumbnailRenderer": [
                            "thumbnail": [
                                "thumbnails": [["url": "https://example.com/playlist\(i).jpg"]],
                            ],
                        ],
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

    private func makeArtistDetailData(songCount: Int, albumCount: Int) -> [String: Any] {
        var songItems: [[String: Any]] = []
        for i in 0 ..< songCount {
            songItems.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Song \(i)"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Test Artist"]]],
                            ],
                        ],
                    ],
                    "thumbnail": [
                        "musicThumbnailRenderer": [
                            "thumbnail": [
                                "thumbnails": [["url": "https://example.com/song\(i).jpg"]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        var albumItems: [[String: Any]] = []
        for i in 0 ..< albumCount {
            albumItems.append([
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Album \(i)"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": [
                            "browseId": "MPRE\(i)",
                        ],
                    ],
                    "subtitle": ["runs": [["text": "2024"]]],
                    "thumbnail": [
                        "musicThumbnailRenderer": [
                            "thumbnail": [
                                "thumbnails": [["url": "https://example.com/album\(i).jpg"]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        return [
            "header": [
                "musicImmersiveHeaderRenderer": [
                    "title": ["runs": [["text": "Test Artist"]]],
                    "description": ["runs": [["text": "A test artist for performance testing"]]],
                    "thumbnail": [
                        "musicThumbnailRenderer": [
                            "thumbnail": [
                                "thumbnails": [["url": "https://example.com/artist.jpg"]],
                            ],
                        ],
                    ],
                    "subscriptionButton": [
                        "subscribeButtonRenderer": [
                            "channelId": "UCTestArtist",
                            "subscribed": false,
                            "subscriberCountText": ["runs": [["text": "1M subscribers"]]],
                        ],
                    ],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "musicShelfRenderer": [
                                                "title": ["runs": [["text": "Songs"]]],
                                                "contents": songItems,
                                            ],
                                        ],
                                        [
                                            "musicCarouselShelfRenderer": [
                                                "header": [
                                                    "musicCarouselShelfBasicHeaderRenderer": [
                                                        "title": ["runs": [["text": "Albums"]]],
                                                    ],
                                                ],
                                                "contents": albumItems,
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeAccessibilityDurationRows(count: Int) -> [[String: Any]] {
        (0 ..< count).map { index in
            [
                "overlay": [
                    "musicItemThumbnailOverlayRenderer": [
                        "content": [
                            "musicPlayButtonRenderer": [
                                "accessibilityPlayData": [
                                    "accessibilityData": [
                                        "label": "Play Benchmark Song \(index), \((index % 5) + 1) minutes, \((index % 50) + 1) seconds",
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ]
        }
    }

    private func makeLRCData(lineCount: Int) -> String {
        var lines = [
            "[ar:Benchmark Artist]",
            "[ti:Benchmark Song]",
            "[offset:125]",
        ]
        lines.reserveCapacity(lineCount + lines.count)

        for index in 0 ..< lineCount {
            let minute = index / 60
            let second = index % 60
            let centisecond = index % 100
            if index.isMultiple(of: 3) {
                lines.append(String(
                    format: "[%02d:%02d.%02d]<%02d:%02d.%02d>word%d <%02d:%02d.%02d>line%d",
                    minute,
                    second,
                    centisecond,
                    minute,
                    second,
                    centisecond,
                    index,
                    minute,
                    min(59, second + 1),
                    centisecond,
                    index
                ))
            } else {
                lines.append(String(format: "[%02d:%02d.%02d]Benchmark lyric line %d", minute, second, centisecond, index))
            }
        }

        return lines.joined(separator: "\n")
    }
}
