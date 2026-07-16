import Foundation

// MARK: - MusicPlaybackIntent

/// Opaque ownership token for one native Music playback intent.
///
/// Web document/media generations reject stale bridge traffic. This token is the
/// complementary native fence: async API work and scheduled corrective actions
/// may mutate playback only while the user intent that created them is current.
struct MusicPlaybackIntent: Equatable {
    let generation: UInt64
}

// MARK: - MusicRemoteTransportCommand

enum MusicRemoteTransportCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case next
    case previous
    case relativeSeek(delta: TimeInterval, admittedAt: ContinuousClock.Instant)
    case absoluteSeek(position: TimeInterval)
}

// MARK: - MusicPlaybackReservation

/// A non-mutating snapshot reserved before parsing or API resolution. It can be
/// claimed exactly while no newer native playback intent has been created.
struct MusicPlaybackReservation: Equatable {
    let playbackGeneration: UInt64
    let reservationGeneration: UInt64
    let queueMutationGeneration: Int
    let queueEntryID: UUID?
    let videoID: String?
}

// MARK: - MusicQueueMetadataOwner

enum MusicQueueMetadataOwner: Equatable {
    case active
    case none
    case entry(UUID)
}

// MARK: - MusicAccountMutationOwner

struct MusicAccountMutationOwner: Hashable {
    let accountID: String
    let sessionGeneration: UInt64
}

// MARK: - MusicLibraryConfirmedState

struct MusicLibraryConfirmedState: Equatable {
    let isInLibrary: Bool
    let feedbackTokens: FeedbackTokens?
}

// MARK: - MusicPlaybackRestoreClock

struct MusicPlaybackRestoreClock: Equatable {
    let progress: TimeInterval
    let duration: TimeInterval
}

@MainActor
extension PlayerService {
    var currentMusicPlaybackIntent: MusicPlaybackIntent {
        MusicPlaybackIntent(generation: self.musicPlaybackIntentGeneration)
    }

    var playbackRequestGeneration: UInt64 {
        self.musicPlaybackIntentGeneration
    }

    @discardableResult
    func beginMusicPlaybackIntent(
        issuedAtMilliseconds: Double? = nil,
        allowsPriorTerminalEvent: Bool = false
    ) -> MusicPlaybackIntent {
        self.invalidateRemoteMusicTransportCommands()
        let previousIntentGeneration = self.musicPlaybackIntentGeneration
        self.musicPlaybackIntentGeneration &+= 1
        self.musicPlaybackReservationGeneration &+= 1
        self.musicPlaybackIntentAcceptsPriorTerminalEvent = allowsPriorTerminalEvent
        if allowsPriorTerminalEvent {
            self.musicPlaybackMinimumAcceptedTerminalIntentGeneration = min(
                self.musicPlaybackMinimumAcceptedTerminalIntentGeneration,
                previousIntentGeneration
            )
        } else {
            self.musicPlaybackMinimumAcceptedTerminalIntentGeneration =
                self.musicPlaybackIntentGeneration
        }
        self.musicPlaybackIntentIssuedAtMilliseconds = if let issuedAtMilliseconds,
                                                          issuedAtMilliseconds.isFinite
        {
            issuedAtMilliseconds
        } else {
            Date().timeIntervalSince1970 * 1000
        }
        return self.currentMusicPlaybackIntent
    }

    func acceptsMusicPlaybackIntent(_ intent: MusicPlaybackIntent) -> Bool {
        intent == self.currentMusicPlaybackIntent
    }

    func acceptsMusicBridgeEvent(
        intent: MusicPlaybackIntent,
        eventIssuedAtMilliseconds: Double?
    ) -> Bool {
        guard self.acceptsMusicPlaybackIntent(intent),
              let eventIssuedAtMilliseconds,
              eventIssuedAtMilliseconds.isFinite
        else { return false }
        return eventIssuedAtMilliseconds > self.musicPlaybackIntentIssuedAtMilliseconds
    }

