import Foundation

// MARK: - LibraryMutationRequest

private struct LibraryMutationRequest {
    let token: String
    let videoId: String
    let accountID: String
    let mutationRevision: UInt64
    let accountSessionGeneration: UInt64
    let expectedState: MusicLibraryConfirmedState
}

@MainActor
extension PlayerService {
    /// Likes the current track (thumbs up).
    /// Delegates to SongLikeStatusManager for unified state management and real-time sync.
    func likeCurrentTrack() {
        guard self.canPerformAccountMutation else {
            self.logger.info("Ignoring like request while signed out")
            return
        }
        guard let track = currentTrack else { return }
        self.logger.info("Liking current track: \(track.videoId)")
        let activeAccountID = self.songLikeStatusManager.activeAccountID
        let client = self.ytMusicClient
        let previousStatus = self.currentTrackLikeStatus
        // Toggle: if already liked, remove the like
        let newStatus: LikeStatus = previousStatus == .like ? .indifferent : .like
        let request = self.songLikeStatusManager.enqueueRating(
            track,
            status: newStatus,
            accountID: activeAccountID,
            client: client,
            visibleBaseline: previousStatus
        )
        // Optimistic UI update for PlayerBar
        self.currentTrackLikeStatus = newStatus

        Task {
            let finalStatus = await request.value
            self.reconcileCurrentTrackLikeStatusAfterRating(
                track: track,
                requestedAccountID: activeAccountID,
                finalStatus: finalStatus
            )
        }
    }

    /// Dislikes the current track (thumbs down).
    /// Delegates to SongLikeStatusManager for unified state management and real-time sync.
    func dislikeCurrentTrack() {
        guard self.canPerformAccountMutation else {
            self.logger.info("Ignoring dislike request while signed out")
            return
        }
        guard let track = currentTrack else { return }
        self.logger.info("Disliking current track: \(track.videoId)")
        let activeAccountID = self.songLikeStatusManager.activeAccountID
        let client = self.ytMusicClient
        let previousStatus = self.currentTrackLikeStatus
        // Toggle: if already disliked, remove the dislike
        let newStatus: LikeStatus = previousStatus == .dislike ? .indifferent : .dislike
        let request = self.songLikeStatusManager.enqueueRating(
            track,
            status: newStatus,
            accountID: activeAccountID,
            client: client,
            visibleBaseline: previousStatus
        )
        // Optimistic UI update for PlayerBar
        self.currentTrackLikeStatus = newStatus

        Task {
            let finalStatus = await request.value
            self.reconcileCurrentTrackLikeStatusAfterRating(
                track: track,
                requestedAccountID: activeAccountID,
                finalStatus: finalStatus
            )
        }
    }

    private func reconcileCurrentTrackLikeStatusAfterRating(
        track: Song,
        requestedAccountID: String,
        finalStatus: LikeStatus
    ) {
        guard self.currentTrack?.videoId == track.videoId else {
            return
        }

        guard self.songLikeStatusManager.activeAccountID == requestedAccountID else {
            self.currentTrackLikeStatus = self.songLikeStatusManager.status(for: track.videoId) ?? .indifferent
            return
        }

        self.currentTrackLikeStatus = finalStatus
    }

    // swiftlint:disable function_body_length

