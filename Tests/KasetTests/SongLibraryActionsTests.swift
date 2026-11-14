import Foundation
import Testing
@testable import Kaset

extension LibraryMutationSerialTests {
    @Suite(.tags(.service), .timeLimit(.minutes(1)))
    @MainActor
    struct SongLibraryActionsTests {
        private let mockClient = MockYTMusicClient()

        private func waitUntil(condition: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(3)
            while clock.now < deadline {
                if condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        private func makeLibraryPlayer() -> PlayerService {
            let playerService = PlayerService()
            let authService = AuthService(webKitManager: MockWebKitManager())
            authService.completeLogin(sapisid: "REDACTED")
            playerService.setAuthService(authService)
            playerService.setSongLikeStatusManager(SongLikeStatusManager())
            playerService.setYTMusicClient(self.mockClient)
            return playerService
        }

        @Test("Saving current and upcoming songs preserves paused playback and queue ownership", arguments: [0, 1])
        func addToLibraryPreservesPlayback(targetIndex: Int) async {
            let playerService = self.makeLibraryPlayer()
            let songs = ["playing", "upcoming"].map { id in
                Song(
                    id: id, title: id, artists: [], videoId: id,
                    isInLibrary: false,
                    feedbackTokens: FeedbackTokens(add: "mock-add", remove: "mock-remove")
                )
            }
            await playerService.playQueue(songs, startingAt: 0)
            playerService.state = .paused
            playerService.progress = 42
            let entryIDs = playerService.queueEntryIDs
            let playbackOwner = playerService.activePlaybackQueueEntryID
            let playbackIntent = playerService.currentMusicPlaybackIntent
            let target = songs[targetIndex]
            self.mockClient.songResponses[target.videoId] = target

            await SongActionsHelper.addToLibrary(target, playerService: playerService).value

            #expect(self.mockClient.editSongLibraryStatusTokens == [["mock-add"]])
            #expect(playerService.currentTrack?.videoId == songs[0].videoId)
            #expect(playerService.state == .paused)
            #expect(playerService.progress == 42)
            #expect(playerService.queueEntryIDs == entryIDs)
            #expect(playerService.currentIndex == 0)
            #expect(playerService.activePlaybackQueueEntryID == playbackOwner)
            #expect(playerService.currentMusicPlaybackIntent == playbackIntent)
            #expect(playerService.queue[targetIndex].isInLibrary == true)
        }

        @Test("Saving a song is cancelled if the account changes while metadata loads")
        func addToLibraryCannotCrossAccountBoundary() async {
            let playerService = self.makeLibraryPlayer()
            let song = Song(
                id: "account-save", title: "Account Save", artists: [], videoId: "account-save",
                isInLibrary: false,
                feedbackTokens: FeedbackTokens(add: "mock-add", remove: "mock-remove")
            )
            self.mockClient.songResponses[song.videoId] = song
            let metadataStarted = AsyncGate()
            let releaseMetadata = AsyncGate()
            self.mockClient.beforeGetSongReturn = { _ in
                await metadataStarted.open()
                await releaseMetadata.wait()
            }

            let task = SongActionsHelper.addToLibrary(song, playerService: playerService)
            await metadataStarted.wait()
            playerService.clearPlaybackForSignOut()
            await releaseMetadata.open()
            await task.value

            #expect(!self.mockClient.editSongLibraryStatusCalled)
            #expect(playerService.currentTrack == nil)
            #expect(playerService.confirmedLibraryStateByKey.isEmpty)
            #expect(playerService.libraryMutationStates.isEmpty)
        }

        @Test("A later library removal stays ordered after a context-menu save")
        func addToLibrarySerializesWithPlayerBarToggle() async {
            let playerService = self.makeLibraryPlayer()
            let song = Song(
                id: "ordered-save", title: "Ordered Save", artists: [], videoId: "ordered-save",
                isInLibrary: false,
                feedbackTokens: FeedbackTokens(add: "mock-add", remove: "mock-remove")
            )
            await playerService.playQueue([song], startingAt: 0)
            self.mockClient.songResponses[song.videoId] = song
            let metadataStarted = AsyncGate()
            let releaseMetadata = AsyncGate()
            self.mockClient.beforeGetSongReturn = { _ in
                await metadataStarted.open()
                await releaseMetadata.wait()
            }

            let task = SongActionsHelper.addToLibrary(song, playerService: playerService)
            await metadataStarted.wait()
            playerService.toggleLibraryStatus()
            await releaseMetadata.open()
            await task.value
            let completed = await self.waitUntil {
                self.mockClient.appliedEditSongLibraryStatusTokens.count == 2
                    && playerService.libraryMutationRevisions.isEmpty
            }

            #expect(completed)
            #expect(self.mockClient.appliedEditSongLibraryStatusTokens == [["mock-add"], ["mock-remove"]])
            #expect(!playerService.currentTrackInLibrary)
            #expect(playerService.queue.first?.isInLibrary == false)
        }

        @Test("A failed save restores library state without starting playback")
        func addToLibraryFailurePreservesPlayback() async {
            let playerService = self.makeLibraryPlayer()
            let song = Song(
                id: "failed-save", title: "Failed Save", artists: [], videoId: "failed-save",
                isInLibrary: false,
                feedbackTokens: FeedbackTokens(add: "mock-add", remove: "mock-remove")
            )
            await playerService.playQueue([song], startingAt: 0)
            playerService.state = .paused
            self.mockClient.songResponses[song.videoId] = song
            self.mockClient.editSongLibraryStatusErrors = [YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))]

            await SongActionsHelper.addToLibrary(song, playerService: playerService).value

            #expect(self.mockClient.editSongLibraryStatusCalled)
            #expect(!playerService.currentTrackInLibrary)
            #expect(playerService.queue.first?.isInLibrary == false)
            #expect(playerService.state == .paused)
        }

