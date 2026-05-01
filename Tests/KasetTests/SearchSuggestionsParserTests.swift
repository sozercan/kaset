import Foundation
import Testing
@testable import Kaset

/// Tests for SearchSuggestionsParser.
@Suite(.tags(.parser))
struct SearchSuggestionsParserTests {
    // MARK: - Empty Response Tests

    @Test("Parse empty response returns empty array")
    func parseEmptyResponse() {
        let data: [String: Any] = [:]
        let suggestions = SearchSuggestionsParser.parse(data)
        #expect(suggestions.isEmpty)
    }

    @Test("Parse empty contents returns empty array")
    func parseEmptyContents() {
        let data: [String: Any] = ["contents": []]
        let suggestions = SearchSuggestionsParser.parse(data)
        #expect(suggestions.isEmpty)
    }

    // MARK: - Valid Response Tests

    @Test("Parse single suggestion")
    func parseSingleSuggestion() {
        let data = self.makeSuggestionsResponse(queries: ["test query"])
        let suggestions = SearchSuggestionsParser.parse(data)

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.query == "test query")
    }

    @Test("Parse multiple suggestions")
    func parseMultipleSuggestions() {
        let data = self.makeSuggestionsResponse(queries: [
            "taylor swift",
            "taylor swift anti hero",
            "taylor swift shake it off",
        ])
        let suggestions = SearchSuggestionsParser.parse(data)

        #expect(suggestions.count == 3)
        #expect(suggestions[0].query == "taylor swift")
        #expect(suggestions[1].query == "taylor swift anti hero")
        #expect(suggestions[2].query == "taylor swift shake it off")
    }

    @Test("Parse duplicate suggestions keeps first occurrence")
    func parseDuplicateSuggestionsKeepsFirstOccurrence() {
        let data = self.makeSuggestionsResponse(queries: [
            "taylor swift",
            "taylor swift songs",
            "taylor swift",
            "taylor swift playlist",
        ])
        let suggestions = SearchSuggestionsParser.parse(data)

        #expect(suggestions.map(\.query) == [
            "taylor swift",
            "taylor swift songs",
            "taylor swift playlist",
        ])
    }

    @Test("Parse duplicate suggestions across sections keeps first occurrence")
    func parseDuplicateSuggestionsAcrossSectionsKeepsFirstOccurrence() {
        let data: [String: Any] = [
            "contents": [
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": [
                            self.makeSearchSuggestionItem(query: "taylor swift"),
                            self.makeSearchSuggestionItem(query: "taylor swift songs"),
                        ],
                    ],
                ],
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": [
                            self.makeSearchSuggestionItem(query: "taylor swift"),
                            self.makeSearchSuggestionItem(query: "taylor swift playlist"),
                        ],
                    ],
                ],
            ],
        ]

        let suggestions = SearchSuggestionsParser.parse(data)

        #expect(suggestions.map(\.query) == [
            "taylor swift",
            "taylor swift songs",
            "taylor swift playlist",
        ])
    }

    @Test("Parse duplicate history and search suggestions keeps first occurrence")
    func parseDuplicateHistoryAndSearchSuggestionsKeepsFirstOccurrence() {
        let data: [String: Any] = [
            "contents": [
                [
                    "searchSuggestionsSectionRenderer": [
                        "contents": [
                            self.makeHistorySuggestionItem(query: "recent search"),
                            self.makeSearchSuggestionItem(query: "recent search"),
                            self.makeSearchSuggestionItem(query: "new search"),
                        ],
                    ],
                ],
            ],
        ]

        let suggestions = SearchSuggestionsParser.parse(data)

        #expect(suggestions.map(\.query) == [
            "recent search",
            "new search",
        ])
    }

    @Test("Parse suggestion with multiple runs joins text")
    func parseSuggestionWithMultipleRuns() {
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

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.query == "taylor swift")
    }

    @Test("Parse history suggestion")
    func parseHistorySuggestion() {
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

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.query == "recent search")
    }

    // MARK: - Edge Cases

    @Test("Empty suggestion text is skipped")
    func parseEmptySuggestionTextIsSkipped() {
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
        #expect(suggestions.isEmpty)
    }

    @Test("Missing suggestion key is skipped")
    func parseMissingSuggestionKeyIsSkipped() {
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
        #expect(suggestions.isEmpty)
    }

    @Test("Unknown renderer is skipped")
    func parseUnknownRendererIsSkipped() {
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
        #expect(suggestions.isEmpty)
    }

    // MARK: - SearchSuggestion Model Tests

    @Test("Suggestions have unique IDs")
    func suggestionHasUniqueId() {
        let suggestion1 = SearchSuggestion(query: "test")
        let suggestion2 = SearchSuggestion(query: "test")

        #expect(suggestion1.id != suggestion2.id)
    }

    @Test("Suggestion with explicit ID")
    func suggestionWithExplicitId() {
        let suggestion = SearchSuggestion(id: "custom-id", query: "test query")

        #expect(suggestion.id == "custom-id")
        #expect(suggestion.query == "test query")
    }

    @Test("Suggestion is hashable")
    func suggestionIsHashable() {
        let suggestion = SearchSuggestion(id: "id1", query: "test")
        var set = Set<SearchSuggestion>()
        set.insert(suggestion)

        #expect(set.contains(suggestion))
    }

    // MARK: - Helpers

    private func makeSuggestionsResponse(queries: [String]) -> [String: Any] {
        let suggestionItems = queries.map { query in
            self.makeSearchSuggestionItem(query: query)
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

    private func makeSearchSuggestionItem(query: String) -> [String: Any] {
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

    private func makeHistorySuggestionItem(query: String) -> [String: Any] {
        [
            "historySuggestionRenderer": [
                "suggestion": [
                    "runs": [
                        ["text": query],
                    ],
                ],
            ],
        ]
    }
}
