import Foundation
import Testing
@testable import Kaset

// swiftlint:disable type_body_length file_length
/// Tests for ArtistParser.
@Suite(.tags(.parser))
struct ArtistParserTests {
    // MARK: - Parse Artist Detail Tests

    @Test("parseArtistDetail extracts basic info")
    func parseArtistDetailBasicInfo() {
        let data = Self.makeArtistResponse(
            name: "Taylor Swift",
            description: "Grammy-winning artist",
            songsSectionTitle: "Top songs",
            songs: 5,
            albums: 3
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-taylor")

        #expect(result.name == "Taylor Swift")
        #expect(result.description == "Grammy-winning artist")
        #expect(result.songs.count == 5)
        #expect(result.songsSectionTitle == "Top songs")
        #expect(Self.albums(in: result, titled: "Albums")?.count == 3)
        #expect(Self.playlists(in: result, titled: "Playlists") == nil)
        #expect(Self.artists(in: result, titled: "Artists") == nil)
    }

    @Test("parseArtistDetail handles empty response")
    func parseArtistDetailEmptyResponse() {
        let data: [String: Any] = [:]

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.name == "Unknown Artist")
        #expect(result.songs.isEmpty)
        #expect(result.orderedSections.isEmpty)
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
            subscriberCount: "1.5M subscribers",
            shortSubscriberCount: "1.5M",
            subscribedButtonText: "Subscribed",
            unsubscribedButtonText: "Subscribe"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.isSubscribed == true)
        #expect(result.subscriberCount == "1.5M")
        #expect(result.subscribedButtonText == "Subscribed")
        #expect(result.unsubscribedButtonText == "Subscribe")
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

        #expect(result.monthlyAudience == "2.59M monthly audience")
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

    @Test("parseArtistSongs propagates renderer playability")
    func parseArtistSongsPropagatesRendererPlayability() {
        let data = Self.makeArtistSongsResponse(
            songCount: 2,
            displayPolicies: [nil, "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"]
        )

        let songs = ArtistParser.parseArtistSongs(data)

        #expect(songs.count == 2)
        #expect(songs[0].isPlayable)
        #expect(songs[1].isPlayable == false)
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

        let albums = Self.albums(in: result, titled: "Albums")
        #expect(albums?.count == 2)
        #expect(albums?[0].id == "MPRE-album-1")
        #expect(albums?[0].title == "Album One")
        #expect(albums?[0].year == "2024")
    }

