import Foundation
import Testing
@testable import Kaset

/// Tests for the PodcastParser.
@Suite("PodcastParser", .tags(.parser))
struct PodcastParserTests {
    // MARK: - parseDiscovery Tests

    @Test("Parse empty response returns empty sections")
    func parseEmptyResponse() {
        let data: [String: Any] = [:]
        let sections = PodcastParser.parseDiscovery(data)
        #expect(sections.isEmpty)
    }

    @Test("Parse discovery response with carousel section")
    func parseDiscoveryWithCarouselSection() {
        let data = self.makeDiscoveryData(withCarousel: true, withShelf: false)
        let sections = PodcastParser.parseDiscovery(data)
        #expect(sections.count == 1)
        #expect(sections.first?.title == "Popular Podcasts")
    }

    @Test("Parse discovery response with music shelf section")
    func parseDiscoveryWithMusicShelfSection() {
        let data = self.makeDiscoveryData(withCarousel: false, withShelf: true)
        let sections = PodcastParser.parseDiscovery(data)
        #expect(sections.count == 1)
        #expect(sections.first?.title == "Episodes for You")
    }

    @Test("Parse discovery response with multiple sections")
    func parseDiscoveryWithMultipleSections() {
        let data = self.makeDiscoveryData(withCarousel: true, withShelf: true)
        let sections = PodcastParser.parseDiscovery(data)
        #expect(sections.count == 2)
    }

    // MARK: - parseContinuation Tests

    @Test("Parse empty continuation returns empty sections")
    func parseEmptyContinuation() {
        let data: [String: Any] = [:]
        let sections = PodcastParser.parseContinuation(data)
        #expect(sections.isEmpty)
    }

    @Test("Parse continuation response with sections")
    func parseContinuationWithSections() {
        let data = self.makeContinuationData(sectionCount: 2)
        let sections = PodcastParser.parseContinuation(data)
        #expect(sections.count == 2)
    }

    // MARK: - parseShowDetail Tests

    @Test("Parse empty show detail returns placeholder show")
    func parseEmptyShowDetail() {
        let data: [String: Any] = [:]
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")
        #expect(detail.show.id == "MPSPP123")
        #expect(detail.show.title == "Unknown Show")
        #expect(detail.episodes.isEmpty)
    }

    @Test("Parse show detail with header")
    func parseShowDetailWithHeader() {
        let data = self.makeShowDetailData(
            title: "Tech Podcast",
            author: "Tech Company",
            description: "A great tech podcast",
            episodeCount: 3
        )
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")
        #expect(detail.show.title == "Tech Podcast")
        #expect(detail.show.author == "Tech Company")
        #expect(detail.show.description == "A great tech podcast")
        #expect(detail.episodes.count == 3)
    }

    @Test("Parse show detail with subscription status")
    func parseShowDetailWithSubscriptionStatus() {
        let data = self.makeShowDetailData(title: "Subscribed Show", isSubscribed: true)
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")
        #expect(detail.isSubscribed == true)
    }

    @Test("Parse show detail with continuation token")
    func parseShowDetailWithContinuation() {
        let data = self.makeShowDetailData(title: "Long Show", continuationToken: "token123")
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")
        #expect(detail.continuationToken == "token123")
        #expect(detail.hasMore == true)
    }

    // MARK: - parseEpisodesContinuation Tests

    @Test("Parse empty episodes continuation")
    func parseEmptyEpisodesContinuation() {
        let data: [String: Any] = [:]
        let continuation = PodcastParser.parseEpisodesContinuation(data)
        #expect(continuation.episodes.isEmpty)
        #expect(continuation.continuationToken == nil)
        #expect(continuation.hasMore == false)
    }

    @Test("Parse episodes continuation with episodes")
    func parseEpisodesContinuationWithEpisodes() {
        let data = self.makeEpisodesContinuationData(episodeCount: 5, hasMore: true)
        let continuation = PodcastParser.parseEpisodesContinuation(data)
        #expect(continuation.episodes.count == 5)
        #expect(continuation.hasMore == true)
    }

    @Test("Parse episodes continuation without more pages")
    func parseEpisodesContinuationWithoutMore() {
        let data = self.makeEpisodesContinuationData(episodeCount: 2, hasMore: false)
        let continuation = PodcastParser.parseEpisodesContinuation(data)
        #expect(continuation.episodes.count == 2)
        #expect(continuation.hasMore == false)
    }

    // MARK: - isPodcastShow Tests

    @Test("isPodcastShow returns true for MPSPP prefix")
    func isPodcastShowWithMPSPPPrefix() {
        #expect(PodcastParser.isPodcastShow("MPSPP12345") == true)
    }

    @Test("isPodcastShow returns false for non-MPSPP prefix")
    func isPodcastShowWithOtherPrefix() {
        #expect(PodcastParser.isPodcastShow("VL12345") == false)
        #expect(PodcastParser.isPodcastShow("UC12345") == false)
        #expect(PodcastParser.isPodcastShow("MPRE12345") == false)
    }

