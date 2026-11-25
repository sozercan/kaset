import Foundation

struct LikeStatusEvent: Equatable {
    let videoId: String
    let status: LikeStatus
    let song: Song?
    let addsLikedMusicMembership: Bool?
    private let eventId: UUID

    init(
        videoId: String,
        status: LikeStatus,
        song: Song?,
        addsLikedMusicMembership: Bool? = nil
    ) {
        self.videoId = videoId
        self.status = status
        self.song = song
        self.addsLikedMusicMembership = addsLikedMusicMembership
        self.eventId = UUID()
    }

    static func == (lhs: LikeStatusEvent, rhs: LikeStatusEvent) -> Bool {
        lhs.eventId == rhs.eventId
    }
}

struct LikeStatusEventBatch: Equatable {
    let accountID: String
    let events: [LikeStatusEvent]
    private let batchId: UUID

    init(accountID: String, events: [LikeStatusEvent]) {
        self.accountID = accountID
        self.events = events
        self.batchId = UUID()
    }

    static func == (lhs: LikeStatusEventBatch, rhs: LikeStatusEventBatch) -> Bool {
        lhs.batchId == rhs.batchId
    }
}

struct LikedMusicRequestSnapshot: Equatable {
    let accountID: String
    let scopeGeneration: UInt64
    let requestID: UInt64
}

struct LikedMusicReconciliation {
    let tracks: [Song]
    let filteredVideoIDs: Set<String>
    let insertedVideoIDs: Set<String>
    let localOverlayVideoIDs: Set<String>
    let newLikedMembershipVideoIDs: Set<String>
}

@MainActor
@Observable
final class SongLikeStatusManager {
    private struct ConfirmedRatingStatus {
        let value: LikeStatus?
    }

    private struct RatingMutationRequest {
        let videoId: String
        let status: LikeStatus
        let accountID: String
        let revision: UInt64
        let sessionGeneration: UInt64
    }

    private struct PendingRating {
        let revision: UInt64
        let status: LikeStatus
        let song: Song
    }

    private struct LocalRatingOverlay {
        let revision: UInt64
        let status: LikeStatus
        let song: Song
        let addsLikedMusicMembership: Bool
        var protectedRequestIDs: Set<UInt64>
    }

    static let shared = SongLikeStatusManager()

    private static let primaryAccountID = "primary"
    static let guestAccountID = "guest"

    private(set) var cacheGeneration: UInt64 = 0

    private var statusCacheByAccount: [String: [String: LikeStatus]] = [:] {
        didSet { self.cacheGeneration &+= 1 }
    }

    private var sessionGeneration: UInt64 = 0
    private(set) var requestScopeGeneration: UInt64 = 0
    private var likedMusicRequestCounter: UInt64 = 0
    private var activeLikedMusicRequestIDsByAccount: [String: Set<UInt64>] = [:]
    private var ratingRevisionCounter: UInt64 = 0
    private var ratingRevisionByAccount: [String: [String: UInt64]] = [:]
    private var confirmedStatusByAccount: [String: [String: ConfirmedRatingStatus]] = [:]
    private var pendingRatingByAccount: [String: [String: PendingRating]] = [:]
    private var localRatingOverlayByAccount: [String: [String: LocalRatingOverlay]] = [:]
    @ObservationIgnored private var ratingMutationTails: [String: Task<Result<Void, any Error>, Never>] = [:]
    @ObservationIgnored private var ratingMutationTailRevisions: [String: UInt64] = [:]

    private(set) var activeAccountID = SongLikeStatusManager.primaryAccountID

    private(set) var lastLikeEvent: LikeStatusEvent?
    private(set) var lastLikeEventBatch: LikeStatusEventBatch?

    private var client: (any YTMusicClientProtocol)?

    init() {}

    func setClient(_ client: (any YTMusicClientProtocol)?) {
        self.client = client
    }

    var currentClient: (any YTMusicClientProtocol)? {
        self.client
    }

    func setActiveAccountID(_ accountID: String?) {
        let resolvedAccountID = Self.resolvedAccountID(accountID)
        guard self.activeAccountID != resolvedAccountID else { return }

        self.invalidateSession(clearsActiveCache: false, publishesRollbackEvents: false)
        self.activeAccountID = resolvedAccountID
        self.lastLikeEvent = nil
        self.lastLikeEventBatch = nil
        DiagnosticsLogger.api.debug("SongLikeStatusManager: Switched cache scope to account \(resolvedAccountID)")
    }

