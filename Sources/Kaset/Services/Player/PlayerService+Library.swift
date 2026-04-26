import Foundation

// MARK: - Like/Dislike/Library Actions

@MainActor
extension PlayerService {
    /// Likes the current track (thumbs up).
    /// Delegates to SongLikeStatusManager for unified state management and real-time sync.
    func likeCurrentTrack() {
        guard let track = currentTrack else { return }
        self.logger.info("Liking current track: \(track.videoId)")
        let activeAccountID = SongLikeStatusManager.shared.activeAccountID
        let client = self.ytMusicClient

        // Toggle: if already liked, remove the like
        let newStatus: LikeStatus = self.currentTrackLikeStatus == .like ? .indifferent : .like
        // Optimistic UI update for PlayerBar
        self.currentTrackLikeStatus = newStatus

        // Delegate to SongLikeStatusManager for API call + cache sync + event emission
        Task {
            let finalStatus: LikeStatus = if newStatus == .like {
                await SongLikeStatusManager.shared.like(
                    track,
                    accountID: activeAccountID,
                    client: client
                )
            } else {
                await SongLikeStatusManager.shared.unlike(
                    track,
                    accountID: activeAccountID,
                    client: client
                )
            }

            guard SongLikeStatusManager.shared.activeAccountID == activeAccountID,
                  self.currentTrack?.videoId == track.videoId
            else {
                return
            }

            self.currentTrackLikeStatus = finalStatus
        }
    }

    /// Dislikes the current track (thumbs down).
    /// Delegates to SongLikeStatusManager for unified state management and real-time sync.
    func dislikeCurrentTrack() {
        guard let track = currentTrack else { return }
        self.logger.info("Disliking current track: \(track.videoId)")
        let activeAccountID = SongLikeStatusManager.shared.activeAccountID
        let client = self.ytMusicClient

        // Toggle: if already disliked, remove the dislike
        let newStatus: LikeStatus = self.currentTrackLikeStatus == .dislike ? .indifferent : .dislike
        // Optimistic UI update for PlayerBar
        self.currentTrackLikeStatus = newStatus

        // Delegate to SongLikeStatusManager for API call + cache sync + event emission
        Task {
            let finalStatus: LikeStatus = if newStatus == .dislike {
                await SongLikeStatusManager.shared.dislike(
                    track,
                    accountID: activeAccountID,
                    client: client
                )
            } else {
                await SongLikeStatusManager.shared.undislike(
                    track,
                    accountID: activeAccountID,
                    client: client
                )
            }

            guard SongLikeStatusManager.shared.activeAccountID == activeAccountID,
                  self.currentTrack?.videoId == track.videoId
            else {
                return
            }

            self.currentTrackLikeStatus = finalStatus
        }
    }

    /// Toggles the library status of the current track.
    func toggleLibraryStatus() {
        guard let track = currentTrack else { return }
        self.logger.info("Toggling library status for current track: \(track.videoId)")
        let activeAccountID = SongLikeStatusManager.shared.activeAccountID

        // Determine which token to use based on current state
        let isCurrentlyInLibrary = self.currentTrackInLibrary
        let tokenToUse = isCurrentlyInLibrary
            ? self.currentTrackFeedbackTokens?.remove
            : self.currentTrackFeedbackTokens?.add

        guard let token = tokenToUse else {
            self.logger.warning("No feedback token available for library toggle")
            return
        }

        // Optimistic update
        let previousState = self.currentTrackInLibrary
        let previousTokens = self.currentTrackFeedbackTokens
        let expectedInLibrary = !isCurrentlyInLibrary
        let expectedFeedbackTokens = FeedbackTokens(
            add: previousTokens?.remove,
            remove: previousTokens?.add
        )
        self.updateCurrentTrackLibraryState(
            isInLibrary: expectedInLibrary,
            feedbackTokens: expectedFeedbackTokens
        )

        // Use API call for reliable library management
        Task {
            do {
                try await self.ytMusicClient?.editSongLibraryStatus(feedbackTokens: [token])
                let action = isCurrentlyInLibrary ? "removed from" : "added to"
                self.logger.info("Successfully \(action) library")

                // After successful toggle, we need to swap the tokens
                // The browse metadata can lag briefly, so delay the refresh and keep
                // the optimistic library state if the response is still stale.
                try? await Task.sleep(for: .milliseconds(500))

                guard SongLikeStatusManager.shared.activeAccountID == activeAccountID else { return }

                await self.fetchSongMetadata(videoId: track.videoId)

                guard SongLikeStatusManager.shared.activeAccountID == activeAccountID,
                      self.currentTrack?.videoId == track.videoId
                else {
                    return
                }

                if self.currentTrackInLibrary != expectedInLibrary {
                    self.updateCurrentTrackLibraryState(
                        isInLibrary: expectedInLibrary,
                        feedbackTokens: expectedFeedbackTokens
                    )
                }
            } catch {
                self.logger.error("Failed to toggle library status: \(error.localizedDescription)")
                // Revert on failure
                guard SongLikeStatusManager.shared.activeAccountID == activeAccountID,
                      self.currentTrack?.videoId == track.videoId
                else {
                    return
                }

                self.updateCurrentTrackLibraryState(
                    isInLibrary: previousState,
                    feedbackTokens: previousTokens
                )
            }
        }
    }