    // MARK: - Test Data Helpers

    private func makeDiscoveryData(withCarousel: Bool, withShelf: Bool) -> [String: Any] {
        var sections: [[String: Any]] = []

        if withCarousel {
            sections.append([
                "musicCarouselShelfRenderer": [
                    "header": [
                        "musicCarouselShelfBasicHeaderRenderer": [
                            "title": ["runs": [["text": "Popular Podcasts"]]],
                        ],
                    ],
                    "contents": [self.makePodcastShowItem(id: "MPSPP1", title: "Show 1")],
                ],
            ])
        }

        if withShelf {
            sections.append([
                "musicShelfRenderer": [
                    "title": ["runs": [["text": "Episodes for You"]]],
                    "contents": [self.makeEpisodeItem(id: "ep1", title: "Episode 1")],
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
                                    "contents": sections,
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeContinuationData(sectionCount: Int) -> [String: Any] {
        var sections: [[String: Any]] = []
        for i in 0 ..< sectionCount {
            sections.append([
                "musicCarouselShelfRenderer": [
                    "header": [
                        "musicCarouselShelfBasicHeaderRenderer": [
                            "title": ["runs": [["text": "Section \(i)"]]],
                        ],
                    ],
                    "contents": [self.makePodcastShowItem(id: "MPSPP\(i)", title: "Show \(i)")],
                ],
            ])
        }

        return [
            "continuationContents": [
                "sectionListContinuation": [
                    "contents": sections,
                ],
            ],
        ]
    }

    private func makeShowDetailData(
        title: String,
        author: String? = nil,
        description: String? = nil,
        episodeCount: Int = 0,
        isSubscribed: Bool = false,
        continuationToken: String? = nil
    ) -> [String: Any] {
        var episodes: [[String: Any]] = []
        for i in 0 ..< episodeCount {
            episodes.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "ep\(i)"],
                    "flexColumns": [[
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": "Episode \(i)"]]],
                        ],
                    ]],
                ],
            ])
        }

        var data: [String: Any] = [
            "header": [
                "musicDetailHeaderRenderer": [
                    "title": ["runs": [["text": title]]],
                    "subtitle": ["runs": [["text": author ?? ""]]],
                    "description": description.map { ["runs": [["text": $0]]] } as Any,
                    "menu": [
                        "menuRenderer": [
                            "items": isSubscribed ? [[
                                "menuServiceItemRenderer": [
                                    "icon": ["iconType": "LIBRARY_REMOVE"],
                                ],
                            ]] : [],
                        ],
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
                                        "musicShelfRenderer": [
                                            "contents": episodes,
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]

        if let token = continuationToken {
            // Add continuation to the music shelf
            if var contents = data["contents"] as? [String: Any],
               var singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
               var tabs = singleColumn["tabs"] as? [[String: Any]],
               var firstTab = tabs.first,
               var tabRenderer = firstTab["tabRenderer"] as? [String: Any],
               var content = tabRenderer["content"] as? [String: Any],
               var sectionList = content["sectionListRenderer"] as? [String: Any],
               var sectionContents = sectionList["contents"] as? [[String: Any]],
               var firstSection = sectionContents.first,
               var musicShelf = firstSection["musicShelfRenderer"] as? [String: Any]
            {
                musicShelf["continuations"] = [[
                    "nextContinuationData": ["continuation": token],
                ]]
                firstSection["musicShelfRenderer"] = musicShelf
                sectionContents[0] = firstSection
                sectionList["contents"] = sectionContents
                content["sectionListRenderer"] = sectionList
                tabRenderer["content"] = content
                firstTab["tabRenderer"] = tabRenderer
                tabs[0] = firstTab
                singleColumn["tabs"] = tabs
                contents["singleColumnBrowseResultsRenderer"] = singleColumn
                data["contents"] = contents
            }
        }

        return data
    }

    private func makeEpisodesContinuationData(episodeCount: Int, hasMore: Bool) -> [String: Any] {
        var episodes: [[String: Any]] = []
        for i in 0 ..< episodeCount {
            episodes.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "ep\(i)"],
                    "flexColumns": [[
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": "Episode \(i)"]]],
                        ],
                    ]],
                ],
            ])
        }

        var shelfContinuation: [String: Any] = [
            "contents": episodes,
        ]

        if hasMore {
            shelfContinuation["continuations"] = [[
                "nextContinuationData": ["continuation": "next-token"],
            ]]
        }

        return [
            "continuationContents": [
                "musicShelfContinuation": shelfContinuation,
            ],
        ]
    }

    private func makePodcastShowItem(id: String, title: String) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": title]]],
                "navigationEndpoint": [
                    "browseEndpoint": ["browseId": id],
                ],
            ],
        ]
    }

    private func makeEpisodeItem(id: String, title: String) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": id],
                "flexColumns": [[
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": title]]],
                    ],
                ]],
            ],
        ]
    }
}
