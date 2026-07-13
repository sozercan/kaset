import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct ProvisionalMixPlaybackHistoryTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func tracklist(finalEndTime: TimeInterval? = nil) -> MixTracklist {
        MixTracklist(
            videoId: "mix",
            entries: [
                MixTrackEntry(startTime: 0, endTime: 100, title: "One", artist: "A", source: .chapters),
                MixTrackEntry(startTime: 100, endTime: 200, title: "Two", artist: "B", source: .chapters),
                MixTrackEntry(startTime: 200, endTime: finalEndTime, title: "Three", artist: "C", source: .chapters),
            ],
            source: .chapters
        )
    }

    private var song: Song {
        TestFixtures.makeSong(id: "mix", title: "Whole Mix", duration: nil)
    }

    @Test("An unbounded final entry receives provisional credit without a parent duration")
    func unboundedFinalEntryCredit() {
        var history = ProvisionalMixPlaybackHistory()
        history.record(startProgress: 210, endProgress: 260, startTime: self.epoch)

        let scrobbles = history.scrobbles(
            tracklist: self.tracklist(),
            song: self.song,
            videoDuration: nil,
            thresholds: .init(percent: 0.5, minSeconds: 40, allowsUnknownDuration: true)
        )

        #expect(scrobbles.count == 1)
        #expect(scrobbles.first?.title == "Three")
        #expect(scrobbles.first?.duration == nil)
    }

    @Test("Discontinuous visits are evaluated independently")
    func discontinuousVisitsStaySeparate() {
        var subthresholdHistory = ProvisionalMixPlaybackHistory()
        subthresholdHistory.record(startProgress: 0, endProgress: 30, startTime: self.epoch)
        subthresholdHistory.record(startProgress: 0, endProgress: 30, startTime: self.epoch.addingTimeInterval(100))

        let thresholds = PlaybackScrobbleTracker.Thresholds(percent: 0.5, minSeconds: 240)
        #expect(subthresholdHistory.scrobbles(
            tracklist: self.tracklist(),
            song: self.song,
            videoDuration: 300,
            thresholds: thresholds
        ).isEmpty)

        var replayHistory = ProvisionalMixPlaybackHistory()
        replayHistory.record(startProgress: 0, endProgress: 60, startTime: self.epoch)
        replayHistory.record(startProgress: 0, endProgress: 60, startTime: self.epoch.addingTimeInterval(100))

        let replayScrobbles = replayHistory.scrobbles(
            tracklist: self.tracklist(),
            song: self.song,
            videoDuration: 300,
            thresholds: thresholds
        )
        #expect(replayScrobbles.count == 2)
        #expect(replayScrobbles[0].timestamp != replayScrobbles[1].timestamp)
    }

    @Test("A pause preserves one progress-contiguous visit")
    func pauseKeepsVisitContiguous() {
        var history = ProvisionalMixPlaybackHistory()
        history.record(startProgress: 0, endProgress: 30, startTime: self.epoch)
        history.record(startProgress: 30, endProgress: 60, startTime: self.epoch.addingTimeInterval(100))

        let scrobbles = history.scrobbles(
            tracklist: self.tracklist(),
            song: self.song,
            videoDuration: 300,
            thresholds: .init(percent: 0.5, minSeconds: 240)
        )

        #expect(scrobbles.count == 1)
        #expect(scrobbles.first?.title == "One")
    }

    @Test("A pause before a chapter boundary preserves the later chapter timestamp")
    func pausePreservesChapterTimestamp() {
        var history = ProvisionalMixPlaybackHistory()
        history.record(startProgress: 90, endProgress: 100, startTime: self.epoch)
        let resumedAt = self.epoch.addingTimeInterval(100)
        history.record(startProgress: 100, endProgress: 110, startTime: resumedAt)

        let list = self.tracklist()
        let listCredits = history.credits(
            tracklist: list,
            videoDuration: 300,
            thresholds: .init(percent: 0.05, minSeconds: 240)
        )
        #expect(listCredits[list.entries[1].id]?.first?.startTime == resumedAt)
    }

    @Test("The next chapter start bounds a non-final entry without endTime")
    func nextChapterBoundsMissingEndTime() {
        let list = MixTracklist(
            videoId: "mix",
            entries: [
                MixTrackEntry(startTime: 0, endTime: nil, title: "One", artist: "A", source: .chapters),
                MixTrackEntry(startTime: 100, endTime: 200, title: "Two", artist: "B", source: .chapters),
                MixTrackEntry(startTime: 200, endTime: 300, title: "Three", artist: "C", source: .chapters),
            ],
            source: .chapters
        )
        var history = ProvisionalMixPlaybackHistory()
        history.record(startProgress: 0, endProgress: 60, startTime: self.epoch)

        let scrobbles = history.scrobbles(
            tracklist: list,
            song: self.song,
            videoDuration: 300,
            thresholds: .init(percent: 0.5, minSeconds: 240)
        )

        #expect(scrobbles.count == 1)
        #expect(scrobbles.first?.title == "One")
    }

    @Test("Returning to a scrobbled entry's middle preserves one latch")
    func middleReentryDoesNotCreateDuplicatePlay() {
        var history = ProvisionalMixPlaybackHistory()
        history.record(startProgress: 0, endProgress: 60, startTime: self.epoch)
        history.record(startProgress: 100, endProgress: 110, startTime: self.epoch.addingTimeInterval(60))
        history.record(startProgress: 50, endProgress: 100, startTime: self.epoch.addingTimeInterval(70))

        let scrobbles = history.scrobbles(
            tracklist: self.tracklist(),
            song: self.song,
            videoDuration: 300,
            thresholds: .init(percent: 0.5, minSeconds: 240)
        )

        #expect(scrobbles.count(where: { $0.title == "One" }) == 1)
    }

    @Test("A new near-start replay keeps its own provisional latch")
    func activeReplayKeepsSeparateLatch() {
        let list = self.tracklist()
        var history = ProvisionalMixPlaybackHistory()
        history.record(startProgress: 0, endProgress: 60, startTime: self.epoch)
        history.record(startProgress: 0, endProgress: 10, startTime: self.epoch.addingTimeInterval(100))

        let credits = history.credits(
            tracklist: list,
            videoDuration: 300,
            thresholds: .init(percent: 0.5, minSeconds: 240)
        )[list.entries[0].id]

        #expect(credits?.count == 2)
        #expect(credits?.first?.hasScrobbled == true)
        #expect(credits?.last?.hasScrobbled == false)
    }

    @Test("Explicit seek markers preserve qualifying replay boundaries")
    func seekMarkersPreserveReplayBoundary() {
        var history = ProvisionalMixPlaybackHistory()
        history.record(startProgress: 0, endProgress: 1, startTime: self.epoch)
        history.recordDiscontinuity(at: 50, startTime: self.epoch.addingTimeInterval(1))
        history.recordDiscontinuity(at: 0, startTime: self.epoch.addingTimeInterval(2))
        history.record(startProgress: 0, endProgress: 1, startTime: self.epoch.addingTimeInterval(3))

        let scrobbles = history.scrobbles(
            tracklist: self.tracklist(),
            song: self.song,
            videoDuration: 300,
            thresholds: .init(percent: 0.01, minSeconds: 240)
        )

        #expect(scrobbles.count(where: { $0.title == "One" }) == 2)
    }

    @Test("Discontinuity markers alone are not playback")
    func markersAreNotPlayback() {
        var history = ProvisionalMixPlaybackHistory()
        history.recordDiscontinuity(at: 50, startTime: self.epoch)
        #expect(!history.hasPlayback)
    }

    @Test("Provisional active credit survives a small unrecorded progress delta")
    @MainActor
    func activeCreditSurvivesSmallProgressDelta() {
        let playerService = PlayerService()
        let song = self.song
        playerService.currentTrack = song
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 13,
            duration: 300,
            observedVideoId: song.videoId
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: MockScrobblingSettings(),
            services: []
        )
        var history = ProvisionalMixPlaybackHistory()
        history.record(startProgress: 0, endProgress: 10, startTime: self.epoch)
        coordinator.provisionalMixHistory = history
        let list = self.tracklist()

        coordinator.consumeProvisionalPlayback(for: list, song: song)

        #expect(coordinator.provisionalCurrentMixCredit?.entryId == list.entries[0].id)
        #expect(coordinator.provisionalCurrentMixCredit?.credit.accumulatedPlayTime == 10)
    }
}