    func acceptsMusicTerminalBridgeEvent(
        intent: MusicPlaybackIntent,
        eventIssuedAtMilliseconds: Double?
    ) -> Bool {
        if self.acceptsMusicBridgeEvent(
            intent: intent,
            eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
        ) {
            return true
        }
        guard self.musicPlaybackIntentAcceptsPriorTerminalEvent,
              let eventIssuedAtMilliseconds,
              eventIssuedAtMilliseconds.isFinite,
              eventIssuedAtMilliseconds <= self.musicPlaybackIntentIssuedAtMilliseconds
        else { return false }
        return intent.generation >= self.musicPlaybackMinimumAcceptedTerminalIntentGeneration
            && intent.generation <= self.musicPlaybackIntentGeneration
    }

    func acceptsMusicRemoteCommand(
        intent: MusicPlaybackIntent,
        commandIssuedAtMilliseconds: Double?
    ) -> Bool {
        guard self.acceptsMusicPlaybackIntent(intent),
              let commandIssuedAtMilliseconds,
              commandIssuedAtMilliseconds.isFinite
        else { return false }
        if self.remoteMusicTransportIntent == intent {
            return commandIssuedAtMilliseconds >= self.musicPlaybackIntentIssuedAtMilliseconds
        }
        return commandIssuedAtMilliseconds > self.musicPlaybackIntentIssuedAtMilliseconds
    }

    func enqueueRemoteMusicTransportCommand(
        _ command: MusicRemoteTransportCommand,
        issuedAtMilliseconds: Double
    ) {
        guard issuedAtMilliseconds.isFinite else { return }

        if let intent = self.remoteMusicTransportIntent,
           self.acceptsMusicRemoteCommand(
               intent: intent,
               commandIssuedAtMilliseconds: issuedAtMilliseconds
           )
        {
            self.musicPlaybackIntentIssuedAtMilliseconds = max(
                self.musicPlaybackIntentIssuedAtMilliseconds,
                issuedAtMilliseconds
            )
            let pendingCount = self.remoteMusicTransportCommands.count
                - self.remoteMusicTransportCommandReadIndex
            guard pendingCount < 64 else { return }
            self.remoteMusicTransportCommands.append(command)
            return
        }

        let currentIntent = self.currentMusicPlaybackIntent
        guard self.acceptsMusicRemoteCommand(
            intent: currentIntent,
            commandIssuedAtMilliseconds: issuedAtMilliseconds
        ) else { return }
        let intent = self.beginMusicPlaybackIntent(issuedAtMilliseconds: issuedAtMilliseconds)
        let batchGeneration = self.remoteMusicTransportBatchGeneration
        self.remoteMusicTransportIntent = intent
        self.remoteMusicTransportCommands = [command]
        self.remoteMusicTransportCommandReadIndex = 0
        self.remoteMusicTransportTask = Task { @MainActor [weak self] in
            await self?.drainRemoteMusicTransportCommands(
                batchGeneration: batchGeneration,
                intent: intent
            )
        }
    }

