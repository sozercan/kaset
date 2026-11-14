import Foundation
import Testing
@testable import Kaset

// MARK: - TrackCreditsParserTests

@Suite(.tags(.parser))
struct TrackCreditsParserTests {
    @Test("Credits dialog sections keep server order and split names on newline runs")
    func parsesSections() throws {
        let credits = try TrackCreditsParser.parse(Self.loadFixture("track_credits"))

        #expect(credits.title == "Song credits")
        #expect(credits.sections.map(\.title) == ["Performed by", "Written by", "Produced by", "Music metadata provided by"])
        #expect(credits.sections[1].names == ["Writer One", "Writer Two", "Writer Three"])
        #expect(credits.sections[2].names == ["Producer One"])
        #expect(credits.isAvailable)
    }

    @Test("Sections without a title or names are dropped")
    func dropsEmptySections() {
        let data: [String: Any] = Self.dialog(sections: [
            Self.section(title: "Performed by", names: ["Test Artist"]),
            Self.section(title: "Written by", names: ["\n", " "]),
            Self.section(title: " ", names: ["Orphan"]),
        ])

        let credits = TrackCreditsParser.parse(data)

        #expect(credits.sections == [TrackCredits.Section(title: "Performed by", names: ["Test Artist"])])
    }

    @Test("A response without a credits dialog is unavailable")
    func missingDialogIsUnavailable() {
        let credits = TrackCreditsParser.parse(["contents": [:]])

        #expect(credits == .unavailable)
        #expect(!credits.isAvailable)
    }

    @Test("Credits browse IDs prefix the video ID with MPTC")
    func browseId() {
        #expect(ParsingHelpers.trackCreditsBrowseId(forVideoId: "abc123") == "MPTCabc123")
    }

    // MARK: - Helpers

    private static func loadFixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func dialog(sections: [[String: Any]]) -> [String: Any] {
        [
            "onResponseReceivedActions": [
                ["openPopupAction": ["popup": ["dismissableDialogRenderer": ["sections": sections]]]],
            ],
        ]
    }

    private static func section(title: String, names: [String]) -> [String: Any] {
        [
            "dismissableDialogContentSectionRenderer": [
                "title": ["runs": [["text": title]]],
                "subtitle": ["runs": names.map { ["text": $0] }],
            ],
        ]
    }
}
