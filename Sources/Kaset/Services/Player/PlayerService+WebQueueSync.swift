import Foundation

// MARK: - Web Queue Sync

@MainActor
extension PlayerService {
    private func normalizedObservedVideoId(_ videoId: String?) -> String? {
        guard let videoId, !videoId.isEmpty else { return nil }
        return videoId
    }

    private func resolvedObservedVideoId(_ videoId: String?) -> String {
        self.normalizedObservedVideoId(videoId) ?? self.currentTrack?.videoId ?? self.pendingPlayVideoId ?? "unknown"
    }

    private func observedTrackMatchesSong(
        observedVideoId: String?,
        title: String,
        artist: String,
        song: Song
    ) -> Bool {
        if let observedVideoId = self.normalizedObservedVideoId(observedVideoId) {
            return song.videoId == observedVideoId
        }
        return song.title == title && song.artistsDisplay == artist
    }

    private func metadataMatchesSong(title: String, artist: String, song: Song) -> Bool {
        song.title == title && song.artistsDisplay == artist
    }

    private func shouldKeepQueueMetadata(title: String, artist: String, song: Song) -> Bool {
        title.isEmpty || artist.isEmpty || !self.metadataMatchesSong(title: title, artist: artist, song: song)
    }

    private var canAdvanceNativeQueueAfterTrackEnd: Bool {
        self.shuffleEnabled
            || self.repeatMode == .one
            || self.currentIndex < self.queue.count - 1
            || self.repeatMode == .all
            || self.mixContinuationToken != nil
    }

    private func expectedQueueIndexAfterCurrentTrack() -> Int? {
        guard !self.queue.isEmpty, !self.shuffleEnabled, self.repeatMode != .one else { return nil }
        if self.currentIndex < self.queue.count - 1 {
            return self.currentIndex + 1
        }
        if self.repeatMode == .all {
            return 0
        }
        return nil
    }

    private func keepQueueSongVisible(_ song: Song, thumbnailUrl: String) {
        let intendedThumbnailURL = URL(string: thumbnailUrl) ?? song.thumbnailURL
        self.currentTrack = Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            album: song.album,
            duration: song.duration,
            thumbnailURL: intendedThumbnailURL,
            videoId: song.videoId,
            hasVideo: song.hasVideo,
            musicVideoType: song.musicVideoType,
            likeStatus: song.likeStatus,
            isInLibrary: song.isInLibrary,
            feedbackTokens: song.feedbackTokens
        )
    }

    /// Handles a natural track completion reported directly by the WebView.
    func handleTrackEnded(observedVideoId: String?) async {
        self.logger.debug("Track ended reported by WebView: \(observedVideoId ?? "unknown")")
        self.songNearingEnd = false
        guard !self.queue.isEmpty else {
            self.markPlaybackEnded()
            return
        }
        if let observedVideoId = self.normalizedObservedVideoId(observedVideoId) {
            let currentQueueVideoId = self.queue[safe: self.currentIndex]?.videoId
            let expectedCurrentVideoId = currentQueueVideoId ?? self.currentTrack?.videoId ?? self.pendingPlayVideoId
            if let expectedCurrentVideoId, expectedCurrentVideoId != observedVideoId {
                self.logger.debug(
                    "Ignoring stale track-ended event for \(observedVideoId); current queue track is \(expectedCurrentVideoId)"
                )
                return
            }
        }

        guard self.canAdvanceNativeQueueAfterTrackEnd else {
            self.markPlaybackEnded()
            self.logger.info("Reached end of native queue; not yielding to YouTube autoplay")
            return
        }
        self.logger.info("Track ended in WebView, advancing native queue immediately")
        await self.next()
    }

    /// Updates track metadata and enforces Kaset's queue when YouTube tries to diverge.
    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String, videoId observedVideoId: String?) {
        self.logger.debug("Track metadata updated: \(title) - \(artist)")
        let thumbnailURL = URL(string: thumbnailUrl)
        let artistObj = Artist(id: "unknown", name: artist)
        let resolvedVideoId = self.resolvedObservedVideoId(observedVideoId)
        let trackChanged = self.currentTrack?.title != title
            || self.currentTrack?.artistsDisplay != artist
            || self.currentTrack?.videoId != resolvedVideoId

        if self.isKasetInitiatedPlayback, !self.queue.isEmpty {
            if let intendedSong = self.queue[safe: self.currentIndex] {
                let matchesObservedVideo = self.normalizedObservedVideoId(observedVideoId) == intendedSong.videoId

                if matchesObservedVideo, self.shouldKeepQueueMetadata(title: title, artist: artist, song: intendedSong) {
                    self.logger.debug(
                        "Observed intended videoId \(intendedSong.videoId) with incomplete metadata '\(title)'; keeping queue metadata"
                    )
                    self.keepQueueSongVisible(intendedSong, thumbnailUrl: thumbnailUrl)
                    return
                } else if self.observedTrackMatchesSong(
                    observedVideoId: observedVideoId,
                    title: title,
                    artist: artist,
                    song: intendedSong
                ) {
                    self.isKasetInitiatedPlayback = false
                    self.logger.debug("Confirmed Kaset-initiated playback for '\(intendedSong.title)'")
                } else if trackChanged {
                    self.logger.info(
                        "YouTube loaded different track '\(title)' (\(resolvedVideoId)), re-playing intended track '\(intendedSong.title)'"
                    )
                    self.isKasetInitiatedPlayback = false
                    Task {
                        await self.play(song: intendedSong)
                    }
                    return
                }
            } else {
                self.isKasetInitiatedPlayback = false
            }
        }

        if trackChanged, !self.queue.isEmpty, self.songNearingEnd {
            self.songNearingEnd = false
            if let expectedNextIndex = self.expectedQueueIndexAfterCurrentTrack(),
               let expectedNextTrack = self.queue[safe: expectedNextIndex]
            {
                if !self.observedTrackMatchesSong(
                    observedVideoId: observedVideoId,
                    title: title,
                    artist: artist,
                    song: expectedNextTrack
                ) {
                    self.logger.info("YouTube autoplay detected, overriding with queue track")
                    Task {
                        await self.next()
                    }
                    return
                } else {
                    self.currentIndex = expectedNextIndex
                    self.logger.info("Track advanced to queue index \(expectedNextIndex)")
                    self.saveQueueForPersistence()

                    if self.shouldKeepQueueMetadata(title: title, artist: artist, song: expectedNextTrack) {
                        self.logger.debug(
                            "Observed queue track \(expectedNextTrack.videoId) with incomplete metadata; keeping queue metadata"
                        )
                        self.keepQueueSongVisible(expectedNextTrack, thumbnailUrl: thumbnailUrl)
                        return
                    }
                }
            } else if self.canAdvanceNativeQueueAfterTrackEnd {
                self.logger.info("Near-end track change detected, advancing native queue to enforce playback order")
                Task {
                    await self.next()
                }
                return
            } else {
                self.markPlaybackEnded()
                self.logger.info("Unexpected autoplay detected at end of native queue; pausing playback")
                Task {
                    await self.pause()
                }
                return
            }
        }

        self.currentTrack = Song(
            id: resolvedVideoId,
            title: title,
            artists: [artistObj],
            album: nil,
            duration: self.duration > 0 ? self.duration : nil,
            thumbnailURL: thumbnailURL,
            videoId: resolvedVideoId
        )

        if trackChanged {
            self.resetTrackStatus()
        }
    }
}
