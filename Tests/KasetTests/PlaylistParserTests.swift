// swiftlint:disable file_length
import Foundation
import Testing
@testable import Kaset

/// Tests for the PlaylistParser.
@Suite(.tags(.parser))
struct PlaylistParserTests { // swiftlint:disable:this type_body_length
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

    @Test("Merge dedicated library playlists preserves order and appends landing-only items")
    func mergedLibraryPlaylistsPreservesDedicatedOrderAndLandingOnlyItems() {
        let createdPlaylist = Playlist(
            id: "PLCREATED",
            title: "New Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil
        )
        let savedPlaylist = Playlist(
            id: "VLPLSAVED",
            title: "Saved Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil
        )
        let landingOnlyPlaylist = Playlist(
            id: "VLLANDINGONLY",
            title: "Landing Only",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil
        )

        let playlists = PlaylistParser.mergedLibraryPlaylists(
            dedicated: [createdPlaylist, savedPlaylist],
            fallback: [landingOnlyPlaylist]
        )

        #expect(playlists.map(\.id) == ["PLCREATED", "VLPLSAVED", "VLLANDINGONLY"])
    }

    @Test("Merge dedicated library playlists deduplicates VL-prefixed landing IDs")
    func mergedLibraryPlaylistsDeduplicatesVLPrefixedLandingIDs() {
        let dedicatedPlaylist = Playlist(
            id: "PLCREATED",
            title: "Dedicated Title",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil
        )
        let fallbackDuplicate = Playlist(
            id: "VLPLCREATED",
            title: "Fallback Title",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil
        )

        let playlists = PlaylistParser.mergedLibraryPlaylists(
            dedicated: [dedicatedPlaylist],
            fallback: [fallbackDuplicate]
        )

        #expect(playlists.count == 1)
        #expect(playlists[0].id == "PLCREATED")
        #expect(playlists[0].title == "Dedicated Title")
    }

    @Test("Merge dedicated saved albums preserves order and removes fallback duplicates")
    func mergedLibraryAlbumsPreservesDedicatedOrder() {
        let dedicatedAlbum = TestFixtures.makeAlbum(id: "MPRE-dedicated", title: "Dedicated Album")
        let fallbackDuplicate = TestFixtures.makeAlbum(id: "MPRE-dedicated", title: "Fallback Title")
        let fallbackOnlyAlbum = TestFixtures.makeAlbum(id: "MPRE-fallback", title: "Fallback Album")

        let albums = PlaylistParser.mergedLibraryAlbums(
            dedicated: [dedicatedAlbum],
            fallback: [fallbackDuplicate, fallbackOnlyAlbum]
        )

        #expect(albums.map(\.id) == ["MPRE-dedicated", "MPRE-fallback"])
        #expect(albums.map(\.title) == ["Dedicated Album", "Fallback Album"])
    }