        @Test("A save after removal uses confirmed state when metadata still reports saved")
        func addToLibraryAfterRemovalIgnoresStaleMetadata() async {
            let playerService = self.makeLibraryPlayer()
            let song = Song(
                id: "remove-then-save", title: "Remove then Save", artists: [], videoId: "remove-then-save",
                isInLibrary: true,
                feedbackTokens: FeedbackTokens(add: "mock-add", remove: "mock-remove")
            )
            await playerService.playQueue([song], startingAt: 0)
            self.mockClient.songResponses[song.videoId] = song
            let removalStarted = AsyncGate()
            let releaseRemoval = AsyncGate()
            self.mockClient.beforeEditSongLibraryStatusReturn = { tokens in
                guard tokens == ["mock-remove"] else { return }
                await removalStarted.open()
                await releaseRemoval.wait()
            }

            playerService.toggleLibraryStatus()
            await removalStarted.wait()
            let save = SongActionsHelper.addToLibrary(song, playerService: playerService)
            await releaseRemoval.open()
            await save.value

            #expect(self.mockClient.appliedEditSongLibraryStatusTokens == [["mock-remove"], ["mock-add"]])
            #expect(playerService.currentTrackInLibrary)
        }

        @Test("Saving another song preserves the current song's pending library metadata")
        func addToLibraryDoesNotInvalidateOtherSongMetadata() async {
            let playerService = self.makeLibraryPlayer()
            let current = TestFixtures.makeSong(id: "metadata-current")
            let saved = TestFixtures.makeSong(id: "saved-other")
            let currentTokens = FeedbackTokens(add: "current-add", remove: "current-remove")
            playerService.currentTrack = current
            self.mockClient.songResponses[current.videoId] = Song(
                id: current.id, title: current.title, artists: [], videoId: current.videoId,
                isInLibrary: true, feedbackTokens: currentTokens
            )
            self.mockClient.songResponses[saved.videoId] = Song(
                id: saved.id, title: saved.title, artists: [], videoId: saved.videoId,
                isInLibrary: false, feedbackTokens: FeedbackTokens(add: "other-add", remove: "other-remove")
            )
            let metadataStarted = AsyncGate()
            let releaseMetadata = AsyncGate()
            self.mockClient.beforeGetSongReturn = { videoID in
                guard videoID == current.videoId else { return }
                await metadataStarted.open()
                await releaseMetadata.wait()
            }

            let metadata = Task { await playerService.fetchSongMetadata(videoId: current.videoId) }
            await metadataStarted.wait()
            await SongActionsHelper.addToLibrary(saved, playerService: playerService).value
            await releaseMetadata.open()
            await metadata.value

            #expect(playerService.currentTrack?.videoId == current.videoId)
            #expect(playerService.currentTrackInLibrary)
            #expect(playerService.currentTrackFeedbackTokens == currentTokens)
            #expect(self.mockClient.appliedEditSongLibraryStatusTokens == [["other-add"]])
        }