    @Test("parseArtistDetail extracts albums with OLAK prefix")
    func parseArtistDetailExtractsAlbumsWithOLAK() {
        let data = Self.makeArtistResponseWithAlbums(
            ids: ["OLAK-album-1"],
            titles: ["OLAK Album"],
            years: ["2022"]
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(Self.albums(in: result, titled: "Albums")?.first?.id == "OLAK-album-1")
    }

    @Test("parseArtistDetail ignores non-album browse IDs")
    func parseArtistDetailIgnoresNonAlbums() {
        let data = Self.makeArtistResponseWithAlbums(
            ids: ["VLPL-playlist"],
            titles: ["Not An Album"],
            years: [nil]
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(Self.albums(in: result, titled: "Albums") == nil)
        #expect(Self.playlists(in: result, titled: "Albums")?.map(\.id) == ["VLPL-playlist"])
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

        #expect(Self.albums(in: result, titled: "Singles & EPs")?.count == 2)
        #expect(Self.albums(in: result, titled: "Singles & EPs")?.map(\.id) == ["MPRE-single-1", "MPRE-single-2"])
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

        let playlists = Self.playlists(in: result, titled: "Playlists")
        #expect(playlists?.map(\.id) == ["VLPL-playlist-1", "PL-playlist-2"])
        #expect(playlists?.first?.author?.id == "UC-playlist-author")
        #expect(playlists?.first?.author?.name == "Shelltoast")
        #expect(playlists?.first?.author?.profileKind == .profile)
        #expect(Self.firstSection(of: result, matching: "Playlists") != nil)
        #expect(Self.artists(in: result, titled: "Artists") == nil)
        #expect(Self.albums(in: result, titled: "Albums") == nil)
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

        #expect(Self.playlists(in: result, titled: "Featured on")?.map(\.id) == ["VLPL-featured-1"])
        #expect(Self.artists(in: result, titled: "Artists") == nil)
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

        #expect(Self.playlists(in: result, titled: "Playlists on repeat")?.map(\.id) == ["VLPL-repeat-1"])
    }

    @Test("parseArtistDetail preserves artist carousel titles")
    func parseArtistDetailExtractsSimilarArtists() {
        let data = Self.makeArtistResponseWithSimilarArtists(
            ids: ["UC-similar-1", "MPLAUC-similar-2"],
            names: ["Michael Giacchino", "Hans Zimmer"],
            sectionTitle: "Artists on repeat"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        let artists = Self.artists(in: result, titled: "Artists on repeat")
        #expect(Self.playlists(in: result, titled: "Playlists") == nil)
        #expect(artists?.count == 2)
        #expect(artists?[0].id == "UC-similar-1")
        #expect(artists?[0].name == "Michael Giacchino")
    }

    @Test("parseArtistDetail preserves carousel response order across section types")
    func parseArtistDetailPreservesCarouselResponseOrder() {
        let data = Self.makeArtistResponseWithCarousels([
            (title: "Albums", items: [Self.makeAlbumItem(id: "MPRE-album-1", title: "Album", year: "2024")]),
            (title: "Featured on", items: [Self.makePlaylistCarouselItem(id: "VL-playlist-1", title: "Featured Playlist", author: "Editorial")]),
            (title: "Similar artists", items: [Self.makeArtistCarouselItem(id: "UC-artist-1", name: "Similar Artist")]),
        ])

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(result.orderedSections.map(\.title) == ["Albums", "Featured on", "Similar artists"])
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

        #expect(Self.artists(in: result, titled: "Fans might also like")?.first?.subtitle == "24.9M monthly audience")
    }

    @Test("parseArtistDetail marks user channel carousel items as profiles")
    func parseArtistDetailMarksUserChannelCarouselItemsAsProfiles() {
        let data = Self.makeArtistResponseWithSimilarArtists(
            ids: ["UC-profile-1"],
            names: ["Profile Artist"],
            sectionTitle: "Artists on repeat",
            pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL"
        )

        let result = ArtistParser.parseArtistDetail(data, artistId: "UC-test")

        #expect(Self.artists(in: result, titled: "Artists on repeat")?.first?.profileKind == .profile)
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

    // MARK: - Fixture-backed Tests (real payload shape)

    /// Loads and parses `artist_lofi_girl.json`, a snapshot of the artist page
    /// for a channel-style artist (Lofi Girl). Asserts every non-default
    /// shelf type the parser is now expected to surface.
    @Test("parseArtistDetail routes all artist-page shelves from real payload")
    func parseArtistDetailFromLofiGirlFixture() throws {
        let data = try Self.loadArtistFixture("artist_lofi_girl")

        let result = ArtistParser.parseArtistDetail(data, artistId: "UCSJ4gkVC6NrvII8umztf0Ow")

        // Header
        #expect(result.name == "Lofi Girl")
        #expect(result.channelId == "UCSJ4gkVC6NrvII8umztf0Ow")

        // Top songs
        #expect(!result.songs.isEmpty)

        // Albums vs Singles split by shelf title
        #expect(!result.albums.isEmpty)
        #expect(!result.singles.isEmpty)
        for album in result.albums {
            #expect(album.id.hasPrefix("MPRE") || album.id.hasPrefix("OLAK"))
        }
        for single in result.singles {
            #expect(single.id.hasPrefix("MPRE") || single.id.hasPrefix("OLAK"))
        }

        // Latest episodes — at least one live stream must be present
        #expect(!result.episodes.isEmpty)
        for episode in result.episodes {
            #expect(!episode.videoId.isEmpty)
            #expect(!episode.title.isEmpty)
        }
        let liveEpisodes = result.episodes.filter(\.isLive)
        #expect(!liveEpisodes.isEmpty, "Expected at least one live episode in the Lofi Girl fixture")

        // Playlists by artist (VL browseIds)
        #expect(!result.playlistsByArtist.isEmpty)
        for playlist in result.playlistsByArtist {
            #expect(playlist.id.hasPrefix("VL") || playlist.id.hasPrefix("PL"))
        }

        // Related artists (UC browseIds)
        #expect(!result.relatedArtists.isEmpty)
        for artist in result.relatedArtists {
            #expect(artist.id.hasPrefix("UC"))
        }

        // Podcast shows on the artist page (MPSPP browseIds)
        #expect(!result.podcasts.isEmpty)
        for show in result.podcasts {
            #expect(show.id.hasPrefix("MPSPP"))
        }
    }

    @Test("parseArtistDetail captures shelf moreContentButton endpoints")
    func parseArtistDetailCapturesMoreEndpoints() throws {
        let data = try Self.loadArtistFixture("artist_lofi_girl")
        let result = ArtistParser.parseArtistDetail(data, artistId: "UCSJ4gkVC6NrvII8umztf0Ow")

        // Lofi Girl's Latest episodes shelf has a More button pointing to a
        // MUSIC_PAGE_TYPE_ARTIST destination.
        let episodesMore = try #require(result.moreEndpoints[.episodes])
        #expect(episodesMore.pageType == .artist)
        #expect(episodesMore.browseId.hasPrefix("UC"))
        #expect(episodesMore.params != nil)
    }

    @Test("parseArtistDiscography extracts albums from grid response")
    func parseArtistDiscographyExtractsAlbums() throws {
        let data = try Self.loadArtistFixture("artist_nirvana_discography")

        let albums = ArtistParser.parseArtistDiscography(data)

        #expect(!albums.isEmpty)
        for album in albums {
            #expect(album.id.hasPrefix("MPRE") || album.id.hasPrefix("OLAK"))
            #expect(!album.title.isEmpty)
        }
    }

    @Test("parseArtistEpisodesGrid extracts full episode list (authenticated)")
    func parseArtistEpisodesGridExtractsEpisodes() throws {
        let data = try Self.loadArtistFixture("artist_lofi_girl_episodes_more")

        let episodes = ArtistParser.parseArtistEpisodesGrid(data)

        // Full list behind the Latest-episodes "See all"; user-reported target
        // video is item 39 of 92 in the captured HAR.
        #expect(episodes.count >= 50)
        for episode in episodes {
            #expect(!episode.videoId.isEmpty)
            #expect(!episode.title.isEmpty)
        }
        let liveEpisodes = episodes.filter(\.isLive)
        #expect(!liveEpisodes.isEmpty, "Expected at least one live stream in the full episodes list")
        #expect(episodes.contains { $0.videoId == "IxPANmjPaek" })
    }

    // MARK: - Test Helpers

    private static func makeArtistResponse(
        name: String,
        description: String? = nil,
        thumbnailURL: String? = nil,
        songsSectionTitle: String? = nil,
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
                    "title": songsSectionTitle.map { ["runs": [["text": $0]]] } as Any,
                    "contents": Self.makeSongItems(count: songs),
                ].compactMapValues { $0 },
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
        shortSubscriberCount: String? = nil,
        subscribedButtonText: String? = nil,
        unsubscribedButtonText: String? = nil,
        monthlyAudience: String? = nil
    ) -> [String: Any] {
        var subscribeButtonRenderer: [String: Any] = [
            "channelId": "UC-extracted",
            "subscribed": isSubscribed,
            "subscriberCountText": [
                "runs": [["text": subscriberCount]],
            ],
        ]

        if let shortSubscriberCount {
            subscribeButtonRenderer["shortSubscriberCountText"] = [
                "runs": [["text": shortSubscriberCount]],
            ]
        }

        if let subscribedButtonText {
            subscribeButtonRenderer["subscribedButtonText"] = [
                "runs": [["text": subscribedButtonText]],
            ]
        }

        if let unsubscribedButtonText {
            subscribeButtonRenderer["unsubscribedButtonText"] = [
                "runs": [["text": unsubscribedButtonText]],
            ]
        }

        var header: [String: Any] = [
            "title": [
                "runs": [["text": name]],
            ],
            "subscriptionButton": [
                "subscribeButtonRenderer": subscribeButtonRenderer,
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

    private static func makeArtistResponseWithCarousels(_ carousels: [(title: String, items: [[String: Any]])]) -> [String: Any] {
        let sectionContents: [[String: Any]] = carousels.map { carousel in
            [
                "musicCarouselShelfRenderer": [
                    "header": [
                        "musicCarouselShelfBasicHeaderRenderer": [
                            "title": [
                                "runs": [["text": carousel.title]],
                            ],
                        ],
                    ],
                    "contents": carousel.items,
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

    private static func firstSection(of detail: ArtistDetail, matching title: String) -> ArtistDetailSection? {
        detail.orderedSections.first { $0.title == title }
    }

    private static func albums(in detail: ArtistDetail, titled title: String) -> [Album]? {
        guard let section = self.firstSection(of: detail, matching: title),
              case let .albums(albums) = section.content
        else {
            return nil
        }
        return albums
    }

    private static func playlists(in detail: ArtistDetail, titled title: String) -> [Playlist]? {
        guard let section = self.firstSection(of: detail, matching: title),
              case let .playlists(playlists) = section.content
        else {
            return nil
        }
        return playlists
    }

    private static func artists(in detail: ArtistDetail, titled title: String) -> [Artist]? {
        guard let section = self.firstSection(of: detail, matching: title),
              case let .artists(artists) = section.content
        else {
            return nil
        }
        return artists
    }

    private static func makePlaylistCarouselItem(id: String, title: String, author: String) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": [
                    "runs": [["text": title]],
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
                        "browseId": id,
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

    private static func makeArtistCarouselItem(id: String, name: String, subtitle: String = "156M monthly audience", pageType: String = "MUSIC_PAGE_TYPE_ARTIST") -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": [
                    "runs": [[
                        "text": name,
                        "navigationEndpoint": [
                            "browseEndpoint": [
                                "browseId": id,
                                "browseEndpointContextSupportedConfigs": [
                                    "browseEndpointContextMusicConfig": [
                                        "pageType": pageType,
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
                                "pageType": pageType,
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
        sectionTitle: String,
        pageType: String = "MUSIC_PAGE_TYPE_ARTIST"
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
                                            "pageType": pageType,
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
                                    "pageType": pageType,
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

    private static func makeArtistSongsResponse(songCount: Int, displayPolicies: [String?]? = nil) -> [String: Any] {
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
                                                    "contents": self.makeSongItems(count: songCount, displayPolicies: displayPolicies),
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

    private static func makeSongItems(count: Int, displayPolicies: [String?]? = nil) -> [[String: Any]] {
        (0 ..< count).map { index in
            var renderer: [String: Any] = [
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
            ]

            if let displayPolicies,
               index < displayPolicies.count,
               let displayPolicy = displayPolicies[index]
            {
                renderer["musicItemRendererDisplayPolicy"] = displayPolicy
            }

            return [
                "musicResponsiveListItemRenderer": renderer,
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

    /// Loads a JSON fixture bundled with the test target and decodes it to a
    /// plain dictionary. Fixtures live in `Tests/KasetTests/Fixtures/` and are
    /// exposed via `Bundle.module` by SwiftPM's `.process("Fixtures")` rule.
    private static func loadArtistFixture(_ name: String) throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw FixtureError.notFound(name)
        }
        let raw = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw FixtureError.invalidJSON(name)
        }
        return dict
    }

    private enum FixtureError: Error {
        case notFound(String)
        case invalidJSON(String)
    }
}

// swiftlint:enable type_body_length file_length