    func status(for videoId: String) -> LikeStatus? {
        self.status(for: videoId, accountID: self.activeAccountID)
    }

    func status(for song: Song) -> LikeStatus? {
        self.status(for: song.videoId) ?? song.likeStatus
    }

    func isLiked(_ song: Song) -> Bool {
        self.status(for: song) == .like
    }

    func isDisliked(_ song: Song) -> Bool {
        self.status(for: song) == .dislike
    }

    func beginLikedMusicRequest() -> LikedMusicRequestSnapshot {
        let accountID = self.activeAccountID
        self.likedMusicRequestCounter &+= 1
        let requestID = self.likedMusicRequestCounter
        self.activeLikedMusicRequestIDsByAccount[accountID, default: []].insert(requestID)
        if var overlays = self.localRatingOverlayByAccount[accountID] {
            for (videoId, var overlay) in overlays
                where self.pendingRatingByAccount[accountID]?[videoId] != nil
                || !overlay.protectedRequestIDs.isEmpty
            {
                overlay.protectedRequestIDs.insert(requestID)
                overlays[videoId] = overlay
            }
            self.localRatingOverlayByAccount[accountID] = overlays
        }
        return LikedMusicRequestSnapshot(
            accountID: accountID,
            scopeGeneration: self.requestScopeGeneration,
            requestID: requestID
        )
    }

    func finishLikedMusicRequest(_ snapshot: LikedMusicRequestSnapshot) {
        self.activeLikedMusicRequestIDsByAccount[snapshot.accountID]?.remove(snapshot.requestID)
        if self.activeLikedMusicRequestIDsByAccount[snapshot.accountID]?.isEmpty == true {
            self.activeLikedMusicRequestIDsByAccount.removeValue(forKey: snapshot.accountID)
        }
        guard var overlays = self.localRatingOverlayByAccount[snapshot.accountID] else { return }
        for (videoId, var overlay) in overlays {
            overlay.protectedRequestIDs.remove(snapshot.requestID)
            if overlay.protectedRequestIDs.isEmpty,
               self.pendingRatingByAccount[snapshot.accountID]?[videoId] == nil
            {
                overlays.removeValue(forKey: videoId)
            } else {
                overlays[videoId] = overlay
            }
        }
        self.localRatingOverlayByAccount[snapshot.accountID] = overlays.isEmpty ? nil : overlays
    }

    func matchesCurrentScope(_ snapshot: LikedMusicRequestSnapshot) -> Bool {
        self.activeAccountID == snapshot.accountID
            && self.requestScopeGeneration == snapshot.scopeGeneration
    }

    func reconcileLikedMusicTracks(
        _ tracks: [Song],
        snapshot: LikedMusicRequestSnapshot,
        deduplicating: Bool = false
    ) -> LikedMusicReconciliation? {
        guard self.matchesCurrentScope(snapshot) else { return nil }

        var acceptedTracks: [Song] = []
        var filteredVideoIDs: Set<String> = []
        var insertedVideoIDs: Set<String> = []
        var localOverlayVideoIDs: Set<String> = []
        var newLikedMembershipVideoIDs: Set<String> = []
        var seenVideoIDs: Set<String> = []
        var cache = self.statusCacheByAccount[snapshot.accountID] ?? [:]
        let overlays = self.localRatingOverlayByAccount[snapshot.accountID] ?? [:]
        var didMutateCache = false

        for var song in tracks {
            if deduplicating, !seenVideoIDs.insert(song.videoId).inserted {
                continue
            }
            if let overlay = overlays[song.videoId],
               overlay.protectedRequestIDs.contains(snapshot.requestID)
            {
                localOverlayVideoIDs.insert(song.videoId)
                guard overlay.status == .like else {
                    filteredVideoIDs.insert(song.videoId)
                    continue
                }
                if overlay.addsLikedMusicMembership {
                    newLikedMembershipVideoIDs.insert(song.videoId)
                }
            } else {
                cache[song.videoId] = .like
                self.setConfirmedStatus(.like, for: song.videoId, accountID: snapshot.accountID)
                didMutateCache = true
            }
            song.likeStatus = .like
            acceptedTracks.append(song)
        }

        var acceptedVideoIDs = Set(acceptedTracks.map(\.videoId))
        let missingLikedOverlays = overlays.filter { videoId, overlay in
            overlay.protectedRequestIDs.contains(snapshot.requestID)
                && overlay.status == .like
                && !acceptedVideoIDs.contains(videoId)
        }.sorted { lhs, rhs in
            lhs.value.revision < rhs.value.revision
        }
        for (videoId, overlay) in missingLikedOverlays {
            var song = overlay.song
            song.likeStatus = .like
            acceptedTracks.insert(song, at: 0)
            acceptedVideoIDs.insert(videoId)
            insertedVideoIDs.insert(videoId)
            localOverlayVideoIDs.insert(videoId)
            if overlay.addsLikedMusicMembership {
                newLikedMembershipVideoIDs.insert(videoId)
            }
        }

        if didMutateCache {
            self.statusCacheByAccount[snapshot.accountID] = cache
        }
        return LikedMusicReconciliation(
            tracks: acceptedTracks,
            filteredVideoIDs: filteredVideoIDs,
            insertedVideoIDs: insertedVideoIDs,
            localOverlayVideoIDs: localOverlayVideoIDs,
            newLikedMembershipVideoIDs: newLikedMembershipVideoIDs
        )
    }

