import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.model))
struct PodcastModelTests {
    struct PodcastShowTests {
        @Test("hasNavigableId returns true for MPSPP prefix")
        func hasNavigableIdWithMPSPPPrefix() {
            let show = PodcastShow(
                id: "MPSPP12345",
                title: "Test Show",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            #expect(show.hasNavigableId == true)
        }

        @Test("hasNavigableId returns false for non-MPSPP prefix")
        func hasNavigableIdWithOtherPrefix() {
            let showVL = PodcastShow(
                id: "VL12345",
                title: "Test Show",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            #expect(showVL.hasNavigableId == false)

            let showEmpty = PodcastShow(
                id: "",
                title: "Test Show",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            #expect(showEmpty.hasNavigableId == false)
        }

        @Test("PodcastShow is Identifiable with id")
        func identifiableById() {
            let show = PodcastShow(
                id: "MPSPP123",
                title: "Test",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            #expect(show.id == "MPSPP123")
        }

        @Test("PodcastShow is Hashable")
        func hashable() {
            let show1 = PodcastShow(
                id: "MPSPP123",
                title: "Test",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            let show2 = PodcastShow(
                id: "MPSPP123",
                title: "Test",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            #expect(show1 == show2)
            #expect(show1.hashValue == show2.hashValue)
        }
    }

    struct PodcastEpisodeTests {
        @Test("formattedDuration returns MM:SS for short duration")
        func formattedDurationShort() {
            let episode = Self.makeEpisode(durationSeconds: 125)
            #expect(episode.formattedDuration == "2:05")
        }

        @Test("formattedDuration returns HH:MM:SS for long duration")
        func formattedDurationLong() {
            let episode = Self.makeEpisode(durationSeconds: 3725)
            #expect(episode.formattedDuration == "1:02:05")
        }

        @Test("formattedDuration returns nil when durationSeconds is nil and no fallback")
        func formattedDurationNil() {
            let episode = Self.makeEpisode(durationSeconds: nil, duration: nil)
            #expect(episode.formattedDuration == nil)
        }

        @Test("formattedDuration returns fallback string when durationSeconds is nil")
        func formattedDurationFallback() {
            let episode = Self.makeEpisode(durationSeconds: nil, duration: "36 min")
            #expect(episode.formattedDuration == "36 min")
        }

        @Test("formattedDuration handles zero duration")
        func formattedDurationZero() {
            let episode = Self.makeEpisode(durationSeconds: 0)
            #expect(episode.formattedDuration == "0:00")
        }

        @Test("formattedDuration handles exactly one hour")
        func formattedDurationOneHour() {
            let episode = Self.makeEpisode(durationSeconds: 3600)
            #expect(episode.formattedDuration == "1:00:00")
        }

        @Test("formattedDuration handles 59 minutes 59 seconds")
        func formattedDurationUnderOneHour() {
            let episode = Self.makeEpisode(durationSeconds: 3599)
            #expect(episode.formattedDuration == "59:59")
        }

        @Test("PodcastEpisode is Identifiable with id")
        func identifiableById() {
            let episode = Self.makeEpisode(id: "ep123")
            #expect(episode.id == "ep123")
        }

        private static func makeEpisode(
            id: String = "ep1",
            durationSeconds: Int? = nil,
            duration: String? = nil
        ) -> PodcastEpisode {
            PodcastEpisode(
                id: id,
                title: "Test Episode",
                showTitle: nil,
                showBrowseId: nil,
                description: nil,
                thumbnailURL: nil,
                publishedDate: nil,
                duration: duration,
                durationSeconds: durationSeconds,
                playbackProgress: 0,
                isPlayed: false
            )
        }
    }

    struct PodcastSectionTests {
        @Test("PodcastSection is Identifiable with id")
        func identifiableById() {
            let section = PodcastSection(
                id: "section1",
                title: "Popular",
                items: []
            )
            #expect(section.id == "section1")
        }
    }

    struct PodcastSectionItemTests {
        @Test("show case returns show id")
        func showCaseId() {
            let show = PodcastShow(
                id: "MPSPP123",
                title: "Test",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            let item = PodcastSectionItem.show(show)
            #expect(item.id == "MPSPP123")
        }

        @Test("episode case returns episode id")
        func episodeCaseId() {
            let episode = PodcastEpisode(
                id: "ep456",
                title: "Test Episode",
                showTitle: nil,
                showBrowseId: nil,
                description: nil,
                thumbnailURL: nil,
                publishedDate: nil,
                duration: nil,
                durationSeconds: nil,
                playbackProgress: 0,
                isPlayed: false
            )
            let item = PodcastSectionItem.episode(episode)
            #expect(item.id == "ep456")
        }

        @Test("PodcastSectionItem is Hashable based on id")
        func hashable() {
            let show1 = PodcastShow(
                id: "MPSPP123",
                title: "Show A",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            let show2 = PodcastShow(
                id: "MPSPP123",
                title: "Show B",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
            let item1 = PodcastSectionItem.show(show1)
            let item2 = PodcastSectionItem.show(show2)

            #expect(item1 == item2)
        }
    }

    struct PodcastShowDetailTests {
        @Test("hasMore returns true when continuationToken exists")
        func hasMoreWithToken() {
            let detail = PodcastShowDetail(
                show: Self.makeShow(),
                episodes: [],
                continuationToken: "token123",
                isSubscribed: false
            )
            #expect(detail.hasMore == true)
        }

        @Test("hasMore returns false when continuationToken is nil")
        func hasMoreWithoutToken() {
            let detail = PodcastShowDetail(
                show: Self.makeShow(),
                episodes: [],
                continuationToken: nil,
                isSubscribed: false
            )
            #expect(detail.hasMore == false)
        }

        private static func makeShow() -> PodcastShow {
            PodcastShow(
                id: "MPSPP123",
                title: "Test",
                author: nil,
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
        }
    }

    struct PodcastEpisodesContinuationTests {
        @Test("hasMore returns true when continuationToken exists")
        func hasMoreWithToken() {
            let continuation = PodcastEpisodesContinuation(
                episodes: [],
                continuationToken: "next-token"
            )
            #expect(continuation.hasMore == true)
        }

        @Test("hasMore returns false when continuationToken is nil")
        func hasMoreWithoutToken() {
            let continuation = PodcastEpisodesContinuation(
                episodes: [],
                continuationToken: nil
            )
            #expect(continuation.hasMore == false)
        }
    }
}