    /// Toggles the library status of the current track.
    func toggleLibraryStatus() {
        guard self.canPerformAccountMutation else {
            self.logger.info("Ignoring library toggle request while signed out")
            return
        }
        guard let track = currentTrack else { return }
        self.logger.info("Toggling library status for current track: \(track.videoId)")
        let activeAccountID = self.songLikeStatusManager.activeAccountID

        // Determine which token to use based on current state
        let isCurrentlyInLibrary = self.currentTrackInLibrary
        let tokenToUse = isCurrentlyInLibrary
            ? self.currentTrackFeedbackTokens?.remove
            : self.currentTrackFeedbackTokens?.add

        guard let token = tokenToUse else {
            self.logger.warning("No feedback token available for library toggle")
            return
        }
        self.libraryMutationGeneration &+= 1
        self.libraryMutationRevisionCounter &+= 1
        let mutationKey = activeAccountID + "\u{0}" + track.videoId
        let mutationRevision = self.libraryMutationRevisionCounter
        self.libraryMutationRevisions[mutationKey] = mutationRevision
        if self.confirmedLibraryStateByKey[mutationKey] == nil {
            self.confirmedLibraryStateByKey[mutationKey] = MusicLibraryConfirmedState(
                isInLibrary: self.currentTrackInLibrary,
                feedbackTokens: self.currentTrackFeedbackTokens
            )
        }
        let accountSessionGeneration = self.accountSessionGeneration
        let pendingMutationKey = self.pendingLibraryMutationKey(
            accountID: activeAccountID,
            videoId: track.videoId,
            sessionGeneration: accountSessionGeneration
        )
        self.pendingLibraryMutationCountsByKey[pendingMutationKey, default: 0] += 1

        // Optimistic update
        let currentTokens = self.currentTrackFeedbackTokens
        let expectedInLibrary = !isCurrentlyInLibrary
        // Feedback tokens are action-specific. Keep the known add/remove pair
        // stable until an authoritative metadata refresh rotates it.
        let expectedFeedbackTokens = currentTokens
        self.applyLibraryState(
            videoId: track.videoId,
            isInLibrary: expectedInLibrary,
            feedbackTokens: expectedFeedbackTokens
        )

        let mutation = LibraryMutationRequest(
            token: token,
            videoId: track.videoId,
            accountID: activeAccountID,
            mutationRevision: mutationRevision,
            accountSessionGeneration: accountSessionGeneration,
            expectedState: MusicLibraryConfirmedState(
                isInLibrary: expectedInLibrary,
                feedbackTokens: expectedFeedbackTokens
            )
        )
        let request = self.enqueueSerializedLibraryMutation(mutation)

        // Use API call for reliable library management
        Task {
            do {
                try await request.value.get()
                guard self.accountSessionGeneration == accountSessionGeneration else { return }
                guard self.isCurrentLibraryMutation(key: mutationKey, revision: mutationRevision) else { return }
                let action = isCurrentlyInLibrary ? "removed from" : "added to"
                self.logger.info("Successfully \(action) library")

                // The browse metadata can lag briefly, so delay the refresh and keep
                // the optimistic library state if the response is still stale.
                try? await Task.sleep(for: .milliseconds(500))

                guard self.songLikeStatusManager.activeAccountID == activeAccountID,
                      self.accountSessionGeneration == accountSessionGeneration,
                      self.isCurrentLibraryMutation(key: mutationKey, revision: mutationRevision)
                else { return }

                await self.fetchSongMetadata(
                    videoId: track.videoId,
                    updatesConfirmedLibraryState: false
                )

                guard self.songLikeStatusManager.activeAccountID == activeAccountID,
                      self.accountSessionGeneration == accountSessionGeneration,
                      self.isCurrentLibraryMutation(key: mutationKey, revision: mutationRevision),
                      self.currentTrack?.videoId == track.videoId
                else {
                    return
                }

                if self.currentTrack?.isInLibrary != expectedInLibrary {
                    self.applyLibraryState(
                        videoId: track.videoId,
                        isInLibrary: expectedInLibrary,
                        feedbackTokens: expectedFeedbackTokens
                    )
                } else {
                    self.confirmedLibraryStateByKey[mutationKey] = MusicLibraryConfirmedState(
                        isInLibrary: expectedInLibrary,
                        feedbackTokens: self.currentTrackFeedbackTokens
                    )
                }
            } catch {
                self.logger.error("Failed to toggle library status: \(error.localizedDescription)")
                // Revert the exact optimistic queue entry when this mutation is still latest.
                guard self.accountSessionGeneration == accountSessionGeneration,
                      self.isCurrentLibraryMutation(key: mutationKey, revision: mutationRevision)
                else { return }
                guard let confirmedState = self.confirmedLibraryStateByKey[mutationKey] else { return }
                self.applyLibraryState(
                    videoId: track.videoId,
                    isInLibrary: confirmedState.isInLibrary,
                    feedbackTokens: confirmedState.feedbackTokens
                )
            }
        }
    }

    // swiftlint:enable function_body_length

