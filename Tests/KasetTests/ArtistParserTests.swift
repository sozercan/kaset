import Foundation
import Testing
@testable import Kaset

// swiftlint:disable type_body_length
/// Tests for ArtistParser.
@Suite(.tags(.parser))
struct ArtistParserTests {
    // MARK: - Parse Artist Detail Tests

    @Test("parseArtistDetail extracts basic info")
    func parseArtistDetailBasicInfo() {
        let data = Self.makeArtistResponse(
            name: "Taylor Swift",
            description: "Grammy-winning artist",
            songs: 5,
            albums: 3
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-taylor")

        #expect(result.name == "Taylor Swift")
        #expect(result.description == "Grammy-winning artist")
        #expect(result.songs.count == 5)
        #expect(result.albumSections.first?.albums.count == 3)
        #expect(result.playlistSections.isEmpty)
        #expect(result.artistSections.isEmpty)
    }

    @Test("parseArtistDetail handles empty response")
    func parseArtistDetailEmptyResponse() {
        let data: [String: Any] = [:]

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.name == "Unknown Artist")
        #expect(result.songs.isEmpty)
        #expect(result.albumSections.isEmpty)
    }

    @Test("parseArtistDetail extracts channel ID from UC prefix")
    func parseArtistDetailExtractsChannelId() {
        let data = Self.makeArtistResponse(name: "Test Artist", songs: 0, albums: 0)

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-channel-123")

        #expect(result.channelId == "UC-channel-123")
    }

    @Test("parseArtistDetail does not set channel ID without UC prefix")
    func parseArtistDetailNoChannelIdWithoutPrefix() {
        let data = Self.makeArtistResponse(name: "Test Artist", songs: 0, albums: 0)

        let result = ArtistParser.parseArtistDetail(data, artistId: "MPLA-not-channel")

        #expect(result.channelId == nil)
    }

    @Test("parseArtistDetail extracts subscription status")
    func parseArtistDetailExtractsSubscription() {
        let data = Self.makeArtistResponseWithSubscription(
            name: "Subscribed Artist",
            isSubscribed: true,
            subscriberCount: "1.5M subscribers"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.isSubscribed == true)
        #expect(result.subscriberCount == "1.5M subscribers")
    }

    @Test("parseArtistDetail extracts monthly audience")
    func parseArtistDetailExtractsMonthlyAudience() {
        let data = Self.makeArtistResponseWithSubscription(
            name: "Monthly Artist",
            isSubscribed: false,
            subscriberCount: "54.4K",
            monthlyAudience: "2.59M monthly audience"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.monthlyAudience == "2.59M")
    }

    @Test("parseArtistDetail extracts songs browse ID when available")
    func parseArtistDetailExtractsSongsBrowseId() {
        let data = Self.makeArtistResponseWithMoreSongs(
            browseId: "VLPL-all-songs",
            params: "some-params"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.hasMoreSongs == true)
        #expect(result.songsBrowseId == "VLPL-all-songs")
        #expect(result.songsParams == "some-params")
    }

    @Test("parseArtistDetail extracts thumbnail URL")
    func parseArtistDetailExtractsThumbnail() {
        let data = Self.makeArtistResponse(
            name: "Test Artist",
            thumbnailURL: "https://example.com/artist.jpg",
            songs: 0,
            albums: 0
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.thumbnailURL?.absoluteString == "https://example.com/artist.jpg")
    }

    // MARK: - Parse Artist Songs Tests

    @Test("parseArtistSongs extracts songs from shelf")
    func parseArtistSongsExtractsFromShelf() {
        let data = Self.makeArtistSongsResponse(songCount: 10)

        let songs = ArtistParser.parseArtistSongs(data)

        #expect(songs.count == 10)
        #expect(songs[0].videoId == "video-0")
        #expect(songs[0].title == "Song 0")
    }

    @Test("parseArtistSongs handles empty response")
    func parseArtistSongsEmptyResponse() {
        let data: [String: Any] = [:]

        let songs = ArtistParser.parseArtistSongs(data)

        #expect(songs.isEmpty)
    }

    @Test("parseArtistSongs extracts artist info")
    func parseArtistSongsExtractsArtists() {
        let data = Self.makeArtistSongsResponse(songCount: 1)

        let songs = ArtistParser.parseArtistSongs(data)

        #expect(songs.count == 1)
        #expect(!songs[0].artists.isEmpty)
    }

    // MARK: - Album Parsing Tests

