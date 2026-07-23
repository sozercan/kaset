import Testing
@testable import Kaset

struct ParsingHelpersArtistExtractionRegressionTests {
    @Test("Extract artists excludes content labels, play counts, and durations")
    func extractArtistsExcludesMetadata() {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    ["text": "Video"],
                    ["text": " • "],
                    ["text": "Alice Cooper", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCalice"]]],
                    ["text": " • "],
                    ["text": "455M plays"],
                    ["text": " • "],
                    ["text": "1 view"],
                    ["text": " • "],
                    ["text": "1 play"],
                    ["text": " • "],
                    ["text": "1 subscriber"],
                    ["text": " • "],
                    ["text": "1 episode"],
                    ["text": " • "],
                    ["text": "No views"],
                    ["text": " • "],
                    ["text": "4:29"],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.map(\.name) == ["Alice Cooper"])
    }

    @Test(
        "Extract artists rejects singular engagement counts without an artist",
        arguments: ["1 view", "1 play", "1 subscriber", "1 episode"]
    )
    func extractArtistsRejectsSingularEngagementCounts(_ count: String) {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    ["text": "Video"],
                    ["text": " • "],
                    ["text": count],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.isEmpty)
    }

    @Test("Extract artists preserves plain names that contain engagement words")
    func extractArtistsPreservesPlainEngagementWordNames() {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    ["text": "Fair Play"],
                    ["text": " & "],
                    ["text": "A View"],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.map(\.name) == ["Fair Play", "A View"])
    }

    @Test("Extract artists stops before localized trailing metadata")
    func extractArtistsStopsBeforeLocalizedMetadata() {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    ["text": "Vídeo"],
                    ["text": " • "],
                    ["text": "Artista sin enlace"],
                    ["text": " & "],
                    ["text": "A View"],
                    ["text": " • "],
                    ["text": "1,2 M de visualizaciones"],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.map(\.name) == ["Artista sin enlace", "A View"])
    }

    @Test(
        "Extract artists skips localized single labels before an unlinked artist",
        arguments: ["Single", "أغنية منفردة", "Sencillo", "Singel", "Singolo", "싱글", "Singiel", "Сингл", "Tekli"]
    )
    func extractArtistsSkipsLocalizedSingleLabels(_ label: String) {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    ["text": label],
                    ["text": " • "],
                    ["text": "Fixture Creator"],
                    ["text": " • "],
                    ["text": "1,2 M de visualizaciones"],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.map(\.name) == ["Fixture Creator"])
    }

    @Test("Extract artists preserves unlinked co-artists beside a linked artist")
    func extractArtistsPreservesMixedLinkedAndUnlinkedArtists() {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    ["text": "Primary", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCprimary"]]],
                    ["text": " & "],
                    ["text": "Featured"],
                    ["text": " • "],
                    ["text": "1.2M views"],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.map(\.name) == ["Primary", "Featured"])
    }

    @Test("Extract artists does not infer bullet-delimited metadata as a co-artist")
    func extractArtistsDoesNotInferMetadataFieldAsCoArtist() {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    ["text": "Primary", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCprimary"]]],
                    ["text": " • "],
                    ["text": "Album Name"],
                    ["text": " • "],
                    ["text": "2026"],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.map(\.name) == ["Primary"])
    }

    @Test("Extract artists preserves metadata-looking names with valid artist endpoints")
    func extractArtistsPreservesLinkedMetadataLookingNames() {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    ["text": "2002", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCyear"]]],
                    ["text": " • "],
                    ["text": "2:54", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCduration"]]],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.map(\.name) == ["2002", "2:54"])
    }

    @Test("Extract artists rejects non-artist browse endpoints")
    func extractArtistsRejectsNonArtistBrowseEndpoints() {
        let data: [String: Any] = [
            "subtitle": [
                "runs": [
                    [
                        "text": "Album Name",
                        "navigationEndpoint": [
                            "browseEndpoint": [
                                "browseId": "MPREalbum",
                                "browseEndpointContextSupportedConfigs": [
                                    "browseEndpointContextMusicConfig": [
                                        "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                                    ],
                                ],
                            ],
                        ],
                    ],
                    ["text": " • "],
                    ["text": "455M plays"],
                ],
            ],
        ]

        let artists = ParsingHelpers.extractArtists(from: data)

        #expect(artists.isEmpty)
    }
}