    private func drainRemoteMusicTransportCommands(
        batchGeneration: UInt64,
        intent: MusicPlaybackIntent
    ) async {
        defer {
            if self.remoteMusicTransportBatchGeneration == batchGeneration {
                self.remoteMusicTransportCommands.removeAll()
                self.remoteMusicTransportCommandReadIndex = 0
                self.remoteMusicTransportIntent = nil
                self.remoteMusicTransportTask = nil
            }
        }

        while !Task.isCancelled,
              self.remoteMusicTransportBatchGeneration == batchGeneration,
              self.acceptsMusicPlaybackIntent(intent),
              self.remoteMusicTransportCommandReadIndex < self.remoteMusicTransportCommands.count
        {
            let command = self.remoteMusicTransportCommands[self.remoteMusicTransportCommandReadIndex]
            self.remoteMusicTransportCommandReadIndex += 1
            switch command {
            case .play:
                self.clearRemoteMusicSkipCoalescingTarget()
                await self.resume(intent: intent)
            case .pause:
                self.clearRemoteMusicSkipCoalescingTarget()
                await self.pause(intent: intent)
            case .togglePlayPause:
                self.clearRemoteMusicSkipCoalescingTarget()
                await self.playPause(intent: intent)
            case .next:
                self.clearRemoteMusicSkipCoalescingTarget()
                await self.next(intent: intent, defersNetworkFollowUp: true)
            case .previous:
                self.clearRemoteMusicSkipCoalescingTarget()
                await self.previous(intent: intent, defersNetworkFollowUp: true)
            case let .relativeSeek(delta, admittedAt):
                await self.applyRemoteMusicRelativeSeek(
                    delta: delta,
                    admittedAt: admittedAt,
                    batchGeneration: batchGeneration,
                    intent: intent
                )
            case let .absoluteSeek(position):
                self.clearRemoteMusicSkipCoalescingTarget()
                guard position.isFinite else { continue }
                await self.seek(to: position, intent: intent)
            }
        }

        let completedBatch = !Task.isCancelled
            && self.remoteMusicTransportBatchGeneration == batchGeneration
            && self.acceptsMusicPlaybackIntent(intent)
            && self.remoteMusicTransportCommandReadIndex >= self.remoteMusicTransportCommands.count
        if completedBatch {
            self.scheduleRemoteMusicTransportFollowUp()
        }
    }

    func clearRemoteMusicSkipCoalescingTarget() {
        self.remoteMusicSkipTarget = nil
        self.remoteMusicSkipVideoID = nil
        self.remoteMusicSkipQueueEntryID = nil
        self.remoteMusicSkipAdmittedAt = nil
    }

    func cancelRemoteMusicTransportFollowUp() {
        self.remoteMusicMetadataFollowUpGeneration &+= 1
        self.remoteMusicMetadataFollowUpTask?.cancel()
        self.remoteMusicMetadataFollowUpTask = nil
        self.remoteMusicQueueFollowUpGeneration &+= 1
        self.remoteMusicQueueFollowUpTask?.cancel()
        self.remoteMusicQueueFollowUpTask = nil
    }

    private func scheduleRemoteMusicTransportFollowUp() {
        self.scheduleRemoteMusicMetadataFollowUp()
        self.scheduleRemoteMusicQueueFollowUp()
    }

