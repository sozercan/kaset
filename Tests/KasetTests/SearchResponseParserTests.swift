import Foundation
import Testing
@testable import Kaset

// MARK: - SearchResponseParserTests

@Suite(.tags(.parser))
struct SearchResponseParserTests {
    @Test("Direct item-section search roots preserve server order")
    func directItemSectionRootPreservesServerOrder() throws {
        let data = try Self.loadFixture("search_direct_item_section")

        let response = SearchResponseParser.parse(data)

        #expect(response.allItems.map(\.id) == [
            "song-direct-song-video",
            "album-MPREdirect-album",
        ])
    }

    @Test("Tabbed mixed search preserves order and first-occurrence identity")
    func tabbedMixedSearchPreservesOrderAndDeduplicates() throws {
        let data = try Self.loadFixture("search_tabbed_mixed")

        let response = SearchResponseParser.parse(data)

        #expect(response.allItems.map(\.id) == [
            "profile-UCtop-profile",
            "video-official-source-video",
            "podcast-MPSPPfixture-show",
            "episode-fixture-episode-video",
            "playlist-VLfixture-playlist",
        ])
        #expect(response.videos.first?.title == "Official Source Video")
        #expect(!response.allItems.contains { $0.videoId == "menu-only-video" })
    }

    @Test("Top Result browse semantics win and nested official-source video parses")
    func topResultBrowseSemanticsWinOverWatchFallbacks() throws {
        let data = try Self.loadFixture("search_tabbed_mixed")

        let response = SearchResponseParser.parse(data)

        let profile = try #require(response.profiles.first)
        #expect(profile.id == "UCtop-profile")
        #expect(profile.subtitle == "42K subscribers")

        let video = try #require(response.videos.first)
        #expect(video.videoId == "official-source-video")
        #expect(video.musicVideoType == .officialSourceMusic)
        #expect(video.hasVideo != true)
    }

    @Test("Mixed search parses podcast shows and episodes")
    func mixedSearchParsesPodcastShowsAndEpisodes() throws {
        let data = try Self.loadFixture("search_tabbed_mixed")

        let response = SearchResponseParser.parse(data)

        let show = try #require(response.podcastShows.first)
        #expect(show.id == "MPSPPfixture-show")
        #expect(show.author == "Fixture Network")

        let episode = try #require(response.podcastEpisodes.first)
        #expect(episode.id == "fixture-episode-video")
        #expect(episode.showTitle == "Fixture Podcast")
        #expect(episode.showBrowseId == "MPSPPfixture-show")
        #expect(episode.publishedDate == "Jul 18, 2026")
        #expect(episode.duration == "42:10")
        #expect(episode.durationSeconds == 2530)
    }

    @Test("First-page search reads shelf-level next continuation")
    func firstPageReadsShelfNextContinuation() throws {
        let data = try Self.loadFixture("search_tabbed_mixed")

        let response = SearchResponseParser.parse(data)

        #expect(response.continuationToken == "sanitized-next-page-token")
    }

    @Test("Audiobook page types remain semantically distinct from albums")
    func audiobookPageTypeParses() {
        let data: [String: Any] = [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "itemSectionRenderer": [
                            "contents": [[
                                "musicResponsiveListItemRenderer": [
                                    "navigationEndpoint": [
                                        "browseEndpoint": [
                                            "browseId": "MPREb_audiobook",
                                            "browseEndpointContextSupportedConfigs": [
                                                "browseEndpointContextMusicConfig": [
                                                    "pageType": "MUSIC_PAGE_TYPE_AUDIOBOOK",
                                                ],
                                            ],
                                        ],
                                    ],
                                    "flexColumns": [
                                        [
                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                "text": ["runs": [["text": "Fixture Audiobook"]]],
                                            ],
                                        ],
                                        [
                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                "text": ["runs": [
                                                    ["text": "Audiobook"],
                                                    ["text": " • "],
                                                    ["text": "Fixture Narrator"],
                                                ]],
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

        let response = SearchResponseParser.parse(data)

        #expect(response.allItems.map(\.id) == ["audiobook-MPREb_audiobook"])
        #expect(response.audiobooks.map(\.title) == ["Fixture Audiobook"])
        #expect(response.audiobooks.map(\.artistsDisplay) == ["Fixture Narrator"])
        #expect(response.albums.isEmpty)
    }

    @Test("Top Result watch destinations parse from title, onTap, and thumbnail overlay")
    func topResultWatchEndpointSourcesParse() throws {
        let data = try Self.loadFixture("search_top_result_watch_endpoints")

        let response = SearchResponseParser.parse(data)

        #expect(response.videos.map(\.videoId) == [
            "title-endpoint-video",
            "on-tap-video",
            "thumbnail-overlay-video",
        ])
        #expect(response.videos.map(\.musicVideoType) == [
            .omv,
            .ugc,
            .officialSourceMusic,
        ])
    }

    @Test("First-page shelves accept reload and continuation-item tokens")
    func firstPageReadsAlternateShelfContinuationCarriers() {
        let reloadResponse = SearchResponseParser.parse(Self.makeContinuationCarrierData(
            ["reloadContinuationData": ["continuation": "sanitized-reload-token"]]
        ))
        let itemResponse = SearchResponseParser.parse(Self.makeContinuationItemData(
            token: "sanitized-item-token"
        ))

        #expect(reloadResponse.continuationToken == "sanitized-reload-token")
        #expect(itemResponse.continuationToken == "sanitized-item-token")
    }

    @Test("Music shelf continuations preserve order, identity, and next token")
    func musicShelfContinuationParsesOrderedItems() throws {
        let data = try Self.loadFixture("search_music_shelf_continuation")

        let response = SearchResponseParser.parseContinuation(data)

        #expect(response.allItems.map(\.id) == [
            "song-continuation-song",
            "profile-UCcontinuation-profile",
        ])
        #expect(response.songs.first?.title == "Continuation Song")
        #expect(response.videos.isEmpty)
        #expect(response.continuationToken == "sanitized-continuation-item-token")
    }

    @Test(
        "Action-envelope continuations preserve order, identity, and next token",
        arguments: [
            ("onResponseReceivedActions", "appendContinuationItemsAction"),
            ("onResponseReceivedCommands", "reloadContinuationItemsCommand"),
            ("onResponseReceivedEndpoints", "appendContinuationItemsAction"),
        ]
    )
    func actionEnvelopeContinuationParsesOrderedItems(
        envelopeKey: String,
        commandKey: String
    ) throws {
        let fixture = try Self.loadFixture("search_music_shelf_continuation")
        let continuationContents = try #require(fixture["continuationContents"] as? [String: Any])
        let shelf = try #require(continuationContents["musicShelfContinuation"] as? [String: Any])
        let items = try #require(shelf["contents"] as? [[String: Any]])
        let actions = items.map { item in
            [commandKey: ["continuationItems": [item]]]
        }

        let response = SearchResponseParser.parseContinuation([envelopeKey: actions])

        #expect(response.allItems.map(\.id) == [
            "song-continuation-song",
            "profile-UCcontinuation-profile",
        ])
        #expect(response.continuationToken == "sanitized-continuation-item-token")
    }

    @Test("Untyped video cards preserve semantic classification and plain artist names")
    func untypedVideoCardsPreserveSemanticMetadata() {
        let data = Self.makeUntypedVideoCardData(artists: [
            "Coldplay",
            "Maroon 5",
            "The Midnight",
        ])

        let response = SearchResponseParser.parse(data)

        #expect(response.videos.map(\.artistsDisplay) == [
            "Coldplay",
            "Maroon 5",
            "The Midnight",
        ])
        #expect(response.videos.allSatisfy { $0.hasVideo != true })
    }

    @Test("Multi-row second subtitles contribute semantic metadata")
    func multiRowSecondSubtitleParses() {
        let response = SearchResponseParser.parse(Self.makeSecondSubtitleVideoData())

        #expect(response.videos.map(\.videoId) == ["second-subtitle-video"])
        #expect(response.videos.map(\.artistsDisplay) == ["Fixture Creator"])
        #expect(response.songs.isEmpty)
    }

    @Test("Middle-dot metadata preserves semantic video and creator parsing")
    func middleDotMetadataParses() {
        let data: [String: Any] = [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "musicCardShelfRenderer": [
                            "title": ["runs": [["text": "Middle Dot Video"]]],
                            "subtitle": ["runs": [["text": "Video · Fixture Creator"]]],
                            "onTap": ["watchEndpoint": ["videoId": "middle-dot-video"]],
                        ],
                    ]],
                ],
            ],
        ]

        let response = SearchResponseParser.parse(data)

        #expect(response.videos.map(\.videoId) == ["middle-dot-video"])
        #expect(response.videos.map(\.artistsDisplay) == ["Fixture Creator"])
    }

    @Test("Relative podcast dates do not replace episode duration")
    func relativePodcastDateDoesNotReplaceDuration() {
        let response = SearchResponseParser.parse(Self.makeRelativeDateEpisodeData())

        let episode = response.podcastEpisodes.first
        #expect(episode?.publishedDate == "2 hours ago")
        #expect(episode?.duration == "36 min")
        #expect(episode?.durationSeconds == 2160)
    }

    @Test(
        "Localized episode dates and durations preserve metadata",
        arguments: [
            ("2시간 전", "36분", 2160),
            ("vor 2 Stunden", "45 Min", 2700),
            ("منذ ٣ ساعات", "٣٦ دقيقة", 2160),
            ("19 lipca", "36 min", 2160),
            ("19 июля", "36 мин.", 2160),
            ("12 maart", "36 min", 2160),
            ("12 aprile", "36 min", 2160),
        ]
    )
    func localizedEpisodeMetadataParses(
        publishedDate: String,
        duration: String,
        expectedSeconds: Int
    ) {
        let response = SearchResponseParser.parse(Self.makeRelativeDateEpisodeData(
            publishedDate: publishedDate,
            duration: duration
        ))

        let episode = response.podcastEpisodes.first
        #expect(episode?.publishedDate == publishedDate)
        #expect(episode?.duration == duration)
        #expect(episode?.durationSeconds == expectedSeconds)
    }

    @Test(
        "Fallback show names containing count words are preserved",
        arguments: ["Song Exploder", "Gameplay"]
    )
    func countWordsWithoutNumbersRemainShowNames(showTitle: String) {
        let response = SearchResponseParser.parse(Self.makeRelativeDateEpisodeData(
            showTitle: showTitle,
            showBrowseId: nil
        ))

        #expect(response.podcastEpisodes.first?.showTitle == showTitle)
    }

    @Test("Radio browse IDs remain playlists ahead of watch fallbacks")
    func radioBrowseIdsPreservePlaylistSemantics() {
        let response = SearchResponseParser.parse(Self.makeRadioBrowseData(
            browseIds: ["RDfixture-radio", "VMfixture-mix"]
        ))

        #expect(response.playlists.map(\.id) == ["RDfixture-radio", "VMfixture-mix"])
        #expect(response.videos.isEmpty)
        #expect(response.songs.isEmpty)
    }

    @Test("Localized type labels preserve video and podcast semantics")
    func localizedTypeLabelsPreserveSemantics() {
        let response = SearchResponseParser.parse(Self.makeLocalizedSemanticData())

        #expect(response.videos.map(\.videoId) == ["localized-video"])
        #expect(response.videos.first?.artistsDisplay == "Banda Ejemplo")
        #expect(response.podcastShows.first?.author == "Fixture Network")
    }

    @Test("Count-only subtitles do not create fallback authors")
    func countOnlySubtitlesDoNotCreateAuthors() {
        let response = SearchResponseParser.parse(Self.makeCountOnlyCreatorData())

        #expect(response.playlists.first?.trackCount == 12)
        #expect(response.playlists.first?.author == nil)
        #expect(response.podcastShows.first?.author == nil)
    }

    @Test("Localized count-only subtitles do not create fallback authors")
    func localizedCountOnlySubtitlesDoNotCreateAuthors() {
        let response = SearchResponseParser.parse(Self.makeCountOnlyCreatorData(
            playlistLabel: "Lista de reproducción",
            songCount: "1,2 mil canciones",
            podcastLabel: "Podcast",
            episodeCount: "1 234 episodios"
        ))

        #expect(response.playlists.first?.author == nil)
        #expect(response.podcastShows.first?.author == nil)

        let inflectedResponse = SearchResponseParser.parse(Self.makeCountOnlyCreatorData(
            playlistLabel: "Playlista",
            songCount: "12 utworów",
            podcastLabel: "Подкаст",
            episodeCount: "12 выпусков"
        ))
        #expect(inflectedResponse.playlists.first?.author == nil)
        #expect(inflectedResponse.podcastShows.first?.author == nil)
    }

    @Test("Playlist IDs in watch endpoints retain playlist semantics")
    func playlistWatchEndpointsPreserveSemantics() throws {
        let data = try Self.loadFixture("search_playlist_watch_endpoints")

        let response = SearchResponseParser.parse(data)

        #expect(response.playlists.map(\.id) == ["RDradio-watch", "VMplaylist-action"])
        #expect(response.albums.map(\.id) == ["MPREcanonical-album"])
        #expect(response.videos.isEmpty)
    }

    @Test("Later flex columns contribute ordered metadata")
    func laterFlexColumnsContributeMetadata() throws {
        let data = try Self.loadFixture("search_later_flex_columns")

        let response = SearchResponseParser.parse(data)

        #expect(response.albums.first?.year == "2026")
    }

    @Test("Parse empty response returns empty results")
    func parseEmptyResponse() {
        let data: [String: Any] = [:]
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.isEmpty)
        #expect(response.albums.isEmpty)
        #expect(response.artists.isEmpty)
        #expect(response.playlists.isEmpty)
    }

    @Test("Parse response with only songs")
    func parseSongResults() {
        let data = self.makeSearchResponseData(songs: 3, albums: 0, artists: 0, playlists: 0)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.count == 3)
        #expect(response.albums.isEmpty)
        #expect(response.artists.isEmpty)
        #expect(response.playlists.isEmpty)
    }

    @Test("Parse response with only albums")
    func parseAlbumResults() {
        let data = self.makeSearchResponseData(songs: 0, albums: 2, artists: 0, playlists: 0)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.isEmpty)
        #expect(response.albums.count == 2)
    }

    @Test("Parse response with only artists")
    func parseArtistResults() {
        let data = self.makeSearchResponseData(songs: 0, albums: 0, artists: 2, playlists: 0)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.isEmpty)
        #expect(response.artists.count == 2)
    }

    @Test("Parse response with only playlists")
    func parsePlaylistResults() {
        let data = self.makeSearchResponseData(songs: 0, albums: 0, artists: 0, playlists: 2)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.isEmpty)
        #expect(response.playlists.count == 2)
    }

    @Test("Parse response with mixed results")
    func parseMixedResults() {
        let data = self.makeSearchResponseData(songs: 2, albums: 1, artists: 1, playlists: 1)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.count == 2)
        #expect(response.albums.count == 1)
        #expect(response.artists.count == 1)
        #expect(response.playlists.count == 1)
    }

    @Test("Song has correct video ID")
    func songHasVideoId() {
        let data = self.makeSearchResponseData(songs: 1, albums: 0, artists: 0, playlists: 0)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.first?.videoId == "video0")
    }

    @Test("Parse library artist result using library artist page type")
    func parseLibraryArtistResult() {
        let data: [String: Any] = [
            "contents": [
                "tabbedSearchResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": [[
                                                "musicResponsiveListItemRenderer": [
                                                    "navigationEndpoint": [
                                                        "browseEndpoint": [
                                                            "browseId": "MPLAUC1234567890",
                                                            "browseEndpointContextSupportedConfigs": [
                                                                "browseEndpointContextMusicConfig": [
                                                                    "pageType": "MUSIC_PAGE_TYPE_LIBRARY_ARTIST",
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                    "flexColumns": [
                                                        [
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Library Artist"]]],
                                                            ],
                                                        ],
                                                        [
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Artist"]]],
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
        ]

        let response = SearchResponseParser.parse(data)

        #expect(response.artists.count == 1)
        #expect(response.artists.first?.id == "MPLAUC1234567890")
        #expect(response.artists.first?.name == "Library Artist")
        #expect(response.albums.isEmpty)
        #expect(response.playlists.isEmpty)
    }

    @Test("Parse song result propagates explicit badge")
    func parseSongPropagatesExplicitBadge() {
        let explicitItem: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "explicit-video"],
                "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Explicit Song"]]]]],
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist"]]]]],
                ],
                "badges": [[
                    "musicInlineBadgeRenderer": [
                        "icon": ["iconType": "MUSIC_EXPLICIT_BADGE"],
                    ],
                ]],
            ],
        ]
        let cleanItem: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "clean-video"],
                "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Clean Song"]]]]],
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist"]]]]],
                ],
            ],
        ]
        let data: [String: Any] = [
            "contents": [
                "tabbedSearchResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [["musicShelfRenderer": ["contents": [explicitItem, cleanItem]]]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]

        let response = SearchResponseParser.parse(data)

        #expect(response.songs.count == 2)
        let explicit = response.songs.first { $0.videoId == "explicit-video" }
        let clean = response.songs.first { $0.videoId == "clean-video" }
        #expect(explicit?.isExplicit == true)
        #expect(clean?.isExplicit == false)
    }
}

private extension SearchResponseParserTests {}
