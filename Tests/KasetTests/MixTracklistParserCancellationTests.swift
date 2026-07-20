import Foundation
import Testing
@testable import Kaset

@Suite("Mix tracklist parser cancellation", .tags(.service))
@MainActor
struct MixTracklistParserCancellationTests {
    @Test("Cancelling one coalesced waiter preserves the shared parse")
    func cancellingOneCoalescedWaiterPreservesSharedParse() async {
        let gate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = Self.makeChapterTracklistData(videoId: "one-waiter")
        mockYouTube.beforeWatchNextReturn = { _ in await gate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        var firstReturned = false

        let first = Task { @MainActor in
            let result = await parser.parseTracklist(videoId: "one-waiter")
            firstReturned = true
            return result
        }
        while mockYouTube.getWatchNextCallCount == 0 {
            await Task.yield()
        }

        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return await parser.parseTracklist(videoId: "one-waiter")
        }
        while !secondStarted {
            await Task.yield()
        }

        first.cancel()
        let firstResult = await first.value

        #expect(firstReturned)
        #expect(firstResult == nil)
        #expect(mockYouTube.getWatchNextCallCount == 1)
        #expect(mockYouTube.getWatchNextCompletionCount == 0)

        await gate.open()

        let secondResult = await second.value
        #expect(secondResult?.entries.count == 3)
        #expect(mockYouTube.getWatchNextCallCount == 1)
        #expect(mockYouTube.getWatchNextCompletionCount == 1)
    }

    @Test("Cancelling all waiters permits an identity-safe same-video retry")
    func cancellingAllWaitersPermitsSameVideoRetry() async {
        let staleGate = AsyncGate()
        let staleDidResume = AsyncGate()
        let replacementGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = Self.makeChapterTracklistData(videoId: "all-waiters")
        mockYouTube.beforeWatchNextReturnByCallCount = { callCount in
            if callCount == 1 {
                await staleGate.wait()
                await staleDidResume.open()
            } else {
                await replacementGate.wait()
            }
        }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        var firstReturned = false
        var secondReturned = false
        var secondStarted = false
        var joinedRetryReturned = false
        var joinedRetryStarted = false

        let first = Task { @MainActor in
            let result = await parser.parseTracklist(videoId: "all-waiters")
            firstReturned = true
            return result
        }
        while mockYouTube.getWatchNextCallCount == 0 {
            await Task.yield()
        }

        let second = Task { @MainActor in
            secondStarted = true
            let result = await parser.parseTracklist(videoId: "all-waiters")
            secondReturned = true
            return result
        }
        while !secondStarted {
            await Task.yield()
        }

        first.cancel()
        second.cancel()
        let firstResult = await first.value
        let secondResult = await second.value

        #expect(firstReturned)
        #expect(secondReturned)
        #expect(firstResult == nil)
        #expect(secondResult == nil)

        let retry = Task { @MainActor in
            await parser.parseTracklist(videoId: "all-waiters")
        }
        for _ in 0 ..< 20 where mockYouTube.getWatchNextCallCount < 2 {
            await Task.yield()
        }
        #expect(mockYouTube.getWatchNextCallCount == 2)

        await staleGate.open()
        await staleDidResume.wait()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        let joinedRetry = Task { @MainActor in
            joinedRetryStarted = true
            let result = await parser.parseTracklist(videoId: "all-waiters")
            joinedRetryReturned = true
            return result
        }
        while !joinedRetryStarted {
            await Task.yield()
        }

        #expect(mockYouTube.getWatchNextCallCount == 2)
        #expect(!joinedRetryReturned)

        await replacementGate.open()

        let retryResult = await retry.value
        let joinedRetryResult = await joinedRetry.value
        #expect(retryResult?.entries.count == 3)
        #expect(joinedRetryResult?.entries.count == 3)
        #expect(mockYouTube.getWatchNextCallCount == 2)
        #expect(mockYouTube.getWatchNextCompletionCount == 1)
    }

    @Test("Immediate same-video retry prunes a synchronously cancelled sole waiter")
    func immediateRetryPrunesSynchronouslyCancelledSoleWaiter() async {
        let staleGate = AsyncGate()
        let replacementGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = Self.makeChapterTracklistData(videoId: "immediate-retry")
        mockYouTube.beforeWatchNextReturnByCallCount = { callCount in
            if callCount == 1 {
                await staleGate.wait()
            } else {
                await replacementGate.wait()
            }
        }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let first = Task { @MainActor in
            await parser.parseTracklist(videoId: "immediate-retry")
        }
        while mockYouTube.getWatchNextCallCount == 0 {
            await Task.yield()
        }

        // Cancel and retry in one MainActor turn, before the cancellation cleanup task can run.
        let retry = Task { @MainActor in
            first.cancel()
            return await parser.parseTracklist(videoId: "immediate-retry")
        }
        for _ in 0 ..< 50 where mockYouTube.getWatchNextCallCount < 2 {
            await Task.yield()
        }

        #expect(mockYouTube.getWatchNextCallCount == 2)
        await staleGate.open()
        await replacementGate.open()

        let firstResult = await first.value
        let retryResult = await retry.value
        #expect(firstResult == nil)
        #expect(retryResult?.entries.count == 3)
        #expect(mockYouTube.getWatchNextCompletionCount == 1)
    }

    private static func makeChapterTracklistData(videoId: String) -> WatchNextData {
        WatchNextData(
            videoTitle: "Cancellation Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: (0 ..< 3).map { index in
                YouTubeChapter(
                    videoId: videoId,
                    title: "Artist \(index) - Track \(index)",
                    startTime: TimeInterval(index) * 600,
                    endTime: TimeInterval(index + 1) * 600,
                    timeText: nil,
                    thumbnailURL: nil
                )
            }
        )
    }
}
