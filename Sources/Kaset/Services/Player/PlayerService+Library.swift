import Foundation

struct MusicLibraryMutationState {
    let generation: UInt64
    var confirmedState: MusicLibraryConfirmedState?
}

private struct LibraryMutationRequest {
    let token: String?
    let videoId: String
    let accountID: String
    let mutationRevision: UInt64
    let accountSessionGeneration: UInt64
    let expectedState: MusicLibraryConfirmedState
}

private struct CurrentTrackLikeStatusEvidence {
    let cached: LikeStatus?
    let webView: LikeStatus?
    let song: LikeStatus?
    let queue: LikeStatus?
    let visible: LikeStatus
}

@MainActor
extension PlayerService {
    func likeCurrentTrack() {
        self.rateCurrentTrack(self.currentTrackLikeStatus == .like ? .indifferent : .like)
    }

    func dislikeCurrentTrack() {
        self.rateCurrentTrack(self.currentTrackLikeStatus == .dislike ? .indifferent : .dislike)
    }

    @discardableResult
    func rateCurrentTrack(_ newStatus: LikeStatus) -> Task<LikeStatus, Never>? {
        guard self.canPerformAccountMutation else {
            self.logger.info("Ignoring rating request while signed out")
            return nil
        }
        guard let track = currentTrack else { return nil }
        self.logger.info("Rating current track \(track.videoId) as \(String(describing: newStatus))")
        let activeAccountID = self.songLikeStatusManager.activeAccountID
        let client = self.ytMusicClient
        let previousStatus = self.currentTrackLikeStatus
        let request = self.songLikeStatusManager.enqueueRating(
            track,
            status: newStatus,
            accountID: activeAccountID,
            client: client,
            visibleBaseline: previousStatus
        )
        self.currentTrackLikeStatus = newStatus

        return Task {
            let finalStatus = await request.value
            self.reconcileCurrentTrackLikeStatusAfterRating(
                track: track,
                requestedAccountID: activeAccountID,
                finalStatus: finalStatus
            )
            return finalStatus
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

    @discardableResult
    func addToLibrary(song: Song) -> Task<Void, Never> {
        guard self.canPerformAccountMutation, self.ytMusicClient != nil else { return Task {} }
        let queuedSong = self.queueEntries.first {
            $0.song.videoId == song.videoId && ($0.song.isInLibrary != nil || $0.song.feedbackTokens != nil)
        }?.song
        let key = self.songLikeStatusManager.activeAccountID + "\u{0}" + song.videoId
        let confirmedState = self.libraryMutationStates[key]?.confirmedState
        let baseline = self.currentTrack?.videoId == song.videoId
            ? MusicLibraryConfirmedState(
                isInLibrary: self.currentTrackInLibrary,
                feedbackTokens: self.currentTrackFeedbackTokens
            )
            : MusicLibraryConfirmedState(
                isInLibrary: queuedSong?.isInLibrary ?? confirmedState?.isInLibrary ?? song.isInLibrary ?? false,
                feedbackTokens: queuedSong?.feedbackTokens ?? confirmedState?.feedbackTokens ?? song.feedbackTokens
            )
        return self.setLibraryStatus(
            for: song,
            baseline: baseline,
            expectedInLibrary: true,
            token: nil
        )
    }

    func toggleLibraryStatus() {
        guard self.canPerformAccountMutation else {
            self.logger.info("Ignoring library toggle request while signed out")
            return
        }
        guard let track = currentTrack else { return }
        self.logger.info("Toggling library status for current track: \(track.videoId)")
        let isCurrentlyInLibrary = self.currentTrackInLibrary
        let tokenToUse = isCurrentlyInLibrary
            ? self.currentTrackFeedbackTokens?.remove
            : self.currentTrackFeedbackTokens?.add

        guard let token = tokenToUse else {
            self.logger.warning("No feedback token available for library toggle")
            return
        }
        self.setLibraryStatus(
            for: track,
            baseline: MusicLibraryConfirmedState(
                isInLibrary: isCurrentlyInLibrary,
                feedbackTokens: self.currentTrackFeedbackTokens
            ),
            expectedInLibrary: !isCurrentlyInLibrary,
            token: token
        )
    }

    @discardableResult
    private func setLibraryStatus(
        for track: Song,
        baseline: MusicLibraryConfirmedState,
        expectedInLibrary: Bool,
        token: String?
    ) -> Task<Void, Never> {
        let activeAccountID = self.songLikeStatusManager.activeAccountID
        self.libraryMutationRevisionCounter &+= 1
        let mutationKey = activeAccountID + "\u{0}" + track.videoId
        let mutationRevision = self.libraryMutationRevisionCounter
        self.libraryMutationStates[mutationKey] = MusicLibraryMutationState(
            generation: mutationRevision,
            confirmedState: self.libraryMutationStates[mutationKey]?.confirmedState
        )
        self.libraryMutationRevisions[mutationKey] = mutationRevision
        if self.confirmedLibraryStateByKey[mutationKey] == nil {
            self.confirmedLibraryStateByKey[mutationKey] = baseline
        }
        let accountSessionGeneration = self.accountSessionGeneration
        let pendingMutationKey = self.pendingLibraryMutationKey(
            accountID: activeAccountID,
            videoId: track.videoId,
            sessionGeneration: accountSessionGeneration
        )
        self.pendingLibraryMutationCountsByKey[pendingMutationKey, default: 0] += 1

        let expectedFeedbackTokens = baseline.feedbackTokens
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

        return Task {
            defer {
                self.finishLibraryMutationTracking(
                    key: mutationKey,
                    pendingMutationKey: pendingMutationKey,
                    mutationRevision: mutationRevision
                )
            }
            do {
                try await request.value.get()
                guard self.accountSessionGeneration == accountSessionGeneration else { return }
                guard self.isCurrentLibraryMutation(key: mutationKey, revision: mutationRevision) else { return }
                let action = expectedInLibrary ? "added to" : "removed from"
                self.logger.info("Successfully \(action) library")
                let expectedFeedbackTokens = self.confirmedLibraryStateByKey[mutationKey]?.feedbackTokens
                    ?? expectedFeedbackTokens
                self.applyLibraryState(
                    videoId: track.videoId,
                    isInLibrary: expectedInLibrary,
                    feedbackTokens: expectedFeedbackTokens
                )

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
                let confirmedState: MusicLibraryConfirmedState
                if let token = mutation.token {
                    try await client.editSongLibraryStatus(feedbackTokens: [token])
                    confirmedState = mutation.expectedState
                } else {
                    let predecessorState = self.libraryMutationStates[key]?.confirmedState
                    let song = try await client.getSong(videoId: mutation.videoId)
                    guard self.songLikeStatusManager.activeAccountID == mutation.accountID,
                          self.accountSessionGeneration == mutation.accountSessionGeneration,
                          self.canPerformAccountMutation
                    else { return .failure(CancellationError()) }
                    let isInLibrary = song.isInLibrary == true && predecessorState?.isInLibrary != false
                    if !isInLibrary {
                        guard let token = song.feedbackTokens?.add ?? predecessorState?.feedbackTokens?.add else {
                            throw YTMusicError.parseError(message: "Song library token is unavailable")
                        }
                        try await client.editSongLibraryStatus(feedbackTokens: [token])
                    }
                    confirmedState = MusicLibraryConfirmedState(
                        isInLibrary: true,
                        feedbackTokens: song.feedbackTokens ?? predecessorState?.feedbackTokens
                    )
                }
                guard self.songLikeStatusManager.activeAccountID == mutation.accountID,
                      self.accountSessionGeneration == mutation.accountSessionGeneration
                else {
                    return .failure(CancellationError())
                }
                self.confirmedLibraryStateByKey[key] = confirmedState
                self.libraryMutationStates[key]?.confirmedState = confirmedState
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

    private func finishLibraryMutationTracking(
        key: String,
        pendingMutationKey: String,
        mutationRevision: UInt64
    ) {
        guard self.libraryMutationRevisions[key] == mutationRevision,
              self.pendingLibraryMutationCountsByKey[pendingMutationKey] == nil
        else { return }

        self.libraryMutationRevisions.removeValue(forKey: key)
        self.confirmedLibraryStateByKey.removeValue(forKey: key)
    }

    private func isCurrentLibraryMutation(key: String, revision: UInt64) -> Bool {
        self.libraryMutationRevisions[key] == revision
    }

    func updateLikeStatus(_ status: LikeStatus) {
        if let videoId = self.currentTrack?.videoId {
            self.currentTrackWebViewLikeStatusEvidence = (videoId, status)
            self.currentTrackLikeStatus = self.songLikeStatusManager.status(for: videoId) ?? status
        } else {
            self.currentTrackWebViewLikeStatusEvidence = nil
            self.currentTrackLikeStatus = status
        }
    }

    func resetTrackStatus() {
        self.currentTrackLikeStatus = .indifferent
        self.currentTrackWebViewLikeStatusEvidence = nil
        self.currentTrackInLibrary = false
        self.currentTrackFeedbackTokens = nil
    }

    func refreshCurrentTrackLikeStatusFromCache() {
        guard let videoId = self.currentTrack?.videoId,
              let cached = self.songLikeStatusManager.status(for: videoId)
        else { return }
        self.currentTrackLikeStatus = cached
    }

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
        let mutationKey = activeAccountID + "\u{0}" + videoId
        let libraryMutationGeneration = self.libraryMutationStates[mutationKey]?.generation
        let accountSessionGeneration = self.accountSessionGeneration
        let pendingMutationKey = self.pendingLibraryMutationKey(
            accountID: activeAccountID, videoId: videoId,
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

            let likeStatusEvidence = self.currentLikeStatusEvidence(for: videoId)
            let ratingRevisionIsCurrent = self.songLikeStatusManager.ratingRevision(
                for: videoId,
                accountID: activeAccountID
            ) == ratingRevision
            let libraryMutationIsCurrent = self.libraryMutationStates[mutationKey]?.generation == libraryMutationGeneration
                && self.accountSessionGeneration == accountSessionGeneration
                && !libraryMutationWasPending
                && self.pendingLibraryMutationCountsByKey[pendingMutationKey, default: 0] == 0
            let resolvedLikeStatus = self.resolveFetchedLikeStatus(
                videoId: videoId,
                apiLikeStatus: songData.likeStatus,
                evidence: likeStatusEvidence,
                ratingRevisionIsCurrent: ratingRevisionIsCurrent
            )

            if self.currentTrack?.videoId == videoId {
                let title = self.currentTrack?.title == "Loading..." ? songData.title : (self.currentTrack?.title ?? songData.title)

                let artists = Self.resolvedFetchedArtists(existing: self.currentTrack?.artists ?? [], fetched: songData.artists)

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
                    isExplicit: songData.isExplicit ?? self.currentTrack?.isExplicit,
                    audioTrackVideoId: songData.audioTrackVideoId ?? self.currentTrack?.audioTrackVideoId
                )

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
                        if self.confirmedLibraryStateByKey[mutationKey] != nil {
                            self.confirmedLibraryStateByKey[mutationKey] = MusicLibraryConfirmedState(
                                isInLibrary: self.currentTrackInLibrary,
                                feedbackTokens: self.currentTrackFeedbackTokens
                            )
                        }
                    }
                }

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

    private static func resolvedFetchedArtists(existing: [Artist], fetched: [Artist]) -> [Artist] {
        guard !fetched.isEmpty else { return existing }

        if fetched.contains(where: \.hasNavigableId) {
            return fetched
        }

        let existingIsWebPlaceholder = !existing.isEmpty
            && existing.allSatisfy(\.isUnresolvedPlaceholder)
        return existing.isEmpty || existingIsWebPlaceholder ? fetched : existing
    }

    private func resolveFetchedLikeStatus(
        videoId: String,
        apiLikeStatus: LikeStatus?,
        evidence: CurrentTrackLikeStatusEvidence,
        ratingRevisionIsCurrent: Bool
    ) -> LikeStatus? {
        guard ratingRevisionIsCurrent, let apiLikeStatus else {
            return evidence.cached
                ?? evidence.webView
                ?? evidence.song
                ?? evidence.queue
                ?? evidence.visible
        }
        let accepted = self.songLikeStatusManager.setStatus(apiLikeStatus, for: videoId)
        return accepted
            ? apiLikeStatus
            : (self.songLikeStatusManager.status(for: videoId)
                ?? evidence.webView
                ?? evidence.song
                ?? evidence.queue
                ?? evidence.visible)
    }

    private func currentLikeStatusEvidence(for videoId: String) -> CurrentTrackLikeStatusEvidence {
        let queueLikeStatus = self.activePlaybackQueueEntryID.flatMap { entryID in
            self.queueEntries.first {
                $0.id == entryID && $0.song.videoId == videoId
            }?.song.likeStatus
        }
        let webViewLikeStatus = self.currentTrackWebViewLikeStatusEvidence.flatMap { evidence in
            evidence.videoId == videoId ? evidence.status : nil
        }
        return CurrentTrackLikeStatusEvidence(
            cached: self.songLikeStatusManager.status(for: videoId),
            webView: webViewLikeStatus,
            song: self.currentTrack?.likeStatus,
            queue: queueLikeStatus,
            visible: self.currentTrackLikeStatus
        )
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
        let resolvedQueueArtists = Self.resolvedFetchedArtists(
            existing: enrichedQueueSong.artists,
            fetched: response.artists
        )
        if enrichedQueueSong.artists != resolvedQueueArtists {
            enrichedQueueSong = enrichedQueueSong.replacingDisplayMetadata(
                title: enrichedQueueSong.title,
                artists: resolvedQueueArtists,
                thumbnailURL: enrichedQueueSong.thumbnailURL
            )
        }
        if let resolvedLikeStatus {
            enrichedQueueSong.likeStatus = resolvedLikeStatus
        }
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
