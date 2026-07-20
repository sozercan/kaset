import Foundation

// MARK: - Search Response Parser Test Fixtures

extension SearchResponseParserTests {
    static func loadFixture(_ name: String) throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw FixtureError.notFound(name)
        }
        let raw = try Data(contentsOf: url)
        guard let fixture = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw FixtureError.invalidJSON(name)
        }
        return fixture
    }

    enum FixtureError: Error { case notFound(String), invalidJSON(String) }

    static func makeLocalizedSemanticData() -> [String: Any] {
        [
            "contents": [
                "sectionListRenderer": [
                    "contents": [
                        [
                            "musicCardShelfRenderer": [
                                "title": [
                                    "runs": [["text": "Vídeo localizado"]],
                                ],
                                "subtitle": [
                                    "runs": [
                                        ["text": "Vídeo"],
                                        ["text": " • "],
                                        ["text": "Banda Ejemplo"],
                                    ],
                                ],
                                "onTap": [
                                    "watchEndpoint": [
                                        "videoId": "localized-video",
                                    ],
                                ],
                            ],
                        ],
                        [
                            "musicResponsiveListItemRenderer": [
                                "navigationEndpoint": [
                                    "browseEndpoint": [
                                        "browseId": "MPSPPlocalized-show",
                                    ],
                                ],
                                "flexColumns": [
                                    [
                                        "musicResponsiveListItemFlexColumnRenderer": [
                                            "text": [
                                                "runs": [["text": "Localized Podcast"]],
                                            ],
                                        ],
                                    ],
                                    [
                                        "musicResponsiveListItemFlexColumnRenderer": [
                                            "text": [
                                                "runs": [
                                                    ["text": "Подкаст"],
                                                    ["text": " • "],
                                                    ["text": "Fixture Network"],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    static func makeCountOnlyCreatorData(
        playlistLabel: String = "Playlist",
        songCount: String = "12 songs",
        podcastLabel: String = "Podcast",
        episodeCount: String = "12 episodes"
    ) -> [String: Any] {
        [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "itemSectionRenderer": [
                            "contents": [
                                [
                                    "musicResponsiveListItemRenderer": [
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "PLcount-only",
                                            ],
                                        ],
                                        "flexColumns": [
                                            [
                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                    "text": [
                                                        "runs": [["text": "Count-only Playlist"]],
                                                    ],
                                                ],
                                            ],
                                            [
                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                    "text": [
                                                        "runs": [
                                                            ["text": playlistLabel],
                                                            ["text": " • "],
                                                            ["text": songCount],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                                [
                                    "musicResponsiveListItemRenderer": [
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "MPSPPcount-only",
                                            ],
                                        ],
                                        "flexColumns": [
                                            [
                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                    "text": [
                                                        "runs": [["text": "Count-only Podcast"]],
                                                    ],
                                                ],
                                            ],
                                            [
                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                    "text": [
                                                        "runs": [
                                                            ["text": podcastLabel],
                                                            ["text": " • "],
                                                            ["text": episodeCount],
                                                        ],
                                                    ],
                                                ],
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

    static func makeRadioBrowseData(browseIds: [String]) -> [String: Any] {
        [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "itemSectionRenderer": [
                            "contents": browseIds.enumerated().map { index, browseId in
                                [
                                    "musicResponsiveListItemRenderer": [
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": browseId,
                                            ],
                                        ],
                                        "flexColumns": [
                                            [
                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                    "text": [
                                                        "runs": [["text": "Radio \(index)"]],
                                                    ],
                                                ],
                                            ],
                                            [
                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                    "text": [
                                                        "runs": [["text": "Playlist"]],
                                                    ],
                                                ],
                                            ],
                                        ],
                                        "overlay": [
                                            "musicItemThumbnailOverlayRenderer": [
                                                "content": [
                                                    "musicPlayButtonRenderer": [
                                                        "playNavigationEndpoint": [
                                                            "watchEndpoint": [
                                                                "videoId": "radio-preview-\(index)",
                                                                "watchEndpointMusicSupportedConfigs": [
                                                                    "watchEndpointMusicConfig": [
                                                                        "musicVideoType": "MUSIC_VIDEO_TYPE_UGC",
                                                                    ],
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ]
                            },
                        ],
                    ]],
                ],
            ],
        ]
    }

    static func makeSecondSubtitleVideoData() -> [String: Any] {
        [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "itemSectionRenderer": [
                            "contents": [[
                                "musicMultiRowListItemRenderer": [
                                    "title": ["runs": [["text": "Second Subtitle Video"]]],
                                    "subtitle": ["runs": [["text": "Fixture Creator"]]],
                                    "secondSubtitle": ["runs": [["text": "Video"]]],
                                    "onTap": [
                                        "watchEndpoint": ["videoId": "second-subtitle-video"],
                                    ],
                                ],
                            ]],
                        ],
                    ]],
                ],
            ],
        ]
    }

    static func makeUntypedVideoCardData(artists: [String]) -> [String: Any] {
        [
            "contents": [
                "sectionListRenderer": [
                    "contents": artists.enumerated().map { index, artist in
                        [
                            "musicCardShelfRenderer": [
                                "title": [
                                    "runs": [["text": "Video \(index)"]],
                                ],
                                "subtitle": [
                                    "runs": [
                                        ["text": "Video"],
                                        ["text": " • "],
                                        ["text": artist],
                                    ],
                                ],
                                "onTap": [
                                    "watchEndpoint": [
                                        "videoId": "untyped-video-\(index)",
                                    ],
                                ],
                            ],
                        ]
                    },
                ],
            ],
        ]
    }

    static func makeRelativeDateEpisodeData(
        showTitle: String = "Fixture Podcast",
        showBrowseId: String? = "MPSPPrelative-date",
        publishedDate: String = "2 hours ago",
        duration: String = "36 min"
    ) -> [String: Any] {
        var showRun: [String: Any] = ["text": showTitle]
        if let showBrowseId {
            showRun["navigationEndpoint"] = [
                "browseEndpoint": ["browseId": showBrowseId],
            ]
        }

        return [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "itemSectionRenderer": [
                            "contents": [[
                                "musicResponsiveListItemRenderer": [
                                    "navigationEndpoint": [
                                        "watchEndpoint": [
                                            "videoId": "relative-date-episode",
                                            "watchEndpointMusicSupportedConfigs": [
                                                "watchEndpointMusicConfig": [
                                                    "musicVideoType": "MUSIC_VIDEO_TYPE_PODCAST_EPISODE",
                                                ],
                                            ],
                                        ],
                                    ],
                                    "flexColumns": [
                                        [
                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                "text": [
                                                    "runs": [[
                                                        "text": "Relative Date Episode",
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": [
                                                                "browseId": "MPEDrelative-date",
                                                            ],
                                                        ],
                                                    ]],
                                                ],
                                            ],
                                        ],
                                        [
                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                "text": [
                                                    "runs": [
                                                        ["text": "Episode"],
                                                        ["text": " • "],
                                                        showRun,
                                                        ["text": " • "],
                                                        ["text": publishedDate],
                                                        ["text": " • "],
                                                        ["text": duration],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ]],
                        ],
                    ]],
                ],
            ],
        ]
    }

    static func makeContinuationCarrierData(_ continuation: [String: Any]) -> [String: Any] {
        [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "musicShelfRenderer": [
                            "contents": [],
                            "continuations": [continuation],
                        ],
                    ]],
                ],
            ],
        ]
    }

    static func makeContinuationItemData(token: String) -> [String: Any] {
        [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "musicShelfRenderer": [
                            "contents": [[
                                "continuationItemRenderer": [
                                    "continuationEndpoint": [
                                        "continuationCommand": [
                                            "token": token,
                                        ],
                                    ],
                                ],
                            ]],
                        ],
                    ]],
                ],
            ],
        ]
    }

    func makeSearchResponseData(songs: Int, albums: Int, artists: Int, playlists: Int) -> [String: Any] {
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

    func makeSongItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song \(i)"]]]]],
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist"]]]]],
                    ],
                ],
            ]
        }
    }

    func makeAlbumItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "MPRE\(i)"]],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Album \(i)"]]]]],
                    ],
                ],
            ]
        }
    }

    func makeArtistItems(count: Int) -> [[String: Any]] {
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

    func makePlaylistItems(count: Int) -> [[String: Any]] {
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
}