    private func enqueueSerializedLibraryMutation(
        _ mutation: LibraryMutationRequest
    ) -> Task<Result<Void, any Error>, Never> {
        let key = mutation.accountID + "\u{0}" + mutation.videoId
        let pendingMutationKey = self.pendingLibraryMutationKey(
            accountID: mutation.accountID,
            videoId: mutation.videoId,
            sessionGeneration: mutation.accountSessionGeneration
        )
        let client = self.ytMusicClient
        let predecessor = self.libraryMutationTails[key]
        let request = Task { () -> Result<Void, any Error> in
            defer {
                self.finishSerializedLibraryMutation(
                    key: key,
                    pendingMutationKey: pendingMutationKey,
                    mutationRevision: mutation.mutationRevision
                )
            }
            if let predecessor {
                _ = await predecessor.value
            }
            guard self.songLikeStatusManager.activeAccountID == mutation.accountID,
                  self.accountSessionGeneration == mutation.accountSessionGeneration,
                  let client
            else {
                return .failure(CancellationError())
            }
            do {
                try await client.editSongLibraryStatus(feedbackTokens: [mutation.token])
                guard self.accountSessionGeneration == mutation.accountSessionGeneration else {
                    return .failure(CancellationError())
                }
                self.confirmedLibraryStateByKey[key] = mutation.expectedState
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        self.libraryMutationTails[key] = request
        self.libraryMutationTailGenerations[key] = mutation.mutationRevision
        return request
    }

    private func finishSerializedLibraryMutation(
        key: String,
        pendingMutationKey: String,
        mutationRevision: UInt64
    ) {
        self.finishPendingLibraryMutation(key: pendingMutationKey)
        if self.libraryMutationTailGenerations[key] == mutationRevision {
            self.libraryMutationTails.removeValue(forKey: key)
            self.libraryMutationTailGenerations.removeValue(forKey: key)
        }
    }

    private func pendingLibraryMutationKey(
        accountID: String,
        videoId: String,
        sessionGeneration: UInt64
    ) -> String {
        accountID + "\u{0}" + videoId + "\u{0}" + String(sessionGeneration)
    }

    private func finishPendingLibraryMutation(key: String) {
        guard let count = self.pendingLibraryMutationCountsByKey[key] else { return }
        if count <= 1 {
            self.pendingLibraryMutationCountsByKey.removeValue(forKey: key)
        } else {
            self.pendingLibraryMutationCountsByKey[key] = count - 1
        }
    }

    private func isCurrentLibraryMutation(key: String, revision: UInt64) -> Bool {
        self.libraryMutationRevisions[key] == revision
    }

    /// Updates the like status from WebView observation.
    /// Only updates PlayerService state for UI; does NOT overwrite SongLikeStatusManager cache
    /// because WebView often reports INDIFFERENT as a default when the actual status is unknown.
    func updateLikeStatus(_ status: LikeStatus) {
        // Only accept WebView status if SongLikeStatusManager has no cached value
        // (cache is more authoritative than WebView's observation)
        if let videoId = self.currentTrack?.videoId,
           let cachedStatus = self.songLikeStatusManager.status(for: videoId)
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

    /// Refreshes the now-playing track's like status from the `SongLikeStatusManager`
    /// cache. Bulk sources (e.g. the Liked Music page) seed like state *after* the
    /// current track may have already resolved to `.indifferent` — its `getSong` fetch
    /// returns no rating, and the cache can be empty at play time. Without this, the
    /// player bar / Now Playing surfaces (and the boring.notch mirror) keep showing
    /// "not liked" for a track that is actually liked. Only fills an unknown status;
    /// never overrides a known `.like` / `.dislike`.
    func refreshCurrentTrackLikeStatusFromCache() {
        guard self.currentTrackLikeStatus == .indifferent,
              let videoId = self.currentTrack?.videoId,
              let cached = self.songLikeStatusManager.status(for: videoId)
        else { return }
        self.currentTrackLikeStatus = cached
    }

    /// Keeps the now-playing like status in sync with the like cache. The status has no
    /// reliable synchronous source (getSong returns no rating; the account-scoped cache is
    /// seeded asynchronously by the Liked Music page and cleared then refilled across login
    /// identity switches), so a one-shot read at track load races and leaves it stuck at
    /// `.indifferent`. Re-resolving whenever the track or the cache changes makes it
    /// self-correcting the moment the user's likes finish loading.
    func observeNowPlayingLikeStatus() {
        withObservationTracking {
            _ = self.currentTrack?.videoId
            _ = self.songLikeStatusManager.cacheGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshCurrentTrackLikeStatusFromCache()
                self?.observeNowPlayingLikeStatus()
            }
        }
    }

    private func applyLibraryState(
        videoId: String,
        isInLibrary: Bool,
        feedbackTokens: FeedbackTokens?
    ) {
        var didChange = false
        if var currentTrack = self.currentTrack, currentTrack.videoId == videoId {
            self.currentTrackInLibrary = isInLibrary
            self.currentTrackFeedbackTokens = feedbackTokens
            currentTrack.isInLibrary = isInLibrary
            currentTrack.feedbackTokens = feedbackTokens
            self.currentTrack = currentTrack
            didChange = true
        }

        var updatedEntries = self.queueEntries
        var didChangeQueue = false
        for index in updatedEntries.indices where updatedEntries[index].song.videoId == videoId {
            var song = updatedEntries[index].song
            song.isInLibrary = isInLibrary
            song.feedbackTokens = feedbackTokens
            updatedEntries[index] = QueueEntry(
                id: updatedEntries[index].id,
                song: song,
                source: updatedEntries[index].source
            )
            didChange = true
            didChangeQueue = true
        }
        if didChangeQueue {
            self.setQueue(entries: updatedEntries)
        }
        if didChange {
            self.saveQueueForPersistence()
        }
    }

    /// Fetches full song metadata including feedbackTokens from the API.
    func fetchSongMetadata(
        videoId: String,
        queueOwner: MusicQueueMetadataOwner = .active,
        updatesConfirmedLibraryState: Bool = true
    ) async {
        guard let client = ytMusicClient else {
            self.logger.warning("No YTMusicClient available for fetching song metadata")
            return
        }

        let activeAccountID = self.songLikeStatusManager.activeAccountID
        let ratingRevision = self.songLikeStatusManager.ratingRevision(
            for: videoId,
            accountID: activeAccountID
        )
        let libraryMutationGeneration = self.libraryMutationGeneration
        let accountSessionGeneration = self.accountSessionGeneration
        let pendingMutationKey = self.pendingLibraryMutationKey(
            accountID: activeAccountID,
            videoId: videoId,
            sessionGeneration: accountSessionGeneration
        )
        let libraryMutationWasPending = self.pendingLibraryMutationCountsByKey[pendingMutationKey, default: 0] > 0
        let queueEntryID: UUID? = switch queueOwner {
        case .active: self.activePlaybackQueueEntryID
        case .none: nil
        case let .entry(entryID): entryID
        }

        do {
            let songData = try await client.getSong(videoId: videoId)
            guard self.songLikeStatusManager.activeAccountID == activeAccountID,
                  self.currentTrack?.videoId == videoId
            else { return }
            let queueOwnerIsCurrent = self.activePlaybackQueueEntryID == queueEntryID

            let cachedLikeStatus = self.songLikeStatusManager.status(for: videoId)
            let ratingRevisionIsCurrent = self.songLikeStatusManager.ratingRevision(
                for: videoId,
                accountID: activeAccountID
            ) == ratingRevision
            let libraryMutationIsCurrent = self.libraryMutationGeneration == libraryMutationGeneration
                && self.accountSessionGeneration == accountSessionGeneration
                && !libraryMutationWasPending
                && self.pendingLibraryMutationCountsByKey[pendingMutationKey, default: 0] == 0
            let resolvedLikeStatus = self.resolveFetchedLikeStatus(
                videoId: videoId,
                apiLikeStatus: songData.likeStatus,
                cachedLikeStatus: cachedLikeStatus,
                ratingRevisionIsCurrent: ratingRevisionIsCurrent
            )

            // Update current track with full metadata if it's still the same song
            if self.currentTrack?.videoId == videoId {
                // Preserve the title/artist from WebView if they're better
                let title = self.currentTrack?.title == "Loading..." ? songData.title : (self.currentTrack?.title ?? songData.title)
                let artists = self.currentTrack?.artists.isEmpty == true ? songData.artists : (self.currentTrack?.artists ?? songData.artists)

                self.currentTrack = Song(
                    id: self.currentTrack?.id ?? videoId,
                    title: title,
                    artists: artists,
                    album: songData.album ?? self.currentTrack?.album,
                    duration: songData.duration ?? self.currentTrack?.duration,
                    thumbnailURL: songData.thumbnailURL ?? self.currentTrack?.thumbnailURL,
                    videoId: videoId,
                    isPlayable: songData.isPlayable,
                    hasVideo: songData.hasVideo ?? self.currentTrack?.hasVideo,
                    musicVideoType: songData.musicVideoType ?? self.currentTrack?.musicVideoType,
                    likeStatus: resolvedLikeStatus,
                    isInLibrary: libraryMutationIsCurrent
                        ? songData.isInLibrary
                        : self.currentTrack?.isInLibrary,
                    feedbackTokens: libraryMutationIsCurrent
                        ? songData.feedbackTokens
                        : self.currentTrack?.feedbackTokens,
                    isExplicit: songData.isExplicit ?? self.currentTrack?.isExplicit
                )

                // Update service state and sync with SongLikeStatusManager.
                // Unknown like status stays out of the cache so it cannot override
                // a known rating from the WebView or a prior user action.
                if let resolvedLikeStatus {
                    self.currentTrackLikeStatus = resolvedLikeStatus
                }
                if libraryMutationIsCurrent {
                    self.applyLibraryState(
                        videoId: videoId,
                        isInLibrary: songData.isInLibrary ?? false,
                        feedbackTokens: songData.feedbackTokens
                    )
                    if updatesConfirmedLibraryState {
                        let key = activeAccountID + "\u{0}" + videoId
                        self.confirmedLibraryStateByKey[key] = MusicLibraryConfirmedState(
                            isInLibrary: self.currentTrackInLibrary,
                            feedbackTokens: self.currentTrackFeedbackTokens
                        )
                    }
                }

                // Update video availability based on API-detected musicVideoType
                // This is more reliable than DOM inspection since it comes directly from the API
                if let videoType = songData.musicVideoType {
                    self.updateVideoAvailability(hasVideo: videoType.hasVideoContent)
                    self.logger.debug("Video availability from API: \(videoType.rawValue) -> hasVideo=\(videoType.hasVideoContent)")
                }

                self.logger.info("Updated track metadata - inLibrary: \(self.currentTrackInLibrary), hasTokens: \(self.currentTrackFeedbackTokens != nil)")

                self.applyFetchedMetadataToQueue(
                    entryID: queueOwnerIsCurrent ? queueEntryID : nil,
                    response: songData,
                    resolvedLikeStatus: resolvedLikeStatus,
                    libraryMutationIsCurrent: libraryMutationIsCurrent
                )
            }
        } catch {
            self.logger.warning("Failed to fetch song metadata: \(error.localizedDescription)")
        }
    }

    private func resolveFetchedLikeStatus(
        videoId: String,
        apiLikeStatus: LikeStatus?,
        cachedLikeStatus: LikeStatus?,
        ratingRevisionIsCurrent: Bool
    ) -> LikeStatus? {
        guard ratingRevisionIsCurrent, let apiLikeStatus else {
            return cachedLikeStatus ?? self.currentTrackLikeStatus
        }
        let accepted = self.songLikeStatusManager.setStatus(apiLikeStatus, for: videoId)
        return accepted
            ? apiLikeStatus
            : (self.songLikeStatusManager.status(for: videoId) ?? self.currentTrackLikeStatus)
    }

    private func applyFetchedMetadataToQueue(
        entryID: UUID?,
        response: Song,
        resolvedLikeStatus: LikeStatus?,
        libraryMutationIsCurrent: Bool
    ) {
        guard let entryID,
              let queueIndex = self.queueEntries.firstIndex(where: { $0.id == entryID })
        else { return }

        let currentQueueSong = self.queueEntries[queueIndex].song
        var enrichedQueueSong = Self.songNeedsQueueEnrichment(currentQueueSong)
            ? Self.mergingQueueMetadata(current: currentQueueSong, response: response)
            : currentQueueSong
        enrichedQueueSong.likeStatus = resolvedLikeStatus
        if entryID == self.activePlaybackQueueEntryID {
            enrichedQueueSong.isInLibrary = self.currentTrackInLibrary
            enrichedQueueSong.feedbackTokens = self.currentTrackFeedbackTokens
        } else if libraryMutationIsCurrent {
            enrichedQueueSong.isInLibrary = response.isInLibrary
            enrichedQueueSong.feedbackTokens = response.feedbackTokens
        }
        var updatedEntries = self.queueEntries
        updatedEntries[queueIndex] = QueueEntry(
            id: updatedEntries[queueIndex].id,
            song: enrichedQueueSong,
            source: updatedEntries[queueIndex].source
        )
        self.setQueue(entries: updatedEntries)
        self.logger.debug(
            "Enriched queue entry at index \(queueIndex): '\(enrichedQueueSong.title)' with artists: \(enrichedQueueSong.artistsDisplay)"
        )
        self.saveQueueForPersistence()
    }
}