    private func scheduleRemoteMusicMetadataFollowUp() {
        self.remoteMusicMetadataFollowUpGeneration &+= 1
        let generation = self.remoteMusicMetadataFollowUpGeneration
        self.remoteMusicMetadataFollowUpTask?.cancel()
        self.remoteMusicMetadataFollowUpTask = nil

        guard let currentTrack = self.currentTrack else { return }
        let queueEntryID = self.queueEntryIDOwningCurrentPlayback
        let queueEntryNeedsMetadata = queueEntryID.flatMap { entryID in
            self.queueEntries.first(where: { $0.id == entryID })?.song.feedbackTokens == nil
        } ?? false
        guard currentTrack.feedbackTokens == nil || queueEntryNeedsMetadata else { return }
        let videoID = currentTrack.videoId

        self.remoteMusicMetadataFollowUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.remoteMusicMetadataFollowUpGeneration == generation {
                    self.remoteMusicMetadataFollowUpTask = nil
                }
            }
            guard self.remoteMusicMetadataFollowUpGeneration == generation,
                  self.queueEntryIDOwningCurrentPlayback == queueEntryID,
                  self.currentTrack?.videoId == videoID
            else { return }
            await self.fetchSongMetadata(
                videoId: videoID,
                queueOwner: queueEntryID.map(MusicQueueMetadataOwner.entry) ?? .none
            )
        }
    }

    private func scheduleRemoteMusicQueueFollowUp() {
        guard self.remoteMusicQueueFollowUpTask == nil else { return }
        self.remoteMusicQueueFollowUpGeneration &+= 1
        let generation = self.remoteMusicQueueFollowUpGeneration
        let queueGeneration = self.queueLoadGeneration
        self.remoteMusicQueueFollowUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.remoteMusicQueueFollowUpGeneration == generation {
                    self.remoteMusicQueueFollowUpTask = nil
                }
            }
            guard self.remoteMusicQueueFollowUpGeneration == generation,
                  self.isCurrentQueueLoad(queueGeneration)
            else { return }
            await self.fetchMoreMixSongsIfNeeded(queueGeneration: queueGeneration)
            guard self.remoteMusicQueueFollowUpGeneration == generation,
                  self.isCurrentQueueLoad(queueGeneration)
            else { return }
            await self.fillSmartShuffleWindow()
            guard self.remoteMusicQueueFollowUpGeneration == generation,
                  self.isCurrentQueueLoad(queueGeneration)
            else { return }
            self.saveQueueForPersistence()
        }
    }

    private func applyRemoteMusicRelativeSeek(
        delta: TimeInterval,
        admittedAt: ContinuousClock.Instant,
        batchGeneration: UInt64,
        intent: MusicPlaybackIntent
    ) async {
        guard delta.isFinite,
              self.remoteMusicTransportBatchGeneration == batchGeneration,
              self.acceptsMusicPlaybackIntent(intent)
        else { return }

        let currentVideoID = self.currentTrack?.videoId ?? self.pendingPlayVideoId
        let currentQueueEntryID = self.queueEntryIDOwningCurrentPlayback
        let playbackSnapshot = await self.currentMusicPlaybackSnapshot()
        guard self.remoteMusicTransportBatchGeneration == batchGeneration,
              self.acceptsMusicPlaybackIntent(intent)
        else { return }
        guard self.queueEntryIDOwningCurrentPlayback == currentQueueEntryID,
              (self.currentTrack?.videoId ?? self.pendingPlayVideoId) == currentVideoID,
              let playbackSnapshot,
              self.remoteMusicPlaybackSnapshot(playbackSnapshot, matches: currentVideoID)
        else {
            self.clearRemoteMusicSkipCoalescingTarget()
            return
        }

        let canCoalesce = self.remoteMusicSkipVideoID == currentVideoID
            && self.remoteMusicSkipQueueEntryID == currentQueueEntryID
            && self.remoteMusicSkipAdmittedAt.map {
                admittedAt >= $0 && admittedAt - $0 <= .seconds(1)
            } == true
        let baseProgress = if canCoalesce, let remoteMusicSkipTarget = self.remoteMusicSkipTarget {
            remoteMusicSkipTarget
        } else {
            playbackSnapshot.progress
        }
        let rawTarget = baseProgress + delta
        let target = if playbackSnapshot.duration > 0 {
            min(max(0, rawTarget), playbackSnapshot.duration)
        } else {
            max(0, rawTarget)
        }

        self.remoteMusicSkipTarget = target
        self.remoteMusicSkipVideoID = currentVideoID
        self.remoteMusicSkipQueueEntryID = currentQueueEntryID
        self.remoteMusicSkipAdmittedAt = admittedAt
        self.progress = target
        await self.seek(to: target, intent: intent)
    }

    private func remoteMusicPlaybackSnapshot(
        _ snapshot: SingletonPlayerWebView.PlaybackSnapshot,
        matches currentVideoID: String?
    ) -> Bool {
        guard let snapshotVideoID = snapshot.videoId, let currentVideoID else { return true }
        return snapshotVideoID == currentVideoID
    }

    private func invalidateRemoteMusicTransportCommands() {
        self.remoteMusicTransportBatchGeneration &+= 1
        self.remoteMusicTransportTask?.cancel()
        self.remoteMusicTransportTask = nil
        self.remoteMusicTransportCommands.removeAll()
        self.remoteMusicTransportCommandReadIndex = 0
        self.remoteMusicTransportIntent = nil
    }

    func reserveMusicPlaybackIntent() -> MusicPlaybackReservation {
        self.musicPlaybackReservationGeneration &+= 1
        return MusicPlaybackReservation(
            playbackGeneration: self.musicPlaybackIntentGeneration,
            reservationGeneration: self.musicPlaybackReservationGeneration,
            queueMutationGeneration: self.reserveQueueMutation(),
            queueEntryID: self.queueEntryIDOwningCurrentPlayback,
            videoID: self.currentTrack?.videoId ?? self.pendingPlayVideoId
        )
    }

    func acceptsMusicPlaybackReservation(_ reservation: MusicPlaybackReservation) -> Bool {
        reservation.playbackGeneration == self.musicPlaybackIntentGeneration
            && reservation.reservationGeneration == self.musicPlaybackReservationGeneration
            && reservation.queueEntryID == self.queueEntryIDOwningCurrentPlayback
            && reservation.videoID == (self.currentTrack?.videoId ?? self.pendingPlayVideoId)
    }

    func claimMusicPlaybackIntent(_ reservation: MusicPlaybackReservation) -> MusicPlaybackIntent? {
        guard reservation.playbackGeneration == self.musicPlaybackIntentGeneration,
              reservation.reservationGeneration == self.musicPlaybackReservationGeneration
        else { return nil }
        return self.beginMusicPlaybackIntent()
    }

    func claimMusicPlaybackIntent(
        _ reservation: MusicPlaybackReservation,
        queueEntryID: UUID
    ) -> MusicPlaybackIntent? {
        guard self.queueEntries.contains(where: { $0.id == queueEntryID }) else { return nil }
        return self.claimMusicPlaybackIntent(reservation)
    }

    func currentQueueEntryID(matching song: Song) -> UUID? {
        guard let entry = self.queueEntries[safe: self.currentIndex],
              entry.song.id == song.id,
              entry.song.videoId == song.videoId
        else { return nil }
        return entry.id
    }

    var queueEntryIDOwningCurrentPlayback: UUID? {
        guard let currentTrack = self.currentTrack,
              let activePlaybackQueueEntryID,
              let entry = self.queueEntries.first(where: { $0.id == activePlaybackQueueEntryID }),
              entry.song.videoId == currentTrack.videoId
        else { return nil }
        return entry.id
    }

    var activePlaybackQueueIndex: Int? {
        guard let entryID = self.queueEntryIDOwningCurrentPlayback else { return nil }
        return self.queueEntries.firstIndex(where: { $0.id == entryID })
    }

    var activePlaybackOwnsCurrentQueueEntry: Bool {
        self.activePlaybackQueueEntryID != nil
            && self.activePlaybackQueueEntryID == self.currentQueueEntryID
    }

    var shouldUseNativeQueueForTrackNavigation: Bool {
        self.activePlaybackOwnsCurrentQueueEntry
            || (
                self.currentTrack == nil
                    && self.pendingPlayVideoId == nil
                    && self.currentEpisode == nil
            )
    }

    func invalidateMixContinuationRequest() {
        self.activeMixContinuationRequestID = nil
        self.isFetchingMoreMixSongs = false
        let waiters = self.mixContinuationWaiters
        self.mixContinuationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForActiveMixContinuationRequest() async {
        guard self.isFetchingMoreMixSongs else { return }
        await withCheckedContinuation { continuation in
            self.mixContinuationWaiters.append(continuation)
        }
    }

    func finishMixContinuationRequest(_ requestID: UUID) {
        guard self.activeMixContinuationRequestID == requestID else { return }
        self.activeMixContinuationRequestID = nil
        self.isFetchingMoreMixSongs = false
        let waiters = self.mixContinuationWaiters
        self.mixContinuationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func scheduleMusicPlaybackIntentTask(
        expectedQueueEntryID: UUID? = nil,
        operation: @escaping @MainActor (PlayerService, MusicPlaybackIntent) async -> Void
    ) {
        let intent = self.currentMusicPlaybackIntent
        Task { @MainActor [weak self] in
            guard let self,
                  self.acceptsMusicPlaybackIntent(intent)
            else { return }
            if let expectedQueueEntryID,
               self.currentQueueEntryID != expectedQueueEntryID
            {
                return
            }
            await operation(self, intent)
        }
    }
}
