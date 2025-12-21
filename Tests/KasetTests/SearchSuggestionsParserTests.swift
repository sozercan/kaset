import XCTest
@testable import Kaset

/// Tests for SearchSuggestionsParser.
final class SearchSuggestionsParserTests: XCTestCase {
    // MARK: - Empty Response Tests

    func testParseEmptyResponse() {
        let data: [String: Any] = [:]
        let suggestions = SearchSuggestionsParser.parse(data)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testParseEmptyContents() {
        let data: [String: Any] = ["contents": []]
        let suggestions = SearchSuggestionsParser.parse(data)
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - Valid Response Tests

    func testParseSingleSuggestion() {
        let data = self.makeSuggestionsResponse(queries: ["test query"])
        let suggestions = SearchSuggestionsParser.parse(data)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.query, "test query")
    }

    func testParseMultipleSuggestions() {
        let data = self.makeSuggestionsResponse(queries: [
            "taylor swift",
            "taylor swift anti hero",
            "taylor swift shake it off",
        ])
        let suggestions = SearchSuggestionsParser.parse(data)

        XCTAssertEqual(suggestions.count, 3)
        XCTAssertEqual(suggestions[0].query, "taylor swift")
        XCTAssertEqual(suggestions[1].query, "taylor swift anti hero")
        XCTAssertEqual(suggestions[2].query, "taylor swift shake it off")
    }

    func testParseSuggestionWithMultipleRuns() {
        // Simulates bold text formatting where query is split into runs
        let data: [String: Any] = [
            "contents": [
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": [
                            [
                                "searchSuggestionRenderer": [
                                    "suggestion": [
                                        "runs": [
                                            ["text": "taylor "],
                                            ["text": "swift"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let suggestions = SearchSuggestionsParser.parse(data)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.query, "taylor swift")
    }

    func testParseHistorySuggestion() {
        let data: [String: Any] = [
            "contents": [
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": [
                            [
                                "historySuggestionRenderer": [
                                    "suggestion": [
                                        "runs": [
                                            ["text": "recent search"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let suggestions = SearchSuggestionsParser.parse(data)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.query, "recent search")
    }

    // MARK: - Edge Cases

    func testParseEmptySuggestionTextIsSkipped() {
        let data: [String: Any] = [
            "contents": [
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": [
                            [
                                "searchSuggestionRenderer": [
                                    "suggestion": [
                                        "runs": [
                                            ["text": ""],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let suggestions = SearchSuggestionsParser.parse(data)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testParseMissingSuggestionKeyIsSkipped() {
        let data: [String: Any] = [
            "contents": [
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": [
                            [
                                "searchSuggestionRenderer": [
                                    "otherKey": "value",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let suggestions = SearchSuggestionsParser.parse(data)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testParseUnknownRendererIsSkipped() {
        let data: [String: Any] = [
            "contents": [
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": [
                            [
                                "unknownRenderer": [
                                    "suggestion": [
                                        "runs": [["text": "test"]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let suggestions = SearchSuggestionsParser.parse(data)
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - SearchSuggestion Model Tests

    func testSuggestionHasUniqueId() {
        let suggestion1 = SearchSuggestion(query: "test")
        let suggestion2 = SearchSuggestion(query: "test")

        XCTAssertNotEqual(suggestion1.id, suggestion2.id)
    }

    func testSuggestionWithExplicitId() {
        let suggestion = SearchSuggestion(id: "custom-id", query: "test query")

        XCTAssertEqual(suggestion.id, "custom-id")
        XCTAssertEqual(suggestion.query, "test query")
    }

    func testSuggestionIsHashable() {
        let suggestion = SearchSuggestion(id: "id1", query: "test")
        var set = Set<SearchSuggestion>()
        set.insert(suggestion)

        XCTAssertTrue(set.contains(suggestion))
    }

    // MARK: - Helpers

    /// Creates a mock suggestions API response.
    private func makeSuggestionsResponse(queries: [String]) -> [String: Any] {
        let suggestionItems = queries.map { query in
            [
                "searchSuggestionRenderer": [
                    "suggestion": [
                        "runs": [
                            ["text": query],
                        ],
                    ],
                ],
            ]
        }

        return [
            "contents": [
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": suggestionItems,
                    ],
                ],
            ],
        ]
    }
}