    @Test("parseArtistDetail extracts albums with MPRE prefix")
    func parseArtistDetailExtractsAlbumsWithMPRE() {
        let data = Self.makeArtistResponseWithAlbums(
            ids: ["MPRE-album-1", "MPRE-album-2"],
            titles: ["Album One", "Album Two"],
            years: ["2024", "2023"]
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.albumSections.count == 1)
        let albums = result.albumSections[0].albums
        #expect(albums.count == 2)
        #expect(albums[0].id == "MPRE-album-1")
        #expect(albums[0].title == "Album One")
        #expect(albums[0].year == "2024")
    }

    @Test("parseArtistDetail extracts albums with OLAK prefix")
    func parseArtistDetailExtractsAlbumsWithOLAK() {
        let data = Self.makeArtistResponseWithAlbums(
            ids: ["OLAK-album-1"],
            titles: ["OLAK Album"],
            years: ["2022"]
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.albumSections.count == 1)
        #expect(result.albumSections[0].albums[0].id == "OLAK-album-1")
    }

    @Test("parseArtistDetail ignores non-album browse IDs")
    func parseArtistDetailIgnoresNonAlbums() {
        let data = Self.makeArtistResponseWithAlbums(
            ids: ["VLPL-playlist"],
            titles: ["Not An Album"],
            years: [nil]
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.albumSections.isEmpty)
    }

    @Test("parseArtistDetail preserves album carousel titles")
    func parseArtistDetailPreservesAlbumSectionTitles() {
        let data = Self.makeArtistResponseWithAlbums(
            ids: ["MPRE-single-1", "MPRE-single-2"],
            titles: ["Single One", "EP Two"],
            years: ["2024", "2023"],
            sectionTitle: "Singles & EPs"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.albumSections.count == 1)
        #expect(result.albumSections[0].albums.count == 2)
        #expect(result.albumSections[0].title == "Singles & EPs")
        #expect(result.albumSections[0].albums.map(\.id) == ["MPRE-single-1", "MPRE-single-2"])
    }

    @Test("parseArtistDetail extracts playlists from carousel")
    func parseArtistDetailExtractsPlaylists() {
        let data = Self.makeArtistResponseWithPlaylists(
            ids: ["VLPL-playlist-1", "PL-playlist-2"],
            titles: ["Playlist One", "Playlist Two"],
            authors: ["Shelltoast", "Shelltoast"],
            sectionTitle: "Playlists"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.playlistSections.count == 1)
        #expect(result.playlistSections[0].title == "Playlists")
        #expect(result.playlistSections[0].playlists.map(\.id) == ["VLPL-playlist-1", "PL-playlist-2"])
        #expect(result.artistSections.isEmpty)
        #expect(result.albumSections.isEmpty)
    }

    @Test("parseArtistDetail preserves featured on playlist section")
    func parseArtistDetailExtractsFeaturedOnPlaylists() {
        let data = Self.makeArtistResponseWithPlaylists(
            ids: ["VLPL-featured-1"],
            titles: ["Featured Playlist"],
            authors: ["Editorial"],
            sectionTitle: "Featured on"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.playlistSections.count == 1)
        #expect(result.playlistSections[0].title == "Featured on")
        #expect(result.playlistSections[0].playlists.map(\.id) == ["VLPL-featured-1"])
        #expect(result.artistSections.isEmpty)
    }

    @Test("parseArtistDetail preserves playlist carousel titles")
    func parseArtistDetailPreservesPlaylistSectionTitles() {
        let data = Self.makeArtistResponseWithPlaylists(
            ids: ["VLPL-repeat-1"],
            titles: ["Repeated Playlist"],
            authors: ["Shelltoast"],
            sectionTitle: "Playlists on repeat"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.playlistSections.count == 1)
        #expect(result.playlistSections[0].title == "Playlists on repeat")
        #expect(result.playlistSections[0].playlists.map(\.id) == ["VLPL-repeat-1"])
    }

    @Test("parseArtistDetail preserves artist carousel titles")
    func parseArtistDetailExtractsSimilarArtists() {
        let data = Self.makeArtistResponseWithSimilarArtists(
            ids: ["UC-similar-1", "MPLAUC-similar-2"],
            names: ["Michael Giacchino", "Hans Zimmer"],
            sectionTitle: "Artists on repeat"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.playlistSections.isEmpty)
        #expect(result.artistSections.count == 1)
        #expect(result.artistSections[0].title == "Artists on repeat")
        #expect(result.artistSections[0].artists.count == 2)
        #expect(result.artistSections[0].artists[0].id == "UC-similar-1")
        #expect(result.artistSections[0].artists[0].name == "Michael Giacchino")
    }

    @Test("parseArtistDetail extracts similar artist subtitle")
    func parseArtistDetailExtractsSimilarArtistSubtitle() {
        let data = Self.makeArtistResponseWithSimilarArtists(
            ids: ["UC-similar-1"],
            names: ["Ezhel"],
            subtitles: ["24.9M monthly audience"],
            sectionTitle: "Fans might also like"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.artistSections.count == 1)
        #expect(result.artistSections[0].artists.first?.subtitle == "24.9M monthly audience")
    }