    @Test("Parse library playlist delete eligibility")
    func parseLibraryPlaylistDeleteEligibility() {
        let data: [String: Any] = [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "gridRenderer": [
                                            "items": [
                                                [
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Owned Playlist"]]],
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "VL-owned"],
                                                        ],
                                                        "menu": [
                                                            "menuRenderer": [
                                                                "items": [[
                                                                    "menuNavigationItemRenderer": [
                                                                        "navigationEndpoint": [
                                                                            "deletePlaylistEndpoint": [
                                                                                "playlistId": "VL-owned",
                                                                            ],
                                                                        ],
                                                                    ],
                                                                ]],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                                [
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Saved Playlist"]]],
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "VL-saved"],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]

        let playlists = PlaylistParser.parseLibraryPlaylists(data)

        #expect(playlists.count == 2)
        #expect(playlists[0].canDelete == true)
        #expect(playlists[1].canDelete == false)
    }

    @Test("Parse mixed library content from grid and responsive shelf")
    func parseLibraryContentFromGridAndResponsiveShelf() {
        let data = self.makeMixedLibraryContentResponseData()
        let content = PlaylistParser.parseLibraryContent(data)

        #expect(content.playlists.map(\.id) == ["VLGRID123", "VLSHELF456"])
        #expect(content.playlists.map(\.title) == ["Grid Playlist", "Shelf Playlist"])
        #expect(content.playlists.map(\.author?.name) == ["Grid Curator", "Shelf Curator"])

        #expect(content.albums.map(\.id) == ["MPREGRIDALBUM123", "MPRESHELFALBUM456"])
        #expect(content.albums.map(\.title) == ["Grid Album", "Shelf Album"])
        #expect(content.albums.map(\.artistsDisplay) == ["Grid Album Artist", "Shelf Album Artist"])
        #expect(content.albums.map(\.year) == ["2024", "2023"])
        #expect(content.albums.map(\.libraryTargetId) == ["OLAKGRIDALBUM123", "OLAKSHELFALBUM456"])

        #expect(content.artists.map(\.id) == ["MPLAUCGRIDARTIST123", "MPLAUCSHELFARTIST456"])
        #expect(content.artists.map(\.name) == ["Grid Artist", "Shelf Artist"])

        #expect(content.podcastShows.map(\.id) == ["MPSPPGRID123", "MPSPPSHELF456"])
        #expect(content.podcastShows.map(\.title) == ["Grid Podcast", "Shelf Podcast"])
        #expect(content.podcastShows.map(\.author) == ["Grid Host", "Shelf Host"])

        let page = PlaylistParser.parseLibraryAlbumsPage(data)
        #expect(page.albums == content.albums)

        let dedicatedAlbums = PlaylistParser.parseLibraryAlbums(data)
        #expect(dedicatedAlbums == content.albums)
    }

    @Test("Parse saved albums from both grid and shelf sections")
    func parseLibraryAlbumsPageFromGridAndShelf() {
        let page = PlaylistParser.parseLibraryAlbumsPage(
            self.makeLibraryAlbumsGridAndShelfData()
        )

        #expect(page.albums.map(\.id) == ["MPREGRIDALBUM789", "MPRESHELFALBUM456"])
        #expect(page.isRecognized)
    }

    @Test("Parse initial saved albums page with continuation token")
    func parseLibraryAlbumsPage() {
        let page = PlaylistParser.parseLibraryAlbumsPage(
            self.makeLibraryAlbumsPageData(
                albumID: "MPREINITIAL123",
                title: "Initial Album",
                continuationToken: "albums-page-2"
            )
        )

        #expect(page.albums.map(\.id) == ["MPREINITIAL123"])
        #expect(page.albums.map(\.artistsDisplay) == ["Initial Album Artist"])
        #expect(page.albums.map(\.year) == ["2022"])
        #expect(page.nextPage == "albums-page-2")
        #expect(page.isRecognized)
    }

    @Test("Parse legacy saved albums continuation")
    func parseLibraryAlbumsLegacyContinuation() {
        let page = PlaylistParser.parseLibraryAlbumsContinuation(
            self.makeLibraryAlbumsLegacyContinuationData(continuationToken: "albums-page-3")
        )

        #expect(page.albums.map(\.id) == ["MPRELEGACY456"])
        #expect(page.nextPage == "albums-page-3")
        #expect(page.isRecognized)
    }

    @Test("Parse saved albums shelf continuation")
    func parseLibraryAlbumsShelfContinuation() {
        let page = PlaylistParser.parseLibraryAlbumsContinuation(
            self.makeLibraryAlbumsShelfContinuationData(continuationToken: "albums-page-4")
        )

        #expect(page.albums.map(\.id) == ["MPRESHELFALBUM456"])
        #expect(page.nextPage == "albums-page-4")
        #expect(page.isRecognized)
    }

    @Test("Parse command-executor saved albums continuation")
    func parseLibraryAlbumsCommandExecutorContinuation() {
        let page = PlaylistParser.parseLibraryAlbumsContinuation([
            "continuationContents": [
                "musicShelfContinuation": [
                    "contents": [
                        self.makeLibraryAlbumItem(
                            id: "MPRECOMMANDEXECUTOR",
                            title: "Command Executor Album",
                            artist: "Command Executor Artist",
                            year: "2026"
                        ),
                        [
                            "continuationItemRenderer": [
                                "continuationEndpoint": [
                                    "commandExecutorCommand": [
                                        "commands": [[
                                            "continuationCommand": [
                                                "token": "albums-command-executor-page",
                                            ],
                                        ]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])

        #expect(page.albums.map(\.id) == ["MPRECOMMANDEXECUTOR"])
        #expect(page.nextPage == "albums-command-executor-page")
        #expect(page.isRecognized)
    }

    @Test("Mark malformed saved-album shelf continuation as partial")
    func markMalformedShelfContinuationAsPartial() {
        let page = PlaylistParser.parseLibraryAlbumsContinuation([
            "continuationContents": [
                "musicShelfContinuation": [
                    "contents": [
                        self.makeLibraryAlbumItem(
                            id: "MPRECONTINUED",
                            title: "Continued Album",
                            artist: "Continued Artist",
                            year: "2026"
                        ),
                        [
                            "continuationItemRenderer": [
                                "continuationEndpoint": [
                                    "commandExecutorCommand": [:],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])

        #expect(page.albums.map(\.id) == ["MPRECONTINUED"])
        #expect(page.nextPages.isEmpty)
        #expect(!page.isRecognized)
    }

    @Test("Mark malformed renderer-level continuation page as partial")
    func markMalformedRendererContinuationPageAsPartial() {
        let page = PlaylistParser.parseLibraryAlbumsContinuation([
            "continuationContents": [
                "gridContinuation": [
                    "items": [self.makeLibraryAlbumItem(
                        id: "MPREMALFORMEDPAGE",
                        title: "Malformed Page Album",
                        artist: "Test Artist",
                        year: "2026"
                    )],
                    "continuations": [["nextContinuationData": [:]]],
                ],
            ],
        ])

        #expect(page.albums.map(\.id) == ["MPREMALFORMEDPAGE"])
        #expect(page.nextPages.isEmpty)
        #expect(!page.isRecognized)
    }

    @Test("Mark malformed renderer-level continuation as partial")
    func markMalformedRendererContinuationAsPartial() {
        let page = PlaylistParser.parseLibraryAlbumsPage([
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "gridRenderer": [
                                            "items": [self.makeLibraryAlbumItem(
                                                id: "MPREMALFORMEDCONTINUATION",
                                                title: "Malformed Continuation Album",
                                                artist: "Test Artist",
                                                year: "2026"
                                            )],
                                            "continuations": [["nextContinuationData": [:]]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ])

        #expect(page.albums.map(\.id) == ["MPREMALFORMEDCONTINUATION"])
        #expect(page.nextPages.isEmpty)
        #expect(!page.isRecognized)
    }

    @Test("Parse append-action saved albums continuation")
    func parseLibraryAlbumsAppendActionContinuation() {
        let page = PlaylistParser.parseLibraryAlbumsContinuation(
            self.makeLibraryAlbumsAppendContinuationData(continuationToken: "albums-page-4")
        )

        #expect(page.albums.map(\.id) == ["MPREAPPEND789"])
        #expect(page.nextPage == "albums-page-4")
        #expect(page.isRecognized)
    }

    @Test("Reject an ambiguous saved-albums tab shell without a renderer")
    func rejectAmbiguousLibraryAlbumsTabShell() {
        let page = PlaylistParser.parseLibraryAlbumsPage([
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [:],
                    ]],
                ],
            ],
            "responseContext": Self.loggedInResponseContext(value: "1"),
        ])

        #expect(page.albums.isEmpty)
        #expect(page.nextPage == nil)
        #expect(!page.isRecognized)
    }

    @Test("Reject a signed-out message response as an album collection")
    func rejectSignedOutLibraryAlbumsResponse() {
        let page = PlaylistParser.parseLibraryAlbumsPage([
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "itemSectionRenderer": [
                                            "contents": [[
                                                "messageRenderer": [
                                                    "button": [
                                                        "buttonRenderer": [
                                                            "navigationEndpoint": [
                                                                "signInEndpoint": [:],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
            "responseContext": Self.loggedInResponseContext(value: "0"),
        ])

        #expect(page.albums.isEmpty)
        #expect(!page.isRecognized)
    }

    @Test("Aggregate albums across multiple saved-album shelves")
    func parseLibraryAlbumsAcrossMultipleShelves() {
        let page = PlaylistParser.parseLibraryAlbumsPage([
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "musicShelfRenderer": [
                                                "contents": [[
                                                    "musicResponsiveListItemRenderer": [
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "VLPLAYLIST"],
                                                        ],
                                                        "flexColumns": [[
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Playlist"]]],
                                                            ],
                                                        ]],
                                                    ],
                                                ]],
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "contents": [
                                                    self.makeLibraryResponsiveAlbumItem(
                                                        id: "MPRESHELFONE",
                                                        title: "Shelf One"
                                                    ),
                                                ],
                                                "continuations": [[
                                                    "nextContinuationData": ["continuation": "shelf-one-next"],
                                                ]],
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "contents": [
                                                    self.makeLibraryResponsiveAlbumItem(
                                                        id: "MPRESHELFTWO",
                                                        title: "Shelf Two"
                                                    ),
                                                ],
                                                "continuations": [[
                                                    "nextContinuationData": ["continuation": "shelf-two-next"],
                                                ]],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ])

        #expect(page.albums.map(\.id) == ["MPRESHELFONE", "MPRESHELFTWO"])
        #expect(page.nextPages == ["shelf-one-next", "shelf-two-next"])
        #expect(page.isRecognized)
    }

    @Test("Recognize an empty saved-albums shelf")
    func recognizeEmptyLibraryAlbumsShelf() {
        let page = PlaylistParser.parseLibraryAlbumsPage([
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": [],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
            "responseContext": Self.loggedInResponseContext(value: "1"),
        ])

        #expect(page.albums.isEmpty)
        #expect(page.isRecognized)
    }

    @Test("Parse saved album rows from a non-grid shelf")
    func parseLibraryAlbumsShelfPage() {
        let page = PlaylistParser.parseLibraryAlbumsPage([
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": [self.makeMixedLibraryShelfAlbumItem()],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
            "responseContext": Self.loggedInResponseContext(value: "1"),
        ])

        #expect(page.albums.map(\.id) == ["MPRESHELFALBUM456"])
        #expect(page.isRecognized)
    }

    @Test("Parse responsive saved album rows directly from the grid")
    func parseResponsiveLibraryAlbumsPage() {
        let data = self.makeLibraryAlbumsGridData(items: [self.makeMixedLibraryShelfAlbumItem()])
        let page = PlaylistParser.parseLibraryAlbumsPage(data)

        #expect(page.albums.map(\.id) == ["MPRESHELFALBUM456"])
        #expect(page.isRecognized)
        #expect(PlaylistParser.parseLibraryAlbums(data).map(\.id) == ["MPRESHELFALBUM456"])
    }

    @Test("Mark a mixed supported and unknown album grid as partial")
    func markPartiallyParsedLibraryAlbumsGrid() {
        let page = PlaylistParser.parseLibraryAlbumsPage(
            self.makeLibraryAlbumsGridData(
                items: [
                    self.makeLibraryAlbumItem(
                        id: "MPREPARSED",
                        title: "Parsed Album",
                        artist: "Parsed Artist",
                        year: "2026"
                    ),
                    ["unknownRenderer": [:]],
                ],
                nextPage: "albums-page-2"
            )
        )

        #expect(page.albums.map(\.id) == ["MPREPARSED"])
        #expect(page.nextPages == ["albums-page-2"])
        #expect(!page.isRecognized)
    }

    @Test("Mark an unconsumed continuation sentinel as partial")
    func markMalformedAlbumContinuationAsPartial() {
        let page = PlaylistParser.parseLibraryAlbumsPage(
            self.makeLibraryAlbumsGridData(items: [
                self.makeLibraryAlbumItem(
                    id: "MPREPARSED",
                    title: "Parsed Album",
                    artist: "Parsed Artist",
                    year: "2026"
                ),
                [
                    "continuationItemRenderer": [
                        "continuationEndpoint": [
                            "commandExecutorCommand": [:],
                        ],
                    ],
                ],
            ])
        )

        #expect(page.albums.map(\.id) == ["MPREPARSED"])
        #expect(page.nextPages.isEmpty)
        #expect(!page.isRecognized)
    }

    @Test("Reject an album grid whose nonempty items cannot be parsed")
    func rejectUnrecognizedLibraryAlbumsGrid() {
        let page = PlaylistParser.parseLibraryAlbumsPage(
            self.makeLibraryAlbumsGridData(items: [["unknownRenderer": [:]]])
        )

        #expect(page.albums.isEmpty)
        #expect(!page.isRecognized)
    }

    @Test("Parse dedicated library artists response")
    func parseLibraryArtists() {
        let data = self.makeLibraryArtistsResponseData()
        let artists = PlaylistParser.parseLibraryArtists(data)

        #expect(artists.map(\.id) == ["UCGRIDARTIST123", "UCSHELFARTIST456"])
        #expect(artists.map(\.name) == ["Grid Artist", "Shelf Artist"])
    }

    @Test("Parse dedicated library artists deduplicates equivalent artist IDs")
    func parseLibraryArtistsDeduplicatesEquivalentIds() {
        let data = self.makeDuplicateLibraryArtistsResponseData()
        let artists = PlaylistParser.parseLibraryArtists(data)

        #expect(artists.map(\.id) == ["UCDUPLICATE123"])
        #expect(artists.map(\.name) == ["Duplicate Artist"])
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
        #expect(detail.author?.name == "Test User")
        #expect(detail.tracks.count == 5)
    }

    @Test("Parse album detail uses second subtitle artist instead of generic Album label")
    func parseAlbumDetailUsesSecondSubtitleArtist() {
        var data = self.makePlaylistDetailData(
            title: "Album Title",
            description: nil,
            author: nil,
            trackCount: 1
        )

        data["header"] = [
            "musicDetailHeaderRenderer": [
                "title": ["runs": [["text": "Album Title"]]],
                "subtitle": ["runs": [["text": "Album"]]],
                "secondSubtitle": [
                    "runs": [
                        [
                            "text": "Album Artist",
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": "UCALBUMARTIST",
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_ARTIST",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                        ["text": " • "],
                        ["text": "1 song"],
                    ],
                ],
            ],
        ]

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "MPRE-album")

        #expect(detail.isAlbum)
        #expect(detail.author?.name == "Album Artist")
        #expect(detail.author?.id == "UCALBUMARTIST")
        #expect(detail.trackCount == 1)
    }

    @Test("Parse album library target playlist ID")
    func parseAlbumLibraryTargetPlaylistID() {
        var data = self.makePlaylistDetailData(
            title: "Album Title",
            description: nil,
            author: "Album Artist",
            trackCount: 1
        )
        data["albumHeader"] = [
            "musicResponsiveHeaderRenderer": [
                "buttons": [[
                    "musicPlayButtonRenderer": [
                        "playNavigationEndpoint": [
                            "watchPlaylistEndpoint": ["playlistId": "OLAK-library-target"],
                        ],
                    ],
                ]],
            ],
        ]
        data["relatedAlbum"] = ["playlistId": "OLAK-unrelated-target"]

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "MPRE-album")

        #expect(detail.libraryTargetId == "OLAK-library-target")
    }

    @Test("Ignore album library targets outside the album header")
    func ignoreAlbumLibraryTargetOutsideHeader() {
        var data = self.makePlaylistDetailData(
            title: "Album Title",
            description: nil,
            author: "Album Artist",
            trackCount: 1
        )
        data["relatedAlbum"] = ["playlistId": "OLAK-unrelated-target"]

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "MPRE-album")

        #expect(detail.libraryTargetId == nil)
    }

    @Test("Parse responsive album detail uses strapline artist and ignores duration metadata")
    func parseResponsiveAlbumDetailUsesStraplineArtist() {
        let data: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicResponsiveHeaderRenderer": [
                                            "title": ["runs": [["text": "2AM"]]],
                                            "subtitle": ["runs": [["text": "Album"], ["text": " • "], ["text": "2026"]]],
                                            "secondSubtitle": [
                                                "runs": [["text": "1 song"], ["text": " • "], ["text": "2 minutes, 42 seconds"]],
                                            ],
                                            "straplineTextOne": [
                                                "runs": [[
                                                    "text": "Test Artist",
                                                    "navigationEndpoint": [
                                                        "browseEndpoint": [
                                                            "browseId": "UCTESTARTIST",
                                                            "browseEndpointContextSupportedConfigs": [
                                                                "browseEndpointContextMusicConfig": [
                                                                    "pageType": "MUSIC_PAGE_TYPE_ARTIST",
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ]],
                                            ],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                    "secondaryContents": [
                        "sectionListRenderer": [
                            "contents": [[
                                "musicPlaylistShelfRenderer": [
                                    "contents": [[
                                        "musicResponsiveListItemRenderer": [
                                            "playlistItemData": ["videoId": "video0"],
                                            "flexColumns": [
                                                [
                                                    "musicResponsiveListItemFlexColumnRenderer": [
                                                        "text": ["runs": [["text": "2AM"]]],
                                                    ],
                                                ],
                                                [
                                                    "musicResponsiveListItemFlexColumnRenderer": [
                                                        "text": ["runs": [["text": "2 minutes, 42 seconds"]]],
                                                    ],
                                                ],
                                            ],
                                            "fixedColumns": [[
                                                "musicResponsiveListItemFixedColumnRenderer": [
                                                    "text": ["runs": [["text": "2:42"]]],
                                                ],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
        ]

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "MPRE-test-album")

        #expect(detail.isAlbum)
        #expect(detail.author?.name == "Test Artist")
        #expect(detail.author?.id == "UCTESTARTIST")
        #expect(detail.duration == "2 minutes, 42 seconds")
        #expect(detail.tracks.first?.artists.isEmpty == true)
    }

    @Test("Parse playlist detail delete eligibility")
    func parsePlaylistDetailDeleteEligibility() {
        var deletableData = self.makePlaylistDetailData(
            title: "Owned Playlist",
            description: nil,
            author: "Test User",
            trackCount: 1
        )
        deletableData["actions"] = [
            "menuRenderer": [
                "items": [[
                    "menuNavigationItemRenderer": [
                        "navigationEndpoint": [
                            "urlEndpoint": ["url": "https://music.youtube.com/playlist/delete?list=VL-owned"],
                        ],
                    ],
                ]],
            ],
        ]

        let deletableDetail = PlaylistParser.parsePlaylistDetail(deletableData, playlistId: "VL-owned")
        let savedDetail = PlaylistParser.parsePlaylistDetail(
            self.makePlaylistDetailData(title: "Saved Playlist", description: nil, author: nil, trackCount: 1),
            playlistId: "VL-saved"
        )

        #expect(deletableDetail.canDelete == true)
        #expect(savedDetail.canDelete == false)
    }

    @Test("Playlist decoding defaults canDelete to false")
    func playlistDecodingDefaultsCanDeleteToFalse() throws {
        let json = #"{"id":"VL-old-cache","title":"Old Cache","description":null,"thumbnailURL":null,"trackCount":null}"#

        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))

        #expect(playlist.canDelete == false)
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

    @Test("Parse uploaded songs as virtual playlist with plain artist metadata")
    func parseUploadedSongsPlaylist() {
        let data = self.makeUploadedSongsData()

        let playlist = PlaylistParser.parseUploadedSongsPlaylist(data)
        let response = PlaylistParser.parsePlaylistWithContinuation(
            data,
            playlistId: Playlist.uploadedSongsBrowseID
        )

        #expect(playlist?.id == Playlist.uploadedSongsBrowseID)
        #expect(playlist?.title == "Uploaded Songs")
        #expect(playlist?.trackCount == 2)
        #expect(response.detail.tracks.count == 2)
        #expect(response.detail.tracks[0].title == "Uploaded Track 1")
        #expect(response.detail.tracks[0].artistsDisplay == "Uploaded Artist")
        #expect(response.detail.tracks[1].artistsDisplay == "Another Uploaded Artist")
        #expect(response.continuationToken == "uploaded-next-page")
    }

    @Test("Parse playlist detail ignores Suggestions shelf when playlist shelf is present")
    func parsePlaylistDetailIgnoresSuggestionsShelf() {
        let actualTrack: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "actual-video"],
                "flexColumns": [[
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": "Actual Playlist Track"]]],
                    ],
                ]],
            ],
        ]

        let suggestedTrack: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "suggested-video"],
                "flexColumns": [[
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": "Suggested Track"]]],
                    ],
                ]],
            ],
        ]

        let data: [String: Any] = [
            "header": [
                "musicDetailHeaderRenderer": [
                    "title": ["runs": [["text": "Playlist With Suggestions"]]],
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
                                            "musicPlaylistShelfRenderer": [
                                                "contents": [actualTrack],
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "title": ["runs": [["text": "Suggestions"]]],
                                                "contents": [suggestedTrack],
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

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL-suggestions")

        #expect(detail.tracks.count == 1)
        #expect(detail.trackCount == 1)
        #expect(detail.tracks[0].title == "Actual Playlist Track")
        #expect(detail.tracks[0].videoId == "actual-video")
        #expect(detail.tracks.map(\.videoId).contains("suggested-video") == false)
    }

    @Test("Parse playlist detail propagates explicit badge to track")
    func parsePlaylistDetailPropagatesExplicitBadge() {
        let explicitTrack: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "explicit-video"],
                "flexColumns": [[
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": "Explicit Track"]]],
                    ],
                ]],
                "badges": [[
                    "musicInlineBadgeRenderer": [
                        "icon": ["iconType": "MUSIC_EXPLICIT_BADGE"],
                    ],
                ]],
            ],
        ]
        let cleanTrack: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "clean-video"],
                "flexColumns": [[
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": "Clean Track"]]],
                    ],
                ]],
            ],
        ]
        let data: [String: Any] = [
            "header": [
                "musicDetailHeaderRenderer": [
                    "title": ["runs": [["text": "Mixed Playlist"]]],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicPlaylistShelfRenderer": [
                                            "contents": [explicitTrack, cleanTrack],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL-explicit")

        #expect(detail.tracks.count == 2)
        let explicit = detail.tracks.first { $0.videoId == "explicit-video" }
        let clean = detail.tracks.first { $0.videoId == "clean-video" }
        #expect(explicit?.isExplicit == true)
        #expect(clean?.isExplicit == false)
    }

    @Test("Parse playlist detail marks greyed out tracks as unavailable")
    func parsePlaylistDetailUnavailableTrack() {
        let data = self.makePlaylistDetailData(
            title: "Unavailable Track Test",
            description: nil,
            author: nil,
            trackCount: 3,
            unavailableTrackIndices: [1]
        )

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL-unavailable")

        #expect(detail.tracks.count == 3)
        #expect(detail.tracks[0].isPlayable == true)
        #expect(detail.tracks[1].isPlayable == false)
        #expect(detail.tracks[2].isPlayable == true)
    }

    @Test("Parse empty playlist detail")
    func parsePlaylistDetailEmpty() {
        let data: [String: Any] = [:]
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL789")

        #expect(detail.id == "VL789")
        #expect(detail.title == "Unknown Playlist")
        #expect(detail.tracks.isEmpty)
    }

    @Test("Parse responsive playlist header track count and continuation")
    func parseResponsivePlaylistHeaderTrackCount() {
        let response = PlaylistParser.parsePlaylistWithContinuation(
            self.makeResponsivePlaylistDetailData(
                title: "Best Video Game Music",
                author: "Shelltoast",
                authorBrowseId: "UCCXHOViev5sTR81Vi9_ysQA",
                reportedTrackCountText: "2,429 tracks",
                duration: "135+ hours",
                loadedTrackCount: 100
            ),
            playlistId: "VL-big-playlist"
        )

        #expect(response.detail.title == "Best Video Game Music")
        #expect(response.detail.author?.name == "Shelltoast")
        #expect(response.detail.author?.id == "UCCXHOViev5sTR81Vi9_ysQA")
        #expect(response.detail.trackCount == 2429)
        #expect(response.detail.duration == "135+ hours")
        #expect(response.detail.tracks.count == 100)
        #expect(response.continuationToken == "next_page_token_123")
        #expect(response.hasMore == true)
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

    // MARK: - Add to Playlist

    @Test("Parse add-to-playlist menu from known option renderers")
    func parseAddToPlaylistMenuKnownOptionRenderers() {
        let data: [String: Any] = [
            "addToPlaylistRenderer": [
                "title": ["runs": [["text": "Add to playlist"]]],
                "contents": [
                    [
                        "playlistAddToOptionRenderer": [
                            "title": ["runs": [["text": "Road Trip"]]],
                            "subtitle": ["runs": [["text": "Private"]]],
                            "serviceEndpoint": [
                                "playlistEditEndpoint": [
                                    "playlistId": "PLROADTRIP",
                                ],
                            ],
                            "selected": true,
                        ],
                    ],
                    [
                        "musicResponsiveListItemRenderer": [
                            "flexColumns": [[
                                "musicResponsiveListItemFlexColumnRenderer": [
                                    "text": ["runs": [["text": "Workout"]]],
                                ],
                            ]],
                            "menu": [
                                "menuRenderer": [
                                    "items": [[
                                        "menuServiceItemRenderer": [
                                            "serviceEndpoint": [
                                                "playlistEditEndpoint": [
                                                    "playlistId": "PLWORKOUT",
                                                ],
                                            ],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ],
                ],
                "createPlaylistEndpoint": [:],
            ],
        ]

        let menu = PlaylistParser.parseAddToPlaylistMenu(data)

        #expect(menu.title == "Add to playlist")
        #expect(menu.canCreatePlaylist == true)
        #expect(menu.options.map(\.playlistId) == ["PLROADTRIP", "PLWORKOUT"])
        #expect(menu.options.map(\.title) == ["Road Trip", "Workout"])
        #expect(menu.options.first?.isSelected == true)
        #expect(menu.options.first?.privacyStatus == .private)
    }

    @Test("Add-to-playlist parser does not infer create ability from text only")
    func parseAddToPlaylistMenuRequiresCreateEndpoint() {
        let data: [String: Any] = [
            "addToPlaylistRenderer": [
                "title": ["runs": [["text": "Create a playlist-style mix"]]],
                "contents": [[
                    "playlistAddToOptionRenderer": [
                        "title": ["runs": [["text": "Create Energy Mix"]]],
                        "serviceEndpoint": [
                            "playlistEditEndpoint": [
                                "playlistId": "PLCREATEENERGY",
                            ],
                        ],
                    ],
                ]],
            ],
        ]

        let menu = PlaylistParser.parseAddToPlaylistMenu(data)

        #expect(menu.canCreatePlaylist == false)
        #expect(menu.options.map(\.playlistId) == ["PLCREATEENERGY"])
    }

    @Test("Add-to-playlist parser deduplicates duplicate playlist IDs")
    func parseAddToPlaylistMenuDeduplicatesPlaylistIds() {
        let data: [String: Any] = [
            "addToPlaylistRenderer": [
                "contents": [
                    [
                        "playlistAddToOptionRenderer": [
                            "title": ["runs": [["text": "Favorites"]]],
                            "serviceEndpoint": [
                                "playlistEditEndpoint": [
                                    "playlistId": "PLDUPLICATE",
                                ],
                            ],
                        ],
                    ],
                    [
                        "addToPlaylistItemRenderer": [
                            "title": ["runs": [["text": "Favorites Duplicate"]]],
                            "serviceEndpoint": [
                                "playlistEditEndpoint": [
                                    "playlistId": "PLDUPLICATE",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let menu = PlaylistParser.parseAddToPlaylistMenu(data)

        #expect(menu.options.count == 1)
        #expect(menu.options.first?.playlistId == "PLDUPLICATE")
        #expect(menu.options.first?.title == "Favorites")
    }

    @Test("Add-to-playlist parser ignores arbitrary parent containers with nested playlist IDs")
    func parseAddToPlaylistMenuIgnoresParentContainerPlaylistIds() {
        let data: [String: Any] = [
            "addToPlaylistRenderer": [
                "title": ["runs": [["text": "Add to playlist"]]],
                "contents": [
                    [
                        "sectionListRenderer": [
                            "contents": [[
                                "title": ["runs": [["text": "Parent wrapper should not become option"]]],
                                "serviceEndpoint": [
                                    "playlistEditEndpoint": [
                                        "playlistId": "PLPARENT",
                                    ],
                                ],
                                "items": [[
                                    "playlistAddToOptionRenderer": [
                                        "title": ["runs": [["text": "Actual playlist"]]],
                                        "serviceEndpoint": [
                                            "playlistEditEndpoint": [
                                                "playlistId": "PLACTUAL",
                                            ],
                                        ],
                                    ],
                                ]],
                            ]],
                        ],
                    ],
                ],
            ],
        ]

        let menu = PlaylistParser.parseAddToPlaylistMenu(data)

        #expect(menu.options.count == 1)
        #expect(menu.options.first?.playlistId == "PLACTUAL")
        #expect(menu.options.first?.title == "Actual playlist")
    }

    @Test("Add-to-playlist parser handles unchecked checkStatus values")
    func parseAddToPlaylistMenuCheckStatusUncheckedValues() {
        let data: [String: Any] = [
            "addToPlaylistRenderer": [
                "contents": [
                    makeAddToPlaylistOptionData(id: "PLUNCHECKED", title: "Unchecked", checkStatus: "UNCHECKED"),
                    makeAddToPlaylistOptionData(
                        id: "PLCHECKBOXUNCHECKED",
                        title: "Checkbox unchecked",
                        checkStatus: "CHECKBOX_STATE_UNCHECKED"
                    ),
                    makeAddToPlaylistOptionData(id: "PLNOTSELECTED", title: "Not selected", checkStatus: "NOT_SELECTED"),
                ],
            ],
        ]

        let menu = PlaylistParser.parseAddToPlaylistMenu(data)

        #expect(menu.options.map(\.playlistId) == ["PLUNCHECKED", "PLCHECKBOXUNCHECKED", "PLNOTSELECTED"])
        #expect(menu.options.map(\.isSelected) == [false, false, false])
    }

    @Test("Add-to-playlist parser handles selected checkStatus values")
    func parseAddToPlaylistMenuCheckStatusSelectedValues() {
        let data: [String: Any] = [
            "addToPlaylistRenderer": [
                "contents": [
                    makeAddToPlaylistOptionData(id: "PLCHECKED", title: "Checked", checkStatus: "CHECKED"),
                    makeAddToPlaylistOptionData(
                        id: "PLCHECKBOXCHECKED",
                        title: "Checkbox checked",
                        checkStatus: "CHECKBOX_STATE_CHECKED"
                    ),
                    makeAddToPlaylistOptionData(id: "PLSELECTED", title: "Selected", checkStatus: "SELECTED"),
                ],
            ],
        ]

        let menu = PlaylistParser.parseAddToPlaylistMenu(data)

        #expect(menu.options.map(\.playlistId) == ["PLCHECKED", "PLCHECKBOXCHECKED", "PLSELECTED"])
        #expect(menu.options.map(\.isSelected) == [true, true, true])
    }

    // MARK: - Created Playlist

    @Test("Parse created playlist ID from top-level field")
    func parseCreatedPlaylistIdTopLevel() {
        let data: [String: Any] = [
            "playlistId": "PLCREATED123",
            "status": "STATUS_SUCCEEDED",
        ]

        let playlistId = PlaylistParser.parseCreatedPlaylistId(data)

        #expect(playlistId == "PLCREATED123")
    }

    @Test("Parse created playlist ID from nested response command")
    func parseCreatedPlaylistIdNestedCommand() {
        let data: [String: Any] = [
            "responseContext": [:],
            "actions": [[
                "addToToastAction": [
                    "item": [
                        "notificationTextRenderer": [
                            "responseText": ["runs": [["text": "Playlist created"]]],
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "playlistId": "PLNESTED456",
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ]

        let playlistId = PlaylistParser.parseCreatedPlaylistId(data)

        #expect(playlistId == "PLNESTED456")
    }

    @Test("Created playlist ID parser ignores empty top-level ID")
    func parseCreatedPlaylistIdIgnoresEmptyTopLevelId() {
        let data: [String: Any] = [
            "playlistId": "",
            "actions": [[
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "playlistId": "PLNESTED789",
                    ],
                ],
            ]],
        ]

        let playlistId = PlaylistParser.parseCreatedPlaylistId(data)

        #expect(playlistId == "PLNESTED789")
    }

    @Test("Created playlist ID parser ignores whitespace-only top-level ID")
    func parseCreatedPlaylistIdIgnoresWhitespaceOnlyTopLevelId() {
        let data: [String: Any] = [
            "playlistId": "   ",
            "actions": [[
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "playlistId": " PLNESTEDTRIMMED ",
                    ],
                ],
            ]],
        ]

        let playlistId = PlaylistParser.parseCreatedPlaylistId(data)

        #expect(playlistId == "PLNESTEDTRIMMED")
    }

    @Test("Created playlist ID parser reads command browse endpoint before recursive fallback")
    func parseCreatedPlaylistIdFromCommandBrowseEndpoint() {
        let data: [String: Any] = [
            "command": [
                "browseEndpoint": [
                    "playlistId": "PLCOMMAND",
                ],
            ],
        ]

        let playlistId = PlaylistParser.parseCreatedPlaylistId(data)

        #expect(playlistId == "PLCOMMAND")
    }

    @Test("Created playlist ID parser returns nil when missing")
    func parseCreatedPlaylistIdMissing() {
        let data: [String: Any] = [
            "status": "STATUS_SUCCEEDED",
            "actions": [[
                "addToToastAction": [
                    "item": [
                        "notificationTextRenderer": [
                            "responseText": ["runs": [["text": "Playlist created"]]],
                        ],
                    ],
                ],
            ]],
        ]

        let playlistId = PlaylistParser.parseCreatedPlaylistId(data)

        #expect(playlistId == nil)
    }

    // MARK: - Helpers

    private func makeAddToPlaylistOptionData(id: String, title: String, checkStatus: String) -> [String: Any] {
        [
            "playlistAddToOptionRenderer": [
                "title": ["runs": [["text": title]]],
                "serviceEndpoint": [
                    "playlistEditEndpoint": [
                        "playlistId": id,
                    ],
                ],
                "checkStatus": checkStatus,
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

    private func makeMixedLibraryContentResponseData() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "gridRenderer": [
                                                "items": self.makeMixedLibraryGridItems(),
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "contents": self.makeMixedLibraryShelfItems(),
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

    private func makeLibraryArtistsResponseData() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "gridRenderer": [
                                                "items": [[
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Grid Artist"]]],
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "MPLAUCGRIDARTIST123"],
                                                        ],
                                                    ],
                                                ]],
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "contents": [[
                                                    "musicResponsiveListItemRenderer": [
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "MPLAUCSHELFARTIST456"],
                                                        ],
                                                        "flexColumns": [[
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Shelf Artist"]]],
                                                            ],
                                                        ]],
                                                    ],
                                                ]],
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

    private func makeDuplicateLibraryArtistsResponseData() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": [
                                                [
                                                    "musicResponsiveListItemRenderer": [
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "MPLAUCDUPLICATE123"],
                                                        ],
                                                        "flexColumns": [[
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Duplicate Artist"]]],
                                                            ],
                                                        ]],
                                                    ],
                                                ],
                                                [
                                                    "musicResponsiveListItemRenderer": [
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "UCDUPLICATE123"],
                                                        ],
                                                        "flexColumns": [[
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Duplicate Artist"]]],
                                                            ],
                                                        ]],
                                                    ],
                                                ],
                                            ],
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

    private func makeMixedLibraryGridItems() -> [[String: Any]] {
        [
            [
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Grid Playlist"]]],
                    "subtitle": ["runs": [["text": "Grid Curator"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "VLGRID123"],
                    ],
                ],
            ],
            [
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Grid Album"]]],
                    "subtitle": [
                        "runs": [
                            ["text": "Album"],
                            ["text": " • "],
                            [
                                "text": "Grid Album Artist",
                                "navigationEndpoint": [
                                    "browseEndpoint": [
                                        "browseId": "UCGRIDALBUMARTIST123",
                                        "browseEndpointContextSupportedConfigs": [
                                            "browseEndpointContextMusicConfig": [
                                                "pageType": "MUSIC_PAGE_TYPE_ARTIST",
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                            ["text": " • "],
                            ["text": "2024"],
                        ],
                    ],
                    "navigationEndpoint": [
                        "browseEndpoint": [
                            "browseId": "MPREGRIDALBUM123",
                            "browseEndpointContextSupportedConfigs": [
                                "browseEndpointContextMusicConfig": [
                                    "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                                ],
                            ],
                        ],
                    ],
                    "menu": [
                        "menuRenderer": [
                            "items": [[
                                "toggleMenuServiceItemRenderer": [
                                    "toggledServiceEndpoint": [
                                        "likeEndpoint": [
                                            "target": ["playlistId": "OLAKGRIDALBUM123"],
                                        ],
                                    ],
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
            [
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Grid Artist"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "MPLAUCGRIDARTIST123"],
                    ],
                ],
            ],
            [
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Grid Podcast"]]],
                    "subtitle": ["runs": [["text": "Grid Host"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "MPSPPGRID123"],
                    ],
                ],
            ],
        ]
    }

    private func makeMixedLibraryShelfItems() -> [[String: Any]] {
        [
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "VLSHELF456"],
                    ],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Playlist"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Curator"]]],
                            ],
                        ],
                    ],
                ],
            ],
            self.makeMixedLibraryShelfAlbumItem(),
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "MPLAUCSHELFARTIST456"],
                    ],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Artist"]]],
                            ],
                        ],
                    ],
                ],
            ],
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "MPSPPSHELF456"],
                    ],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Podcast"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Host"]]],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func makeMixedLibraryShelfAlbumItem() -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": "MPRESHELFALBUM456",
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                            ],
                        ],
                    ],
                ],
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": "Shelf Album"]]],
                        ],
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    [
                                        "text": "Shelf Album Artist",
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "UCSHELFALBUMARTIST456",
                                                "browseEndpointContextSupportedConfigs": [
                                                    "browseEndpointContextMusicConfig": [
                                                        "pageType": "MUSIC_PAGE_TYPE_ARTIST",
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                    ["text": " • "],
                                    ["text": "2023"],
                                ],
                            ],
                        ],
                    ],
                ],
                "menu": [
                    "menuRenderer": [
                        "items": [[
                            "toggleMenuServiceItemRenderer": [
                                "toggledServiceEndpoint": [
                                    "likeEndpoint": [
                                        "target": ["playlistId": "OLAKSHELFALBUM456"],
                                    ],
                                ],
                            ],
                        ]],
                    ],
                ],
            ],
        ]
    }

    private func makeLibraryResponsiveAlbumItem(id: String, title: String) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": id,
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM",
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
                            "text": [
                                "runs": [
                                    ["text": "Album"],
                                    ["text": " • "],
                                    ["text": "Test Artist"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func makeLibraryAlbumsGridAndShelfData() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "gridRenderer": [
                                                "items": [
                                                    self.makeLibraryAlbumItem(
                                                        id: "MPREGRIDALBUM789",
                                                        title: "Grid Album",
                                                        artist: "Grid Artist",
                                                        year: "2025"
                                                    ),
                                                ],
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "contents": [self.makeMixedLibraryShelfAlbumItem()],
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

    private static func loggedInResponseContext(value: String) -> [String: Any] {
        [
            "serviceTrackingParams": [[
                "params": [
                    [
                        "key": "logged_in",
                        "value": value,
                    ],
                    [
                        "key": "browse_id",
                        "value": "FEmusic_liked_albums",
                    ],
                ],
            ]],
        ]
    }

    private func makeLibraryAlbumsGridData(
        items: [[String: Any]],
        nextPage: String? = nil
    ) -> [String: Any] {
        var gridRenderer: [String: Any] = [
            "items": items,
        ]
        if let nextPage {
            gridRenderer["continuations"] = [[
                "nextContinuationData": ["continuation": nextPage],
            ]]
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [["gridRenderer": gridRenderer]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeLibraryAlbumsPageData(
        albumID: String,
        title: String,
        continuationToken: String?
    ) -> [String: Any] {
        var gridRenderer: [String: Any] = [
            "items": [self.makeLibraryAlbumItem(id: albumID, title: title, artist: "Initial Album Artist", year: "2022")],
        ]
        if let continuationToken {
            gridRenderer["continuations"] = [[
                "nextContinuationData": ["continuation": continuationToken],
            ]]
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [["gridRenderer": gridRenderer]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeLibraryAlbumsShelfContinuationData(continuationToken: String?) -> [String: Any] {
        var contents = [self.makeMixedLibraryShelfAlbumItem()]
        if let continuationToken {
            contents.append([
                "continuationItemRenderer": [
                    "continuationEndpoint": [
                        "continuationCommand": ["token": continuationToken],
                    ],
                ],
            ])
        }

        return [
            "continuationContents": [
                "musicShelfContinuation": [
                    "contents": contents,
                ],
            ],
        ]
    }

    private func makeLibraryAlbumsLegacyContinuationData(continuationToken: String?) -> [String: Any] {
        var gridContinuation: [String: Any] = [
            "items": [
                self.makeLibraryAlbumItem(
                    id: "MPRELEGACY456",
                    title: "Legacy Continuation Album",
                    artist: "Legacy Artist",
                    year: "2021"
                ),
            ],
        ]
        if let continuationToken {
            gridContinuation["continuations"] = [[
                "nextContinuationData": ["continuation": continuationToken],
            ]]
        }

        return [
            "continuationContents": [
                "gridContinuation": gridContinuation,
            ],
        ]
    }

    private func makeLibraryAlbumsAppendContinuationData(continuationToken: String?) -> [String: Any] {
        var continuationItems = [
            self.makeLibraryAlbumItem(
                id: "MPREAPPEND789",
                title: "Append Continuation Album",
                artist: "Append Artist",
                year: "2020"
            ),
        ]
        if let continuationToken {
            continuationItems.append([
                "continuationItemRenderer": [
                    "continuationEndpoint": [
                        "continuationCommand": ["token": continuationToken],
                    ],
                ],
            ])
        }

        return [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": continuationItems,
                ],
            ]],
        ]
    }

    private func makeLibraryAlbumItem(
        id: String,
        title: String,
        artist: String,
        year: String
    ) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": title]]],
                "subtitle": [
                    "runs": [
                        ["text": "Album"],
                        ["text": " • "],
                        ["text": artist],
                        ["text": " • "],
                        ["text": year],
                    ],
                ],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": id,
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func makePlaylistDetailData(
        title: String,
        description: String?,
        author: String?,
        trackCount: Int,
        unavailableTrackIndices: Set<Int> = []
    ) -> [String: Any] {
        var tracks: [[String: Any]] = []

        for i in 0 ..< trackCount {
            var renderer: [String: Any] = [
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
            ]
            if unavailableTrackIndices.contains(i) {
                renderer["musicItemRendererDisplayPolicy"] = "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
            }

            tracks.append([
                "musicResponsiveListItemRenderer": renderer,
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

    private func makeUploadedSongsData() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": [
                                                self.uploadedSongRow(
                                                    videoId: "upload-video-1",
                                                    title: "Uploaded Track 1",
                                                    artist: "Uploaded Artist"
                                                ),
                                                self.uploadedSongRow(
                                                    videoId: "upload-video-2",
                                                    title: "Uploaded Track 2",
                                                    artist: "Another Uploaded Artist"
                                                ),
                                                [
                                                    "continuationItemRenderer": [
                                                        "continuationEndpoint": [
                                                            "continuationCommand": [
                                                                "token": "uploaded-next-page",
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                            ],
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

    private func uploadedSongRow(videoId: String, title: String, artist: String) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": videoId],
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": title]]],
                        ],
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [
                                ["text": artist],
                                ["text": " • "],
                                ["text": "Uploaded Album"],
                            ]],
                        ],
                    ],
                ],
                "fixedColumns": [[
                    "musicResponsiveListItemFixedColumnRenderer": [
                        "text": ["runs": [["text": "3:25"]]],
                    ],
                ]],
            ],
        ]
    }

    private func makeResponsivePlaylistDetailData(
        title: String,
        author: String,
        authorBrowseId: String? = nil,
        reportedTrackCountText: String,
        duration: String,
        loadedTrackCount: Int
    ) -> [String: Any] {
        var tracks: [[String: Any]] = []

        for i in 0 ..< loadedTrackCount {
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

        tracks.append([
            "continuationItemRenderer": [
                "continuationEndpoint": [
                    "continuationCommand": [
                        "token": "next_page_token_123",
                    ],
                ],
            ],
        ])

        return [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicResponsiveHeaderRenderer": [
                                            "title": ["runs": [["text": title]]],
                                            "subtitle": [
                                                "runs": [
                                                    ["text": "Playlist"],
                                                    ["text": " • "],
                                                    ["text": "2026"],
                                                ],
                                            ],
                                            "secondSubtitle": [
                                                "runs": [
                                                    ["text": "21M views"],
                                                    ["text": " • "],
                                                    ["text": reportedTrackCountText],
                                                    ["text": " • "],
                                                    ["text": duration],
                                                ],
                                            ],
                                            "facepile": [
                                                "avatarStackViewModel": [
                                                    "text": [
                                                        "content": author,
                                                    ],
                                                    "rendererContext": authorBrowseId.map { browseId in
                                                        [
                                                            "commandContext": [
                                                                "onTap": [
                                                                    "innertubeCommand": [
                                                                        "browseEndpoint": [
                                                                            "browseId": browseId,
                                                                            "browseEndpointContextSupportedConfigs": [
                                                                                "browseEndpointContextMusicConfig": [
                                                                                    "pageType": "MUSIC_PAGE_TYPE_USER_CHANNEL",
                                                                                ],
                                                                            ],
                                                                        ],
                                                                    ],
                                                                ],
                                                            ],
                                                        ]
                                                    } ?? [:],
                                                ],
                                            ],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                    "secondaryContents": [
                        "sectionListRenderer": [
                            "contents": [[
                                "musicPlaylistShelfRenderer": [
                                    "contents": tracks,
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
        ]
    }
}
