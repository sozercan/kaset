import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.parser))
struct PlaylistAuthorParsingTests {
    @Test("Extracts creator from structured runs while dropping localized counts")
    func extractsCreatorWithoutLocalizedCounts() {
        let linkedRuns: [[String: Any]] = [
            ["text": "Playlist"],
            ["text": " • "],
            [
                "text": "DJ Nova",
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": "UCcreator123",
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_USER_CHANNEL",
                            ],
                        ],
                    ],
                ],
            ],
            ["text": " • "],
            ["text": "42 şarkı"],
        ]

        let linked = ParsingHelpers.extractPlaylistAuthor(from: linkedRuns)
        #expect(linked?.name == "DJ Nova")
        #expect(linked?.id == "UCcreator123")
        #expect(linked?.hasNavigableId == true)

        let plainCreatorRuns: [[String: Any]] = [
            ["text": "Playlist"],
            ["text": " • "],
            ["text": "Kaset Curated"],
            ["text": " • "],
            ["text": "120 canciones"],
        ]
        let plain = ParsingHelpers.extractPlaylistAuthor(from: plainCreatorRuns)
        #expect(plain?.name == "Kaset Curated")

        let countOnlyRuns: [[String: Any]] = [
            ["text": "Playlist"],
            ["text": " • "],
            ["text": "25 曲"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: countOnlyRuns) == nil)

        let numericCreatorRuns: [[String: Any]] = [
            ["text": "Playlist"],
            ["text": " • "],
            ["text": "DJ 123"],
            ["text": " • "],
            ["text": "42 songs"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: numericCreatorRuns)?.name == "DJ 123")

        let numericLeadingCreatorRuns: [[String: Any]] = [
            ["text": "Playlist"],
            ["text": " • "],
            ["text": "123 Records"],
            ["text": " • "],
            ["text": "42 songs"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: numericLeadingCreatorRuns)?.name == "123 Records")

        let numericLeadingFinalCreatorRuns: [[String: Any]] = [
            ["text": "Playlist"],
            ["text": " • "],
            ["text": "123 Records"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: numericLeadingFinalCreatorRuns)?.name == "123 Records")

        let magnitudeCountOnlyRuns: [[String: Any]] = [
            ["text": "Lista de reproducción"],
            ["text": " • "],
            ["text": "1,2 mil canciones"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: magnitudeCountOnlyRuns) == nil)

        let narrowSpaceCountOnlyRuns: [[String: Any]] = [
            ["text": "Lista de reproducción"],
            ["text": " • "],
            ["text": "1\u{202F}234 canciones"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: narrowSpaceCountOnlyRuns) == nil)
    }

    @Test("Handles embedded separators, localized CJK playlist labels, and artist carousel playlists")
    func handlesEmbeddedSeparatorsAndLocalizedLabels() throws {
        let embeddedRun: [[String: Any]] = [
            ["text": "Playlist · Kaset Curated · 120 canciones"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: embeddedRun)?.name == "Kaset Curated")

        let punctuatedCreatorRuns: [[String: Any]] = [
            ["text": "DJ · Nova"],
            ["text": " • "],
            ["text": "42 songs"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: punctuatedCreatorRuns)?.name == "DJ · Nova")

        let creatorOnlyPunctuatedRun: [[String: Any]] = [
            ["text": "DJ · Nova"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: creatorOnlyPunctuatedRun)?.name == "DJ · Nova")

        let japaneseCountOnly: [[String: Any]] = [
            ["text": "プレイリスト"],
            ["text": " • "],
            ["text": "25 曲"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: japaneseCountOnly) == nil)

        let japaneseWithCreator: [[String: Any]] = [
            ["text": "プレイリスト"],
            ["text": " • "],
            ["text": "DJ Haru"],
            ["text": " • "],
            ["text": "25 曲"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: japaneseWithCreator)?.name == "DJ Haru")

        let chineseCountOnly: [[String: Any]] = [
            ["text": "播放列表"],
            ["text": " • "],
            ["text": "18 首歌曲"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: chineseCountOnly) == nil)

        let chineseWithCreator: [[String: Any]] = [
            ["text": "歌单"],
            ["text": " • "],
            ["text": "Studio Lin"],
        ]
        #expect(ParsingHelpers.extractPlaylistAuthor(from: chineseWithCreator)?.name == "Studio Lin")

        let legacyFlattened = ParsingHelpers.normalizedLegacyPlaylistAuthorName("Test User • 145 songs")
        #expect(legacyFlattened == "Test User")
        #expect(ParsingHelpers.normalizedLegacyPlaylistAuthorName("DJ · Nova") == "DJ · Nova")
        #expect(ParsingHelpers.normalizedLegacyPlaylistAuthorName("DJ · Nova • 145 songs") == "DJ · Nova")
        #expect(ParsingHelpers.normalizedLegacyPlaylistAuthorName("Playlist • DJ · Nova • 145 songs") == "DJ · Nova")
        #expect(ParsingHelpers.normalizedLegacyPlaylistAuthorName("Playlist • 25 曲") == nil)

        let artistResponse: [String: Any] = [
            "header": [
                "musicImmersiveHeaderRenderer": [
                    "title": ["runs": [["text": "Sample Artist"]]],
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
                                                    "title": ["runs": [["text": "Featured on"]]],
                                                ],
                                            ],
                                            "contents": [[
                                                "musicTwoRowItemRenderer": [
                                                    "title": ["runs": [["text": "Japanese Mix"]]],
                                                    "subtitle": ["runs": [
                                                        ["text": "Playlist"],
                                                        ["text": " • "],
                                                        ["text": "25 曲"],
                                                    ]],
                                                    "navigationEndpoint": [
                                                        "browseEndpoint": [
                                                            "browseId": "VLPLartistcarousel1",
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
        let detail = ArtistParser.parseArtistDetail(artistResponse, artistId: "UCartist1")
        let playlist = try #require(
            detail.orderedSections.flatMap { section -> [Playlist] in
                if case let .playlists(playlists) = section.content {
                    return playlists
                }
                return []
            }.first
        )
        #expect(playlist.author == nil)
    }
}