    // MARK: - Mix Playlist Tests

    @Test("parseArtistDetail extracts mix playlist ID from startRadioButton")
    func parseArtistDetailExtractsMixPlaylistId() {
        let data = Self.makeArtistResponseWithRadioButton(
            playlistId: "RDCLAK-mix-123",
            videoId: nil
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.mixPlaylistId == "RDCLAK-mix-123")
    }

    // MARK: - Test Helpers

    private static func makeArtistResponse(
        name: String,
        description: String? = nil,
        thumbnailURL: String? = nil,
        songs: Int,
        albums: Int
    ) -> [String: Any] {
        var headerContent: [String: Any] = [
            "title": [
                "runs": [["text": name]],
            ],
        ]

        if let description {
            headerContent["description"] = [
                "runs": [["text": description]],
            ]
        }

        if let thumbnailURL {
            headerContent["thumbnail"] = [
                "musicThumbnailRenderer": [
                    "thumbnail": [
                        "thumbnails": [
                            ["url": thumbnailURL, "width": 226, "height": 226],
                        ],
                    ],
                ],
            ]
        }

        var sectionContents: [[String: Any]] = []

        // Add songs shelf
        if songs > 0 {
            sectionContents.append([
                "musicShelfRenderer": [
                    "contents": Self.makeSongItems(count: songs),
                ],
            ])
        }

        // Add albums carousel
        if albums > 0 {
            sectionContents.append([
                "musicCarouselShelfRenderer": [
                    "contents": (0 ..< albums).map { Self.makeAlbumItem(index: $0) },
                ],
            ])
        }

        return [
            "header": [
                "musicImmersiveHeaderRenderer": headerContent,
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": sectionContents,
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func makeArtistResponseWithSubscription(
        name: String,
        isSubscribed: Bool,
        subscriberCount: String,
        monthlyAudience: String? = nil
    ) -> [String: Any] {
        var header: [String: Any] = [
            "title": [
                "runs": [["text": name]],
            ],
            "subscriptionButton": [
                "subscribeButtonRenderer": [
                    "channelId": "UC-extracted",
                    "subscribed": isSubscribed,
                    "subscriberCountText": [
                        "runs": [["text": subscriberCount]],
                    ],
                ],
            ],
        ]
        if let monthlyAudience {
            header["monthlyListenerCount"] = [
                "runs": [["text": monthlyAudience]],
            ]
        }

        return [
            "header": [
                "musicImmersiveHeaderRenderer": header,
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": [] as [[String: Any]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func makeArtistResponseWithMoreSongs(browseId: String, params: String?) -> [String: Any] {
        var browseEndpoint: [String: Any] = [
            "browseId": browseId,
        ]
        if let params {
            browseEndpoint["params"] = params
        }

        let shelfContent: [String: Any] = [
            "contents": Self.makeSongItems(count: 5),
            "bottomEndpoint": [
                "browseEndpoint": browseEndpoint,
            ],
        ]

        return [
            "header": [
                "musicImmersiveHeaderRenderer": [
                    "title": [
                        "runs": [["text": "Artist"]],
                    ],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": [
                                            [
                                                "musicShelfRenderer": shelfContent,
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

    private static func makeAlbumItem(id: String, title: String, year: String?) -> [String: Any] {
        var twoRowRenderer: [String: Any] = [
            "title": [
                "runs": [["text": title]],
            ],
            "navigationEndpoint": [
                "browseEndpoint": [
                    "browseId": id,
                ],
            ],
        ]

        if let year {
            twoRowRenderer["subtitle"] = [
                "runs": [["text": year]],
            ]
        }

        return ["musicTwoRowItemRenderer": twoRowRenderer]
    }

    private static func makeArtistResponseWithAlbums(
        ids: [String],
        titles: [String],
        years: [String?],
        sectionTitle: String = "Albums"
    ) -> [String: Any] {
        let albumItems = zip(zip(ids, titles), years).map { pair, year in
            Self.makeAlbumItem(id: pair.0, title: pair.1, year: year)
        }

        return [
            "header": [
                "musicImmersiveHeaderRenderer": [
                    "title": [
                        "runs": [["text": "Artist"]],
                    ],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": [
                                            [
                                                "musicCarouselShelfRenderer": [
                                                    "header": [
                                                        "musicCarouselShelfBasicHeaderRenderer": [
                                                            "title": [
                                                                "runs": [["text": sectionTitle]],
                                                            ],
                                                        ],
                                                    ],
                                                    "contents": albumItems,
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

    private static func makeArtistResponseWithPlaylists(
        ids: [String],
        titles: [String],
        authors: [String],
        sectionTitle: String
    ) -> [String: Any] {
        let playlistItems = zip(zip(ids, titles), authors).map { pair, author in
            [
                "musicTwoRowItemRenderer": [
                    "title": [
                        "runs": [["text": pair.1]],
                    ],
                    "subtitle": [
                        "runs": [[
                            "text": author,
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": "UC-playlist-author",
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_USER_CHANNEL",
                                        ],
                                    ],
                                ],
                            ],
                        ]],
                    ],
                    "navigationEndpoint": [
                        "browseEndpoint": [
                            "browseId": pair.0,
                            "browseEndpointContextSupportedConfigs": [
                                "browseEndpointContextMusicConfig": [
                                    "pageType": "MUSIC_PAGE_TYPE_PLAYLIST",
                                ],
                            ],
                        ],
                    ],
                ],
            ]
        }

        return [
            "header": [
                "musicImmersiveHeaderRenderer": [
                    "title": [
                        "runs": [["text": "Artist"]],
                    ],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicCarouselShelfRenderer": [
                                            "header": [
                                                "musicCarouselShelfBasicHeaderRenderer": [
                                                    "title": [
                                                        "runs": [["text": sectionTitle]],
                                                    ],
                                                ],
                                            ],
                                            "contents": playlistItems,
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

    private static func makeArtistResponseWithSimilarArtists(
        ids: [String],
        names: [String],
        subtitles: [String]? = nil,
        sectionTitle: String
    ) -> [String: Any] {
        let artistSubtitles = subtitles ?? Array(repeating: "156M monthly audience", count: ids.count)
        let artistItems = zip(zip(ids, names), artistSubtitles).map { pair, subtitle in
            let (id, name) = pair
            return [
                "musicTwoRowItemRenderer": [
                    "title": [
                        "runs": [[
                            "text": name,
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": id,
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_ARTIST",
                                        ],
                                    ],
                                ],
                            ],
                        ]],
                    ],
                    "subtitle": [
                        "runs": [["text": subtitle]],
                    ],
                    "navigationEndpoint": [
                        "browseEndpoint": [
                            "browseId": id,
                            "browseEndpointContextSupportedConfigs": [
                                "browseEndpointContextMusicConfig": [
                                    "pageType": "MUSIC_PAGE_TYPE_ARTIST",
                                ],
                            ],
                        ],
                    ],
                    "thumbnailRenderer": [
                        "musicThumbnailRenderer": [
                            "thumbnail": [
                                "thumbnails": [[
                                    "url": "https://example.com/\(id).jpg",
                                    "width": 226,
                                    "height": 226,
                                ]],
                            ],
                        ],
                    ],
                ],
            ]
        }

        return [
            "header": [
                "musicImmersiveHeaderRenderer": [
                    "title": [
                        "runs": [["text": "Artist"]],
                    ],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicCarouselShelfRenderer": [
                                            "header": [
                                                "musicCarouselShelfBasicHeaderRenderer": [
                                                    "title": [
                                                        "runs": [["text": sectionTitle]],
                                                    ],
                                                ],
                                            ],
                                            "contents": artistItems,
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

    private static func makeArtistResponseWithRadioButton(playlistId: String, videoId: String?) -> [String: Any] {
        var watchPlaylistEndpoint: [String: Any] = [
            "playlistId": playlistId,
        ]
        if let videoId {
            watchPlaylistEndpoint["videoId"] = videoId
        }

        return [
            "header": [
                "musicImmersiveHeaderRenderer": [
                    "title": [
                        "runs": [["text": "Artist"]],
                    ],
                    "startRadioButton": [
                        "buttonRenderer": [
                            "navigationEndpoint": [
                                "watchPlaylistEndpoint": watchPlaylistEndpoint,
                            ],
                        ],
                    ],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": [] as [[String: Any]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func makeArtistSongsResponse(songCount: Int) -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": [
                                            [
                                                "musicShelfRenderer": [
                                                    "contents": self.makeSongItems(count: songCount),
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

    private static func makeSongItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { index in
            [
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": [
                        "videoId": "video-\(index)",
                    ],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": [
                                    "runs": [["text": "Song \(index)"]],
                                ],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": [
                                    "runs": [
                                        [
                                            "text": "Artist \(index)",
                                            "navigationEndpoint": [
                                                "browseEndpoint": [
                                                    "browseId": "UC-artist-\(index)",
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
    }

    private static func makeAlbumItem(index: Int) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": [
                    "runs": [["text": "Album \(index)"]],
                ],
                "subtitle": [
                    "runs": [["text": "202\(index)"]],
                ],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": "MPRE-\(index)",
                    ],
                ],
            ],
        ]
    }
}

// swiftlint:enable type_body_length