    @discardableResult
    func like(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil
    ) async -> LikeStatus {
        await self.enqueueRating(song, status: .like, accountID: accountID, client: client).value
    }

    @discardableResult
    func unlike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil
    ) async -> LikeStatus {
        await self.enqueueRating(song, status: .indifferent, accountID: accountID, client: client).value
    }

    @discardableResult
    func dislike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil
    ) async -> LikeStatus {
        await self.enqueueRating(song, status: .dislike, accountID: accountID, client: client).value
    }

    @discardableResult
    func undislike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil
    ) async -> LikeStatus {
        await self.enqueueRating(song, status: .indifferent, accountID: accountID, client: client).value
    }

    func enqueueRating(
        _ song: Song,
        status: LikeStatus,
        accountID: String? = nil,
        client overrideClient: (any YTMusicClientProtocol)? = nil,
        visibleBaseline: LikeStatus? = nil
    ) -> Task<LikeStatus, Never> {
        let resolvedAccountID = accountID.map(Self.resolvedAccountID) ?? self.activeAccountID
        let key = Self.ratingMutationKey(
            accountID: resolvedAccountID,
            videoId: song.videoId
        )
        if let visibleBaseline {
            if self.ratingMutationTails[key] == nil,
               self.confirmedStatusByAccount[resolvedAccountID]?[song.videoId] == nil
            {
                self.setConfirmedStatus(
                    visibleBaseline,
                    for: song.videoId,
                    accountID: resolvedAccountID
                )
            }
            self.setStatus(visibleBaseline, for: song.videoId, accountID: resolvedAccountID)
        }

        guard let client = overrideClient ?? self.client else {
            DiagnosticsLogger.api.warning("SongLikeStatusManager: No client set, cannot rate song")
            let fallback = self.status(for: song.videoId, accountID: resolvedAccountID)
                ?? song.likeStatus
                ?? .indifferent
            return Task { @MainActor in fallback }
        }

        let sessionGeneration = self.sessionGeneration
        let revision = self.beginRatingOperation(
            videoId: song.videoId,
            accountID: resolvedAccountID
        )
        let previousStatus = self.status(for: song.videoId, accountID: resolvedAccountID)
        if self.confirmedStatusByAccount[resolvedAccountID]?[song.videoId] == nil {
            self.setConfirmedStatus(previousStatus, for: song.videoId, accountID: resolvedAccountID)
        }
        let addsLikedMusicMembership = status == .like
            && self.confirmedStatus(for: song.videoId, accountID: resolvedAccountID) != .like
        self.setStatus(status, for: song.videoId, accountID: resolvedAccountID)
        self.publishEvent(
            LikeStatusEvent(
                videoId: song.videoId,
                status: status,
                song: song,
                addsLikedMusicMembership: addsLikedMusicMembership
            ),
            for: resolvedAccountID
        )
        self.pendingRatingByAccount[resolvedAccountID, default: [:]][song.videoId] = PendingRating(
            revision: revision,
            status: status,
            song: song
        )
        self.localRatingOverlayByAccount[resolvedAccountID, default: [:]][song.videoId] = LocalRatingOverlay(
            revision: revision,
            status: status,
            song: song,
            addsLikedMusicMembership: addsLikedMusicMembership,
            protectedRequestIDs: self.activeLikedMusicRequestIDsByAccount[resolvedAccountID] ?? []
        )

        let mutation = RatingMutationRequest(
            videoId: song.videoId,
            status: status,
            accountID: resolvedAccountID,
            revision: revision,
            sessionGeneration: sessionGeneration
        )
        let request = self.enqueueSerializedRatingMutation(
            client: client,
            mutation: mutation
        )
        return Task { @MainActor in
            await self.settleRatingMutation(
                song: song,
                status: status,
                mutation: mutation,
                request: request
            )
        }
    }

    private func settleRatingMutation(
        song: Song,
        status: LikeStatus,
        mutation: RatingMutationRequest,
        request: Task<Result<Void, any Error>, Never>
    ) async -> LikeStatus {
        defer {
            self.finishRatingMutation(
                accountID: mutation.accountID,
                videoId: mutation.videoId,
                revision: mutation.revision
            )
        }
        do {
            try await request.value.get()
            guard self.sessionGeneration == mutation.sessionGeneration else {
                return self.status(for: song.videoId, accountID: mutation.accountID) ?? status
            }
            guard self.isCurrentRatingOperation(
                mutation.revision,
                videoId: song.videoId,
                accountID: mutation.accountID
            ) else {
                return self.status(for: song.videoId, accountID: mutation.accountID) ?? status
            }
            DiagnosticsLogger.api.info("Rated song \(song.videoId) as \(status.rawValue)")
            return status
        } catch is CancellationError {
            return self.rollbackRatingMutation(
                song: song,
                status: status,
                mutation: mutation,
                logsCancellation: true
            )
        } catch {
            DiagnosticsLogger.api.error("Failed to rate song: \(error.localizedDescription)")
            return self.rollbackRatingMutation(
                song: song,
                status: status,
                mutation: mutation,
                logsCancellation: false
            )
        }
    }

    private func rollbackRatingMutation(
        song: Song,
        status _: LikeStatus,
        mutation: RatingMutationRequest,
        logsCancellation: Bool
    ) -> LikeStatus {
        guard self.isCurrentRatingOperation(
            mutation.revision,
            videoId: song.videoId,
            accountID: mutation.accountID
        ) else {
            return self.status(for: song.videoId, accountID: mutation.accountID) ?? .indifferent
        }
        let confirmedStatus = self.confirmedStatus(
            for: song.videoId,
            accountID: mutation.accountID
        )
        let rollbackStatus = confirmedStatus ?? .indifferent
        if let overlay = self.localRatingOverlayByAccount[mutation.accountID]?[song.videoId],
           overlay.revision == mutation.revision
        {
            if overlay.protectedRequestIDs.isEmpty {
                self.localRatingOverlayByAccount[mutation.accountID]?.removeValue(forKey: song.videoId)
                if self.localRatingOverlayByAccount[mutation.accountID]?.isEmpty == true {
                    self.localRatingOverlayByAccount.removeValue(forKey: mutation.accountID)
                }
            } else {
                self.localRatingOverlayByAccount[mutation.accountID]?[song.videoId] = LocalRatingOverlay(
                    revision: mutation.revision,
                    status: rollbackStatus,
                    song: song,
                    addsLikedMusicMembership: false,
                    protectedRequestIDs: overlay.protectedRequestIDs
                )
            }
        }
        let sessionIsCurrent = self.sessionGeneration == mutation.sessionGeneration
        let shouldRestoreOldAccount = sessionIsCurrent || self.activeAccountID != mutation.accountID
        if shouldRestoreOldAccount {
            self.restoreStatus(confirmedStatus, for: song.videoId, accountID: mutation.accountID)
        }
        if sessionIsCurrent {
            self.publishEvent(
                LikeStatusEvent(
                    videoId: song.videoId,
                    status: rollbackStatus,
                    song: song,
                    addsLikedMusicMembership: false
                ),
                for: mutation.accountID
            )
        }
        if logsCancellation {
            DiagnosticsLogger.api.debug("Rating cancelled for song \(song.videoId)")
        }
        return shouldRestoreOldAccount
            ? rollbackStatus
            : (self.status(for: song.videoId, accountID: mutation.accountID) ?? .indifferent)
    }

    @discardableResult
    func setStatus(_ status: LikeStatus, for videoId: String) -> Bool {
        let accountID = self.activeAccountID
        guard !self.shouldPreserveLocalRating(for: videoId, accountID: accountID) else { return false }
        self.setStatus(status, for: videoId, accountID: accountID)
        self.setConfirmedStatus(status, for: videoId, accountID: accountID)
        self.localRatingOverlayByAccount[accountID]?.removeValue(forKey: videoId)
        return true
    }

    func setCachedStatus(_ status: LikeStatus, for videoId: String) {
        self.setStatus(status, for: videoId, accountID: self.activeAccountID)
    }

    func setStatus(_ status: LikeStatus, for videoIds: some Sequence<String>, accountID: String? = nil) {
        let resolvedAccountID = accountID.map(Self.resolvedAccountID) ?? self.activeAccountID
        var cache = self.statusCacheByAccount[resolvedAccountID] ?? [:]

        for videoId in videoIds where !self.shouldPreserveLocalRating(
            for: videoId,
            accountID: resolvedAccountID
        ) {
            cache[videoId] = status
            self.setConfirmedStatus(status, for: videoId, accountID: resolvedAccountID)
        }

        self.statusCacheByAccount[resolvedAccountID] = cache
    }

    func clearCache() {
        self.requestScopeGeneration &+= 1
        self.sessionGeneration &+= 1
        for task in self.ratingMutationTails.values {
            task.cancel()
        }
        self.pendingRatingByAccount.removeAll()
        self.localRatingOverlayByAccount.removeAll()
        self.activeLikedMusicRequestIDsByAccount.removeAll()
        self.statusCacheByAccount.removeAll()
        self.ratingRevisionByAccount.removeAll()
        self.confirmedStatusByAccount.removeAll()
        self.lastLikeEvent = nil
        self.lastLikeEventBatch = nil
    }

    func invalidateSession(
        clearsActiveCache: Bool = true,
        publishesRollbackEvents: Bool = true
    ) {
        let accountID = self.activeAccountID
        let rollbackEvents = clearsActiveCache
            ? []
            : self.restorePendingRatings(for: accountID)
        self.requestScopeGeneration &+= 1
        self.sessionGeneration &+= 1
        for task in self.ratingMutationTails.values {
            task.cancel()
        }
        self.pendingRatingByAccount.removeAll()
        self.activeLikedMusicRequestIDsByAccount.removeAll()
        self.localRatingOverlayByAccount.removeAll()
        if clearsActiveCache {
            self.statusCacheByAccount.removeValue(forKey: accountID)
            self.confirmedStatusByAccount.removeValue(forKey: accountID)
            self.ratingRevisionByAccount.removeValue(forKey: accountID)
            self.lastLikeEvent = nil
            self.lastLikeEventBatch = nil
        } else if publishesRollbackEvents {
            self.publishEvents(rollbackEvents, for: accountID)
        }
    }

    func hasPendingRating(for videoId: String, accountID: String? = nil) -> Bool {
        let resolvedAccountID = accountID.map(Self.resolvedAccountID) ?? self.activeAccountID
        return self.pendingRatingByAccount[resolvedAccountID]?[videoId] != nil
    }

    private func restorePendingRatings(for accountID: String) -> [LikeStatusEvent] {
        (self.pendingRatingByAccount[accountID] ?? [:])
            .sorted { lhs, rhs in lhs.value.revision < rhs.value.revision }
            .map { videoId, pendingRating in
                let confirmedStatus = self.confirmedStatus(for: videoId, accountID: accountID)
                self.restoreStatus(confirmedStatus, for: videoId, accountID: accountID)
                self.localRatingOverlayByAccount[accountID]?.removeValue(forKey: videoId)
                return LikeStatusEvent(
                    videoId: videoId,
                    status: confirmedStatus ?? .indifferent,
                    song: pendingRating.song,
                    addsLikedMusicMembership: false
                )
            }
    }

    private func shouldPreserveLocalRating(for videoId: String, accountID: String) -> Bool {
        self.pendingRatingByAccount[accountID]?[videoId] != nil
            || self.localRatingOverlayByAccount[accountID]?[videoId]?.protectedRequestIDs.isEmpty == false
    }

    func ratingRevision(for videoId: String, accountID: String? = nil) -> UInt64 {
        let resolvedAccountID = accountID.map(Self.resolvedAccountID) ?? self.activeAccountID
        return self.ratingRevisionByAccount[resolvedAccountID]?[videoId] ?? 0
    }

    private func beginRatingOperation(videoId: String, accountID: String) -> UInt64 {
        self.ratingRevisionCounter &+= 1
        self.ratingRevisionByAccount[accountID, default: [:]][videoId] = self.ratingRevisionCounter
        return self.ratingRevisionCounter
    }

    private func isCurrentRatingOperation(
        _ revision: UInt64,
        videoId: String,
        accountID: String
    ) -> Bool {
        self.ratingRevisionByAccount[accountID]?[videoId] == revision
    }

    private func enqueueSerializedRatingMutation(
        client: any YTMusicClientProtocol,
        mutation: RatingMutationRequest
    ) -> Task<Result<Void, any Error>, Never> {
        let key = Self.ratingMutationKey(
            accountID: mutation.accountID,
            videoId: mutation.videoId
        )
        let predecessor = self.ratingMutationTails[key]
        let requestTask = Task { @MainActor () -> Result<Void, any Error> in
            if let predecessor {
                _ = await predecessor.value
            }
            guard self.sessionGeneration == mutation.sessionGeneration,
                  self.activeAccountID == mutation.accountID
            else {
                return .failure(CancellationError())
            }
            do {
                try await client.rateSong(videoId: mutation.videoId, rating: mutation.status)
                guard self.sessionGeneration == mutation.sessionGeneration else {
                    return .failure(CancellationError())
                }
                self.setConfirmedStatus(
                    mutation.status,
                    for: mutation.videoId,
                    accountID: mutation.accountID
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        self.ratingMutationTails[key] = requestTask
        self.ratingMutationTailRevisions[key] = mutation.revision
        return requestTask
    }

    private func finishRatingMutation(
        accountID: String,
        videoId: String,
        revision: UInt64
    ) {
        let key = Self.ratingMutationKey(accountID: accountID, videoId: videoId)
        guard self.ratingMutationTailRevisions[key] == revision else { return }
        self.ratingMutationTails.removeValue(forKey: key)
        self.ratingMutationTailRevisions.removeValue(forKey: key)
        if self.pendingRatingByAccount[accountID]?[videoId]?.revision == revision {
            self.pendingRatingByAccount[accountID]?.removeValue(forKey: videoId)
            if self.pendingRatingByAccount[accountID]?.isEmpty == true {
                self.pendingRatingByAccount.removeValue(forKey: accountID)
            }
        }
        if self.localRatingOverlayByAccount[accountID]?[videoId]?.revision == revision,
           self.localRatingOverlayByAccount[accountID]?[videoId]?.protectedRequestIDs.isEmpty == true
        {
            self.localRatingOverlayByAccount[accountID]?.removeValue(forKey: videoId)
            if self.localRatingOverlayByAccount[accountID]?.isEmpty == true {
                self.localRatingOverlayByAccount.removeValue(forKey: accountID)
            }
        }
    }

    private static func ratingMutationKey(accountID: String, videoId: String) -> String {
        accountID + "\u{0}" + videoId
    }

    private static func resolvedAccountID(_ accountID: String?) -> String {
        accountID ?? self.primaryAccountID
    }

    func status(for videoId: String, accountID: String?) -> LikeStatus? {
        self.statusCacheByAccount[Self.resolvedAccountID(accountID)]?[videoId]
    }

    private func setStatus(_ status: LikeStatus, for videoId: String, accountID: String) {
        self.statusCacheByAccount[accountID, default: [:]][videoId] = status
    }

    private func confirmedStatus(for videoId: String, accountID: String) -> LikeStatus? {
        self.confirmedStatusByAccount[accountID]?[videoId]?.value
    }

    private func setConfirmedStatus(
        _ status: LikeStatus?,
        for videoId: String,
        accountID: String
    ) {
        self.confirmedStatusByAccount[accountID, default: [:]][videoId] = ConfirmedRatingStatus(value: status)
    }

    private func restoreStatus(_ status: LikeStatus?, for videoId: String, accountID: String) {
        if let status {
            self.setStatus(status, for: videoId, accountID: accountID)
        } else {
            self.removeStatus(for: videoId, accountID: accountID)
        }
    }

    private func removeStatus(for videoId: String, accountID: String) {
        guard self.statusCacheByAccount[accountID] != nil else { return }

        self.statusCacheByAccount[accountID]?.removeValue(forKey: videoId)
        if self.statusCacheByAccount[accountID]?.isEmpty == true {
            self.statusCacheByAccount.removeValue(forKey: accountID)
        }
    }

    private func publishEvent(_ event: LikeStatusEvent, for accountID: String) {
        self.publishEvents([event], for: accountID)
    }

    private func publishEvents(_ events: [LikeStatusEvent], for accountID: String) {
        guard accountID == self.activeAccountID, let lastEvent = events.last else { return }
        self.lastLikeEvent = lastEvent
        self.lastLikeEventBatch = LikeStatusEventBatch(accountID: accountID, events: events)
    }
}