        @Test("A save after completed removal does not trust the stale metadata cache")
        func addToLibraryAfterCompletedRemoval() async {
            let playerService = self.makeLibraryPlayer()
            let song = Song(
                id: "completed-remove", title: "Completed Remove", artists: [], videoId: "completed-remove",
                isInLibrary: true,
                feedbackTokens: FeedbackTokens(add: "mock-add", remove: "mock-remove")
            )
            await playerService.playQueue([song], startingAt: 0)
            self.mockClient.songResponses[song.videoId] = song
            playerService.toggleLibraryStatus()
            let removed = await self.waitUntil {
                self.mockClient.appliedEditSongLibraryStatusTokens == [["mock-remove"]]
                    && playerService.libraryMutationRevisions.isEmpty
            }
            #expect(removed)
            #expect(!playerService.currentTrackInLibrary)

            await SongActionsHelper.addToLibrary(song, playerService: playerService).value

            #expect(self.mockClient.appliedEditSongLibraryStatusTokens == [["mock-remove"], ["mock-add"]])
            #expect(playerService.currentTrackInLibrary)
        }

        @Test("Failed saves preserve known upcoming queue metadata when the clicked row lacks it")
        func addToLibraryFailurePreservesKnownQueueState() async {
            let playerService = self.makeLibraryPlayer()
            let current = Song(
                id: "queue-current", title: "Current", artists: [], videoId: "queue-current",
                isInLibrary: false,
                feedbackTokens: FeedbackTokens(add: "current-add", remove: "current-remove")
            )
            let saved = Song(
                id: "queue-saved", title: "Saved", artists: [], videoId: "queue-saved",
                isInLibrary: true,
                feedbackTokens: FeedbackTokens(add: "saved-add", remove: "saved-remove")
            )
            await playerService.playQueue([current, saved], startingAt: 0)
            let row = Song(id: saved.id, title: saved.title, artists: [], videoId: saved.videoId)
            self.mockClient.shouldThrowError = URLError(.notConnectedToInternet)

            await SongActionsHelper.addToLibrary(row, playerService: playerService).value

            #expect(!self.mockClient.editSongLibraryStatusCalled)
            #expect(playerService.queue[1].isInLibrary == true)
            #expect(playerService.queue[1].feedbackTokens == saved.feedbackTokens)
            #expect(playerService.currentTrack?.videoId == current.videoId)
        }

        @Test("A previous successful save does not suppress saving after an external removal")
        func addToLibraryRespectsExternallyRemovedState() async {
            let playerService = self.makeLibraryPlayer()
            let song = Song(
                id: "external-remove", title: "External Remove", artists: [], videoId: "external-remove",
                isInLibrary: false,
                feedbackTokens: FeedbackTokens(add: "mock-add", remove: "mock-remove")
            )
            self.mockClient.songResponses[song.videoId] = song

            await SongActionsHelper.addToLibrary(song, playerService: playerService).value
            // The second response reports the song removed again, as if changed in another client.
            await SongActionsHelper.addToLibrary(song, playerService: playerService).value

            #expect(self.mockClient.appliedEditSongLibraryStatusTokens == [["mock-add"], ["mock-add"]])
        }
    }
}