    /// Updates the like status from WebView observation.
    /// Only updates PlayerService state for UI; does NOT overwrite SongLikeStatusManager cache
    /// because WebView often reports INDIFFERENT as a default when the actual status is unknown.
    func updateLikeStatus(_ status: LikeStatus) {
        // Only accept WebView status if SongLikeStatusManager has no cached value
        // (cache is more authoritative than WebView's observation)
        if let videoId = self.currentTrack?.videoId,
           let cachedStatus = SongLikeStatusManager.shared.status(for: videoId)
        {
            self.currentTrackLikeStatus = cachedStatus
        } else {
            self.currentTrackLikeStatus = status
        }
    }

    /// Resets like/library status when track changes.
    func resetTrackStatus() {
        self.currentTrackLikeStatus = .indifferent
        self.currentTrackInLibrary = false
        self.currentTrackFeedbackTokens = nil
    }

    private func updateCurrentTrackLibraryState(
        isInLibrary: Bool,
        feedbackTokens: FeedbackTokens?
    ) {
        self.currentTrackInLibrary = isInLibrary
        self.currentTrackFeedbackTokens = feedbackTokens

        guard var currentTrack = self.currentTrack else { return }
        currentTrack.isInLibrary = isInLibrary
        currentTrack.feedbackTokens = feedbackTokens
        self.currentTrack = currentTrack
    }

    /// Fetches full song metadata including feedbackTokens from the API.
    func fetchSongMetadata(videoId: String) async {
        guard let client = ytMusicClient else {
            self.logger.warning("No YTMusicClient available for fetching song metadata")
            return
        }

        let activeAccountID = SongLikeStatusManager.shared.activeAccountID

        do {
            let songData = try await client.getSong(videoId: videoId)
            guard SongLikeStatusManager.shared.activeAccountID == activeAccountID else { return }

            let cachedLikeStatus = SongLikeStatusManager.shared.status(for: videoId)
            let resolvedLikeStatus = songData.likeStatus ?? cachedLikeStatus

            // Update current track with full metadata if it's still the same song
            if self.currentTrack?.videoId == videoId {
                // Preserve the title/artist from WebView if they're better
                let title = self.currentTrack?.title == "Loading..." ? songData.title : (self.currentTrack?.title ?? songData.title)
                let artists = self.currentTrack?.artists.isEmpty == true ? songData.artists : (self.currentTrack?.artists ?? songData.artists)

                self.currentTrack = Song(
                    id: videoId,
                    title: title,
                    artists: artists,
                    album: songData.album ?? self.currentTrack?.album,
                    duration: songData.duration ?? self.currentTrack?.duration,
                    thumbnailURL: songData.thumbnailURL ?? self.currentTrack?.thumbnailURL,
                    videoId: videoId,
                    musicVideoType: songData.musicVideoType,
                    likeStatus: resolvedLikeStatus,
                    isInLibrary: songData.isInLibrary,
                    feedbackTokens: songData.feedbackTokens
                )

                // Update service state and sync with SongLikeStatusManager.
                // Unknown like status stays out of the cache so it cannot override
                // a known rating from the WebView or a prior user action.
                if let likeStatus = songData.likeStatus {
                    self.currentTrackLikeStatus = likeStatus
                    SongLikeStatusManager.shared.setStatus(likeStatus, for: videoId)
                } else if let cachedLikeStatus {
                    self.currentTrackLikeStatus = cachedLikeStatus
                }
                self.currentTrackInLibrary = songData.isInLibrary ?? false
                self.currentTrackFeedbackTokens = songData.feedbackTokens

                // Update video availability based on API-detected musicVideoType
                // This is more reliable than DOM inspection since it comes directly from the API
                if let videoType = songData.musicVideoType {
                    self.updateVideoAvailability(hasVideo: videoType.hasVideoContent)
                    self.logger.debug("Video availability from API: \(videoType.rawValue) -> hasVideo=\(videoType.hasVideoContent)")
                }

                self.logger.info("Updated track metadata - inLibrary: \(self.currentTrackInLibrary), hasTokens: \(self.currentTrackFeedbackTokens != nil)")

                // Also update the corresponding song in the queue with enriched metadata
                // This ensures the queue displays complete info without separate API calls
                if let queueIndex = self.queueEntries.firstIndex(where: { $0.song.videoId == videoId }) {
                    // Only update if the queue entry is missing metadata
                    let currentQueueSong = self.queueEntries[queueIndex].song
                    let needsUpdate = currentQueueSong.artists.isEmpty ||
                        currentQueueSong.artists.allSatisfy { $0.name.isEmpty || $0.name == "Unknown Artist" } ||
                        currentQueueSong.title.isEmpty ||
                        currentQueueSong.title == "Loading..." ||
                        currentQueueSong.thumbnailURL == nil

                    if needsUpdate {
                        var enrichedQueueSong = songData
                        enrichedQueueSong.likeStatus = resolvedLikeStatus
                        var updatedEntries = self.queueEntries
                        updatedEntries[queueIndex] = QueueEntry(id: updatedEntries[queueIndex].id, song: enrichedQueueSong)
                        self.setQueue(entries: updatedEntries)
                        self.logger.debug("Enriched queue entry at index \(queueIndex): '\(enrichedQueueSong.title)' with artists: \(enrichedQueueSong.artistsDisplay)")
                        // Save the enriched queue to persistence
                        self.saveQueueForPersistence()
                    }
                }
            }
        } catch {
            self.logger.warning("Failed to fetch song metadata: \(error.localizedDescription)")
        }
    }
}
