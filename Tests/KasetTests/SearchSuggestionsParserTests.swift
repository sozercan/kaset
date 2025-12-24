import Foundation
import Testing
@testable import Kaset

/// Tests for SearchSuggestionsParser.
@Suite
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
    func parseSingleSuggestion() throws {
        let data = makeSuggestionsResponse(queries: ["test query"])
        let suggestions = SearchSuggestionsParser.parse(data)

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.query == "test query")
    }

    @Test("Parse multiple suggestions")
    func parseMultipleSuggestions() {
        let data = makeSuggestionsResponse(queries: [
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

    @Test("Parse suggestion with multiple runs joins text")
    func parseSuggestionWithMultipleRuns() throws {
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
    func parseHistorySuggestion() throws {
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
