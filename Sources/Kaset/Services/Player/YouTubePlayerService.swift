// swiftlint:disable file_length
import AppKit
import Foundation
import Observation

struct YouTubePlaybackOccurrence: Hashable {
    let documentGeneration: UInt64
    let mediaGeneration: UInt64
}

@MainActor
protocol YouTubeWatchPlaybackControlling: AnyObject {
    func prepare(webKitManager: WebKitManager, playerService: YouTubePlayerService, usesCookieFreeDataStore: Bool)
    func loadVideo(videoId: String)
    func reloadVideo(videoId: String, resumeAt seconds: Double?)
    @discardableResult
    func cancelPendingLoad() -> Bool
    func playPause()
    func play()
    func pause()
    func seek(to time: Double)
    func seekWithRecovery(to seconds: Double)
    func cancelPendingRecoverySeek()
    func markCurrentPlaybackOccurrenceEnded()
    func setVolume(_ volume: Double)
    func setPlaybackRate(_ rate: Double)
    func showAirPlayPicker(at screenPoint: CGPoint?)
    func availableCaptionTracks() async -> [YouTubeCaptionTrack]
    func currentCaptionLanguageCode() async -> String?
    func setCaptionTrack(languageCode: String?)
    func availableQualityLevels() async -> [String]
    func currentQualityLevel() async -> String?
    func setQualityLevel(_ level: String)
    func storyboardSpec(expectedVideoId: String?) async -> String?
    func tearDown()
}

extension YouTubeWatchWebView: YouTubeWatchPlaybackControlling {
    func prepare(webKitManager: WebKitManager, playerService: YouTubePlayerService, usesCookieFreeDataStore: Bool) {
        _ = self.getWebView(
            webKitManager: webKitManager,
            playerService: playerService,
            usesCookieFreeDataStore: usesCookieFreeDataStore
        )
    }
}

@MainActor
@Observable
final class YouTubePlayerService {
    private(set) var currentVideo: YouTubeVideo?

    private(set) var watchActivityGeneration = 0

    private(set) var watchConclusionGeneration = 0

    private var currentWatchConcluded = false

    @ObservationIgnored private(set) var currentPlaybackOccurrence: YouTubePlaybackOccurrence?
    @ObservationIgnored private var lastEndedPlaybackOccurrence: YouTubePlaybackOccurrence?
    @ObservationIgnored private var lastResumeIssuedAtMilliseconds: Double?
    @ObservationIgnored private var isAutoplayTransitionPending = false
    @ObservationIgnored private var shouldRecoverAutoplayTransitionOnResume = false
    @ObservationIgnored private var autoplayRecoveryRequestGeneration: UInt64 = 0

    private(set) var isPlaying = false

    @ObservationIgnored private var hasObservedPausedMedia = false

    private enum DesiredPlaybackIntent: Equatable {
        case playing
        case paused
    }

    @ObservationIgnored private var desiredPlaybackIntent: DesiredPlaybackIntent = .paused

    @ObservationIgnored var youtubePlaybackIntentIssuedAtMilliseconds: Double = 0
    @ObservationIgnored var youtubeRemoteCommandIntentIssuedAtMilliseconds: Double?
    @ObservationIgnored var youtubePlaybackIntentGeneration: UInt64 = 0

    @ObservationIgnored private var isExplicitPauseIntentActive = false
    @ObservationIgnored private var isAwaitingResumeConfirmation = false

    private struct ExplicitStartTarget {
        let videoId: String
        let seconds: Double
    }

    private struct PendingUserSeekTarget {
        let videoId: String
        let seconds: Double
    }

    @ObservationIgnored private var pendingExplicitStartTarget: ExplicitStartTarget?

    @ObservationIgnored private var pendingUserSeekTarget: PendingUserSeekTarget?

    var pendingPausedIdentityReloadVideoId: String?
    var pendingPausedIdentityReloadResumeAt: Double?
    var userUpdatedPendingPausedIdentityReloadSeek = false
    private var isIdentityReloadInFlight = false
    private var pausedIdentityReloadAwaitingFirstUpdate = false

    var progress: Double = 0

    var lastNonAdContentProgress: Double = 0
    private var lastNonAdContentVideoId: String?

    private(set) var duration: Double = 0

    @ObservationIgnored var lastRelativeSeekTarget: Double?
    @ObservationIgnored var lastRelativeSeekIssuedAt: ContinuousClock.Instant?
    @ObservationIgnored var lastRelativeSeekVideoId: String?

    private(set) var isShowingAd = false

    private(set) var isPlaybackLoading = false

    @ObservationIgnored var currentMediaIsLive = false

    @ObservationIgnored private var playbackLoadingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var playbackLoadingGeneration: UInt64 = 0

    var volume: Double = 1.0 {
        didSet {
            guard oldValue != self.volume else { return }
            self.playbackController.setVolume(self.volume)
        }
    }

    var playbackRate: Double = 1.0 {
        didSet {
            guard oldValue != self.playbackRate else { return }
            self.playbackController.setPlaybackRate(self.playbackRate)
        }
    }

    enum SurfaceLocation: Equatable {
        case none
        case inline
        case floating
    }

    private(set) var surfaceLocation: SurfaceLocation = .none

    var activeInlineVideoId: String?

    private(set) var currentRating: YouTubeRating = .none

    private(set) var popInRequest: YouTubeVideo?

    private(set) var upNext: [YouTubeVideo] = []

    private(set) var chapters: [YouTubeChapter] = []

    private var history: [YouTubeVideo] = []

    private(set) var skipNavigationRequest: YouTubeVideo?

    private(set) var isInWatchLater = false

    var windowFullscreenPhase: YouTubeVideoWindowFullscreenPhase = .windowed

    var isWindowFullscreen: Bool {
        self.windowFullscreenPhase.blocksWindowedControls
    }

    private(set) var captionTracks: [YouTubeCaptionTrack] = []

    private(set) var activeCaptionLanguageCode: String?

    private(set) var qualityLevels: [String] = []

    private(set) var currentQuality: String?

    private(set) var userPinnedQuality: String?

    private(set) var storyboardSpec: String?

    private var storyboardFetchVideoId: String?

    private var storyboardFetchInFlightVideoId: String?

    private var playbackOptionsVideoId: String?

    @ObservationIgnored var youtubeClient: (any YouTubeClientProtocol)?

    var playbackWillStart: (() -> Void)?

    var onVideoEnded: ((String?) -> Void)?

    private let webKitManager: WebKitManager
    let playbackController: any YouTubeWatchPlaybackControlling
    private var usesCookieFreePlaybackDataStore = false
    private let playbackLoadingTimeout: Duration
    private let logger = DiagnosticsLogger.player

    private let shouldPopOutOnNavigateAway: @MainActor () -> Bool

    init(
        webKitManager: WebKitManager = .shared,
        playbackController: (any YouTubeWatchPlaybackControlling)? = nil,
        shouldPopOutOnNavigateAway: @escaping @MainActor () -> Bool = { SettingsManager.shared.popOutVideoOnNavigateAway },
        playbackLoadingTimeout: Duration = .seconds(15)
    ) {
        self.webKitManager = webKitManager
        self.playbackController = playbackController ?? YouTubeWatchWebView.shared
        self.shouldPopOutOnNavigateAway = shouldPopOutOnNavigateAway
        self.playbackLoadingTimeout = playbackLoadingTimeout
    }

    func play(video: YouTubeVideo, usesCookieFreeDataStore: Bool = false, startAt: Double? = nil) {
        self.beginYouTubePlaybackIntent()
        self.autoplayRecoveryRequestGeneration &+= 1
        self.shouldRecoverAutoplayTransitionOnResume = false
        let normalizedStartAt = Self.normalizedExplicitStartAt(startAt)
        self.logger.info("YouTubePlayer: play video")
        self.usesCookieFreePlaybackDataStore = usesCookieFreeDataStore
        self.playbackWillStart?()

        if let current = self.currentVideo, current.videoId != video.videoId {
            self.rememberInHistory(current)
        }
        self.upNext = []
        self.currentVideo = video
        self.resetPlaybackOccurrenceState()
        self.desiredPlaybackIntent = .playing
        self.isExplicitPauseIntentActive = false
        self.isAwaitingResumeConfirmation = false
        self.watchActivityGeneration += 1
        self.currentWatchConcluded = false
        self.isIdentityReloadInFlight = false
        self.resetPerVideoState()
        if let normalizedStartAt {
            self.pendingExplicitStartTarget = ExplicitStartTarget(
                videoId: video.videoId,
                seconds: normalizedStartAt
            )
        }
        self.beginPlaybackLoading()
        self.surfaceLocation = .inline

        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        if let normalizedStartAt {
            self.playbackController.reloadVideo(videoId: video.videoId, resumeAt: normalizedStartAt)
        } else {
            self.playbackController.loadVideo(videoId: video.videoId)
        }
    }

    nonisolated static func normalizedExplicitStartAt(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    func reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: Bool) {
        self.usesCookieFreePlaybackDataStore = usesCookieFreeDataStore
        guard self.currentVideo != nil else { return }
        self.reloadCurrentVideoForIdentitySwitch()
    }

    func reloadCurrentVideoForIdentitySwitch() {
        self.beginYouTubePlaybackIntent()
        guard let currentVideo = self.currentVideo else {
            self.logger.debug("Identity switch: no current video to re-point")
            return
        }
        let resumeAt = self.interruptionResumeAt(for: currentVideo.videoId)
        let intendsToPlay = self.desiredPlaybackIntent == .playing
        self.logger.info("Identity switch: re-pointing current video under new session identity (resume at \(resumeAt ?? 0)s, intendsToPlay=\(intendsToPlay))")

        if !intendsToPlay {
            self.pendingPausedIdentityReloadVideoId = currentVideo.videoId
            self.pendingPausedIdentityReloadResumeAt = resumeAt
            self.userUpdatedPendingPausedIdentityReloadSeek = false
            return
        }

        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        self.playbackController.reloadVideo(
            videoId: currentVideo.videoId,
            resumeAt: resumeAt
        )
        self.isIdentityReloadInFlight = true
        self.beginPlaybackLoading()
    }

    private func interruptionResumeAt(for videoId: String) -> Double? {
        if let pendingUserSeekTarget = self.pendingUserSeekTarget,
           pendingUserSeekTarget.videoId == videoId
        {
            return pendingUserSeekTarget.seconds
        }
        guard !self.currentWatchConcluded else { return nil }
        if let explicitStartTarget = self.explicitStartTarget(for: videoId) {
            return explicitStartTarget
        }
        guard self.lastNonAdContentVideoId == videoId,
              self.lastNonAdContentProgress > 0
        else { return nil }
        return self.lastNonAdContentProgress
    }

    private func explicitStartTarget(for videoId: String) -> Double? {
        guard self.pendingExplicitStartTarget?.videoId == videoId else { return nil }
        return self.pendingExplicitStartTarget?.seconds
    }

    func invalidateExplicitStartTargetForUserSeek() {
        self.pendingExplicitStartTarget = nil
    }

    func recordPendingUserSeek(to seconds: Double) {
        guard let videoId = self.currentVideo?.videoId else { return }
        if self.currentWatchConcluded
            || self.isAutoplayTransitionPending
            || self.shouldRecoverAutoplayTransitionOnResume
        {
            self.autoplayRecoveryRequestGeneration &+= 1
            self.isAutoplayTransitionPending = false
            self.shouldRecoverAutoplayTransitionOnResume = false
        }
        self.pendingUserSeekTarget = PendingUserSeekTarget(
            videoId: videoId,
            seconds: seconds
        )
    }

    func clearPendingUserSeek() {
        self.pendingUserSeekTarget = nil
    }

    func handlePendingSeekExhausted(videoId: String, target: Double) {
        if let explicitStartTarget = self.pendingExplicitStartTarget,
           explicitStartTarget.videoId == videoId,
           abs(explicitStartTarget.seconds - target) < 0.001
        {
            self.pendingExplicitStartTarget = nil
        }
        if let pendingUserSeekTarget = self.pendingUserSeekTarget,
           pendingUserSeekTarget.videoId == videoId,
           abs(pendingUserSeekTarget.seconds - target) < 0.001
        {
            self.pendingUserSeekTarget = nil
        }
        if self.pendingPausedIdentityReloadVideoId == videoId,
           let pendingResumeAt = self.pendingPausedIdentityReloadResumeAt,
           abs(pendingResumeAt - target) < 0.001
        {
            self.pendingPausedIdentityReloadResumeAt = self.interruptionResumeAt(for: videoId)
            self.userUpdatedPendingPausedIdentityReloadSeek = false
        }
    }

    func recoverAfterWebContentProcessTermination(resumeAtOverride: Double? = nil) {
        guard let currentVideo = self.currentVideo else { return }

        let hasPendingUserSeek = self.pendingUserSeekTarget?.videoId == currentVideo.videoId
        if self.isAutoplayTransitionPending, !hasPendingUserSeek {
            self.isAutoplayTransitionPending = false
            self.shouldRecoverAutoplayTransitionOnResume = true
            self.desiredPlaybackIntent = .paused
            self.isAwaitingResumeConfirmation = false
            self.autoplayRecoveryRequestGeneration &+= 1
            self.isPlaying = false
            self.isIdentityReloadInFlight = false
            self.finishPlaybackLoading()
            self.hasObservedPausedMedia = true
            return
        }

        let resumeAt = resumeAtOverride ?? self.interruptionResumeAt(for: currentVideo.videoId)

        if self.desiredPlaybackIntent == .paused {
            self.pendingPausedIdentityReloadVideoId = currentVideo.videoId
            self.pendingPausedIdentityReloadResumeAt = resumeAt
            self.userUpdatedPendingPausedIdentityReloadSeek = false
            self.isIdentityReloadInFlight = false
            self.isPlaying = false
            self.finishPlaybackLoading()
            return
        }

        self.playbackController.reloadVideo(videoId: currentVideo.videoId, resumeAt: resumeAt)
        self.isPlaying = false
        self.isIdentityReloadInFlight = true
        self.beginPlaybackLoading()
    }

    func handleWebNavigationFailure(resumeAtOverride: Double? = nil) {
        self.deferCurrentVideoReload(resumeAtOverride: resumeAtOverride)
    }

    func handleWebNavigationCancellation(resumeAtOverride: Double? = nil) {
        self.deferCurrentVideoReload(resumeAtOverride: resumeAtOverride)
    }

    private func deferCurrentVideoReload(resumeAtOverride: Double? = nil) {
        guard let currentVideo = self.currentVideo else { return }
        self.pendingPausedIdentityReloadVideoId = currentVideo.videoId
        self.pendingPausedIdentityReloadResumeAt = resumeAtOverride
            ?? self.interruptionResumeAt(for: currentVideo.videoId)
        self.userUpdatedPendingPausedIdentityReloadSeek = false
        self.isIdentityReloadInFlight = false
        self.desiredPlaybackIntent = .paused
        self.isExplicitPauseIntentActive = true
        self.isAwaitingResumeConfirmation = false
        self.hasObservedPausedMedia = true
        self.isPlaying = false
        self.finishPlaybackLoading()
    }

    func playPause() {
        self.beginYouTubePlaybackIntent()
        self.performPlayPause()
    }

    func performPlayPause(resumeIssuedAtMilliseconds: Double? = nil) {
        if self.isPlaying
            || self.isAwaitingResumeConfirmation
            || (self.desiredPlaybackIntent == .playing
                && !(self.hasObservedPausedMedia && !self.isPlaying))
        {
            self.performPause()
        } else {
            self.performResume(issuedAtMilliseconds: resumeIssuedAtMilliseconds)
        }
    }

    func resume() {
        self.beginYouTubePlaybackIntent()
        self.performResume()
    }

    func performResume(issuedAtMilliseconds: Double? = nil) {
        self.lastResumeIssuedAtMilliseconds = issuedAtMilliseconds
            ?? Date().timeIntervalSince1970 * 1000
        self.desiredPlaybackIntent = .playing
        self.isExplicitPauseIntentActive = false
        self.isAwaitingResumeConfirmation = true
        self.hasObservedPausedMedia = false
        if self.shouldRecoverAutoplayTransitionOnResume {
            if let nextVideo = self.upNext.first {
                self.advance(to: nextVideo)
            } else {
                self.autoplayRecoveryRequestGeneration &+= 1
                let recoveryGeneration = self.autoplayRecoveryRequestGeneration
                let expectedVideoId = self.currentVideo?.videoId
                Task { @MainActor in
                    await self.recoverAutoplayTransition(
                        expectedVideoId: expectedVideoId,
                        generation: recoveryGeneration
                    )
                }
            }
            return
        }
        self.autoplayRecoveryRequestGeneration &+= 1
        if self.reloadPendingPausedIdentitySwitchForUserResume() {
            return
        }
        self.playbackWillStart?()
        self.playbackController.play()
    }

    @discardableResult
    private func reloadPendingPausedIdentitySwitchForUserResume() -> Bool {
        guard let currentVideo = self.currentVideo,
              self.pendingPausedIdentityReloadVideoId == currentVideo.videoId
        else {
            return false
        }

        let resumeAt = self.pendingPausedIdentityReloadResumeAt
        self.pendingPausedIdentityReloadVideoId = nil
        self.pendingPausedIdentityReloadResumeAt = nil
        self.userUpdatedPendingPausedIdentityReloadSeek = false
        self.playbackWillStart?()
        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        self.playbackController.reloadVideo(videoId: currentVideo.videoId, resumeAt: resumeAt)
        self.desiredPlaybackIntent = .playing
        self.isExplicitPauseIntentActive = false
        self.isIdentityReloadInFlight = true
        self.beginPlaybackLoading()
        return true
    }

    func pause() {
        self.beginYouTubePlaybackIntent()
        self.performPause()
    }

    func performPause() {
        self.autoplayRecoveryRequestGeneration &+= 1
        self.activateExplicitPauseIntent()
        let didCancelPendingLoad = self.playbackController.cancelPendingLoad()
        if didCancelPendingLoad {
            self.activateExplicitPauseIntent()
        }
        self.playbackController.pause()
    }

    func activateExplicitPauseIntent() {
        self.desiredPlaybackIntent = .paused
        self.isExplicitPauseIntentActive = true
        self.isAwaitingResumeConfirmation = false
        self.hasObservedPausedMedia = true
        self.deferInFlightIdentityReloadIfNeeded()
    }

    private func deferInFlightIdentityReloadIfNeeded() {
        if self.isIdentityReloadInFlight, let currentVideo = self.currentVideo {
            self.pendingPausedIdentityReloadVideoId = currentVideo.videoId
            self.pendingPausedIdentityReloadResumeAt = self.interruptionResumeAt(for: currentVideo.videoId)
            self.userUpdatedPendingPausedIdentityReloadSeek = false
            self.pausedIdentityReloadAwaitingFirstUpdate = true
            self.isIdentityReloadInFlight = false
        }
        self.isPlaying = false
        self.finishPlaybackLoading()
    }

    func stop() {
        self.beginYouTubePlaybackIntent()
        self.autoplayRecoveryRequestGeneration &+= 1
        self.shouldRecoverAutoplayTransitionOnResume = false
        self.logger.info("YouTubePlayer: stop")
        if self.currentVideo != nil, self.progress > 0 {
            if self.signalWatchConclusion() {
                self.watchActivityGeneration += 1
            }
        }
        self.currentVideo = nil
        self.resetPlaybackOccurrenceState()
        self.desiredPlaybackIntent = .paused
        self.isExplicitPauseIntentActive = true
        self.isAwaitingResumeConfirmation = false
        self.isPlaying = false
        self.finishPlaybackLoading()
        self.isIdentityReloadInFlight = false
        self.progress = 0
        self.duration = 0
        self.isShowingAd = false
        self.resetPerVideoState()
        self.surfaceLocation = .none
        self.activeInlineVideoId = nil
        self.popInRequest = nil
        self.upNext = []
        self.history = []
        self.skipNavigationRequest = nil
        self.pauseInPlaceOnDisappear = false
        self.playbackController.tearDown()
    }

    func popOutToWindow() {
        guard self.currentVideo != nil else { return }
        self.logger.info("YouTubePlayer: pop out to floating window")
        self.surfaceLocation = .floating
    }

    func dockInline() {
        guard self.currentVideo != nil else { return }
        self.logger.info("YouTubePlayer: dock inline")
        self.surfaceLocation = .inline
    }

    func requestPopIn() {
        guard self.surfaceLocation == .floating, let video = self.currentVideo else { return }
        self.popInRequest = video
    }

    func consumePopInRequest() {
        self.popInRequest = nil
    }

    func setUpNext(_ videos: [YouTubeVideo]) {
        let currentId = self.currentVideo?.videoId
        self.upNext = videos.filter { $0.videoId != currentId && !$0.isShort }
    }

    func setChapters(_ chapters: [YouTubeChapter]) {
        guard let currentId = self.currentVideo?.videoId else {
            self.chapters = []
            return
        }
        self.chapters = chapters.filter { $0.videoId == nil || $0.videoId == currentId }
    }

    func skipForward() async {
        let playbackIntentGeneration = self.beginYouTubePlaybackIntent()
        await self.skipForward(ownedBy: playbackIntentGeneration)
    }

    func skipForward(ownedBy playbackIntentGeneration: UInt64) async {
        guard let current = self.currentVideo else { return }

        var target = self.upNext.first
        if target == nil, let client = self.youtubeClient {
            target = await (try? client.getWatchNext(videoId: current.videoId))?
                .related.first { !$0.isShort }
            guard self.youtubePlaybackIntentGeneration == playbackIntentGeneration,
                  self.currentVideo?.videoId == current.videoId
            else { return }
        }
        guard let next = target else { return }
        self.advance(to: next)
    }

    func skipBackward() {
        self.beginYouTubePlaybackIntent()
        self.skipBackwardWithoutBeginningIntent()
    }

    func skipBackwardWithoutBeginningIntent() {
        if let previous = self.history.popLast() {
            self.advance(to: previous, recordingHistory: false)
        } else {
            self.seek(to: 0)
        }
    }

    func consumeSkipNavigationRequest() {
        self.skipNavigationRequest = nil
    }

    private func advance(to video: YouTubeVideo, recordingHistory: Bool = true) {
        self.autoplayRecoveryRequestGeneration &+= 1
        self.shouldRecoverAutoplayTransitionOnResume = false
        self.logger.info("YouTubePlayer: advancing to another video")
        if recordingHistory, let current = self.currentVideo {
            self.rememberInHistory(current)
        }
        self.upNext.removeAll { $0.videoId == video.videoId }

        self.playbackWillStart?()
        self.currentVideo = video
        self.resetPlaybackOccurrenceState()
        self.desiredPlaybackIntent = .playing
        self.isExplicitPauseIntentActive = false
        self.signalWatchConclusion()
        self.watchActivityGeneration += 1
        self.currentWatchConcluded = false
        self.isIdentityReloadInFlight = false
        self.resetPerVideoState()
        self.beginPlaybackLoading()
        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        self.playbackController.loadVideo(videoId: video.videoId)

        if self.surfaceLocation == .inline {
            self.skipNavigationRequest = video
        }
    }

    private func recoverAutoplayTransition(
        expectedVideoId: String?,
        generation: UInt64
    ) async {
        guard let expectedVideoId,
              let client = self.youtubeClient
        else {
            self.finishFailedAutoplayRecovery(generation: generation)
            return
        }
        let nextVideo = await (try? client.getWatchNext(videoId: expectedVideoId))?
            .related.first { !$0.isShort }
        guard generation == self.autoplayRecoveryRequestGeneration,
              self.currentVideo?.videoId == expectedVideoId,
              self.desiredPlaybackIntent == .playing
        else { return }
        guard let nextVideo else {
            self.finishFailedAutoplayRecovery(generation: generation)
            return
        }
        self.advance(to: nextVideo)
    }

    private func finishFailedAutoplayRecovery(generation: UInt64) {
        guard generation == self.autoplayRecoveryRequestGeneration else { return }
        self.shouldRecoverAutoplayTransitionOnResume = true
        self.desiredPlaybackIntent = .paused
        self.isAwaitingResumeConfirmation = false
        self.hasObservedPausedMedia = true
    }

    private func rememberInHistory(_ video: YouTubeVideo) {
        self.history.append(video)
        if self.history.count > 50 {
            self.history.removeFirst()
        }
    }

    private func resetPerVideoState() {
        self.progress = 0
        self.duration = 0
        self.currentRating = .none
        self.isInWatchLater = false
        self.chapters = []
        self.captionTracks = []
        self.activeCaptionLanguageCode = nil
        self.qualityLevels = []
        self.currentQuality = nil
        self.userPinnedQuality = nil
        self.currentMediaIsLive = false
        self.storyboardSpec = nil
        self.storyboardFetchVideoId = nil
        self.storyboardFetchInFlightVideoId = nil
        self.playbackOptionsVideoId = nil
        self.pendingPausedIdentityReloadVideoId = nil
        self.pendingPausedIdentityReloadResumeAt = nil
        self.userUpdatedPendingPausedIdentityReloadSeek = false
        self.pausedIdentityReloadAwaitingFirstUpdate = false
        self.pendingExplicitStartTarget = nil
        self.pendingUserSeekTarget = nil
        self.isAutoplayTransitionPending = false
        self.shouldRecoverAutoplayTransitionOnResume = false
        self.lastNonAdContentProgress = 0
        self.lastNonAdContentVideoId = nil
        self.hasObservedPausedMedia = false
        self.isAwaitingResumeConfirmation = false
        self.clearRelativeSeekCoalescingTarget()
    }

    func toggleWatchLater() async {
        guard let video = self.currentVideo, let client = self.youtubeClient else { return }
        let wasInWatchLater = self.isInWatchLater
        self.isInWatchLater = !wasInWatchLater
        do {
            if wasInWatchLater {
                try await client.removeFromWatchLater(videoId: video.videoId)
            } else {
                try await client.addToWatchLater(videoId: video.videoId)
            }
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to edit Watch Later: \(error.localizedDescription)")
            self.isInWatchLater = wasInWatchLater
        }
    }

    func refreshPlaybackOptions() async {
        let videoId = self.currentVideo?.videoId
        for attempt in 0 ..< 3 {
            let tracks = await self.playbackController.availableCaptionTracks()
            guard self.currentVideo?.videoId == videoId else { return }

            self.captionTracks = tracks
            let levels = await self.playbackController.availableQualityLevels()
            self.qualityLevels = levels.isEmpty || levels.contains("auto")
                ? levels
                : levels + ["auto"]
            self.currentQuality = await self.playbackController.currentQualityLevel()
            self.activeCaptionLanguageCode = await self.playbackController.currentCaptionLanguageCode()

            if !tracks.isEmpty || attempt == 2 {
                return
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    @discardableResult
    func startStoryboardSpecRefreshIfNeeded() -> Bool {
        guard let videoId = self.currentVideo?.videoId,
              self.beginStoryboardSpecRefreshIfNeeded(videoId: videoId)
        else { return false }

        Task {
            await self.fetchStoryboardSpec(for: videoId)
        }
        return true
    }

    private func beginStoryboardSpecRefreshIfNeeded(videoId: String) -> Bool {
        if self.storyboardFetchVideoId == videoId {
            return false
        }
        if self.storyboardFetchInFlightVideoId == videoId {
            return false
        }
        self.storyboardFetchInFlightVideoId = videoId
        self.storyboardSpec = nil
        self.storyboardFetchVideoId = nil
        return true
    }

    private func fetchStoryboardSpec(for videoId: String) async {
        defer {
            if self.storyboardFetchInFlightVideoId == videoId {
                self.storyboardFetchInFlightVideoId = nil
            }
        }

        for attempt in 0 ..< 3 {
            let spec = await self.playbackController.storyboardSpec(expectedVideoId: videoId)
            guard self.currentVideo?.videoId == videoId else { return }
            if let spec {
                self.storyboardSpec = spec
                self.storyboardFetchVideoId = videoId
                return
            }
            if attempt == 2 {
                self.storyboardFetchVideoId = videoId
                return
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    func selectCaptionTrack(languageCode: String?) {
        self.activeCaptionLanguageCode = languageCode
        self.playbackController.setCaptionTrack(languageCode: languageCode)
        HapticService.toggle()
    }

    func selectQuality(_ level: String) {
        self.currentQuality = level
        self.userPinnedQuality = level == "auto" ? nil : level
        self.playbackController.setQualityLevel(level)
        HapticService.toggle()
    }

    func showAirPlayPicker(at screenPoint: CGPoint? = nil) {
        self.playbackController.showAirPlayPicker(at: screenPoint)
    }

    func toggleLike() async {
        await self.setRating(self.currentRating == .like ? .none : .like)
    }

    func toggleDislike() async {
        await self.setRating(self.currentRating == .dislike ? .none : .dislike)
    }

    private func setRating(_ newRating: YouTubeRating) async {
        guard let video = self.currentVideo, let client = self.youtubeClient else { return }
        let previous = self.currentRating
        self.currentRating = newRating
        do {
            try await client.rateVideo(videoId: video.videoId, rating: newRating)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to rate video: \(error.localizedDescription)")
            self.currentRating = previous
        }
    }

    private var pauseInPlaceOnDisappear = false
}

extension YouTubePlayerService {
    private func beginPlaybackLoading() {
        self.playbackLoadingTimeoutTask?.cancel()
        self.playbackLoadingGeneration &+= 1
        let loadingGeneration = self.playbackLoadingGeneration
        self.isPlaybackLoading = true

        let timeout = self.playbackLoadingTimeout
        let videoId = self.currentVideo?.videoId
        self.playbackLoadingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.playbackLoadingGeneration == loadingGeneration,
                  self.isPlaybackLoading,
                  self.currentVideo?.videoId == videoId
            else { return }
            if !self.playbackController.cancelPendingLoad() {
                self.deferCurrentVideoReload()
            }
        }
    }

    private func finishPlaybackLoading() {
        self.playbackLoadingGeneration &+= 1
        self.isPlaybackLoading = false
        self.playbackLoadingTimeoutTask?.cancel()
        self.playbackLoadingTimeoutTask = nil
    }

    func prepareForSourceSwitch() {
        guard self.surfaceLocation == .inline, self.currentVideo != nil else { return }
        if self.desiredPlaybackIntent == .playing {
            self.pause()
        }
        self.pauseInPlaceOnDisappear = true
    }

    func inlineSurfaceWillDisappear(videoId: String) {
        guard self.activeInlineVideoId == videoId else { return }
        self.activeInlineVideoId = nil

        guard self.currentVideo?.videoId == videoId, self.surfaceLocation == .inline else {
            self.pauseInPlaceOnDisappear = false
            return
        }

        if self.pauseInPlaceOnDisappear {
            self.pauseInPlaceOnDisappear = false
            return
        }

        if self.isPlaying, self.shouldPopOutOnNavigateAway() {
            self.popOutToWindow()
        } else {
            self.stop()
        }
    }

    struct PlaybackUpdate {
        let isPlaying: Bool
        let progress: Double
        let duration: Double
        var hasReadyMedia = false
        var hasMediaError = false
        var videoId: String?
        var boundVideoId: String?
        var title: String?
        var isAd = false
        var isLive = false
        var didApplyPendingSeek = false
        var didFailPendingSeek = false
        var pendingSeekTarget: Double?
        var pendingSeekVideoId: String?
        var pendingSeekAttempt: UInt64?
        var nativePausePending = false
        var eventIssuedAtMilliseconds: Double?
        var playbackOccurrence: YouTubePlaybackOccurrence?
    }

    func updatePlaybackState(_ update: PlaybackUpdate) {
        self.recordPostConclusionAutoplayTransitionIfNeeded(update)
        guard self.acceptsPlaybackOccurrence(update.playbackOccurrence) else { return }
        let reconciledPlayingState = self.reconciledPlayingState(for: update)
        guard self.currentVideo != nil else {
            if reconciledPlayingState.wasSuppressed {
                self.playbackController.pause()
            }
            return
        }
        self.bindPlaybackOccurrence(update.playbackOccurrence)
        let effectiveIsPlaying = reconciledPlayingState.isPlaying
        let shouldPreserveTerminalIntent = self.currentWatchConcluded
            && self.desiredPlaybackIntent == .paused
            && !update.hasReadyMedia
        self.reconcileObservedPauseIntent(update)
        self.reconcileDesiredPlaybackIntent(
            for: update,
            effectiveIsPlaying: effectiveIsPlaying,
            shouldPreserveTerminalIntent: shouldPreserveTerminalIntent
        )

        let completedIdentityReload = self.isIdentityReloadInFlight
            || self.pausedIdentityReloadAwaitingFirstUpdate
        guard !self.reconcilePendingPausedIdentityReload(
            for: update,
            effectiveIsPlaying: effectiveIsPlaying,
            completedIdentityReload: completedIdentityReload
        ) else { return }
        self.completeIdentityReloadIfNeeded(completedIdentityReload)

        self.isIdentityReloadInFlight = false
        self.acknowledgeExplicitStartTarget(with: update)
        self.acknowledgePendingUserSeek(with: update)
        self.applyPlaybackSnapshot(update, effectiveIsPlaying: effectiveIsPlaying)
        self.reopenConcludedWatchIfNeeded(update, effectiveIsPlaying: effectiveIsPlaying)
        self.refreshPlaybackMetadataIfNeeded(update, effectiveIsPlaying: effectiveIsPlaying)
        self.followPageDriftIfNeeded(update)
        self.finishPlaybackLoadingIfReady(update)
        self.deferMediaErrorIfNeeded(update)
        self.completeAutoplayTransitionIfNeeded(update)
        self.recordReadyContentProgressIfPossible(update)

        if reconciledPlayingState.wasSuppressed {
            self.playbackController.pause()
        }
    }

    func recordPostConclusionAutoplayTransitionIfNeeded(_ update: PlaybackUpdate) {
        guard self.currentVideo != nil,
              self.currentWatchConcluded,
              self.desiredPlaybackIntent == .paused,
              self.pendingUserSeekTarget == nil,
              update.isAd || !update.hasReadyMedia
        else { return }
        self.isAutoplayTransitionPending = true
    }

    private func reconcileDesiredPlaybackIntent(
        for update: PlaybackUpdate,
        effectiveIsPlaying: Bool,
        shouldPreserveTerminalIntent: Bool
    ) {
        if effectiveIsPlaying {
            let isCurrentResumeSample = if self.isAwaitingResumeConfirmation,
                                           let lastResumeIssuedAtMilliseconds,
                                           let eventIssuedAtMilliseconds = update.eventIssuedAtMilliseconds
            {
                eventIssuedAtMilliseconds >= lastResumeIssuedAtMilliseconds
            } else {
                true
            }
            if !shouldPreserveTerminalIntent,
               !update.nativePausePending,
               isCurrentResumeSample
            {
                self.desiredPlaybackIntent = .playing
                self.isAwaitingResumeConfirmation = false
            }
            self.hasObservedPausedMedia = false
        } else if update.hasReadyMedia {
            self.hasObservedPausedMedia = true
        }
    }

    @discardableResult
    private func reconcilePendingPausedIdentityReload(
        for update: PlaybackUpdate,
        effectiveIsPlaying: Bool,
        completedIdentityReload: Bool
    ) -> Bool {
        guard let pendingId = self.pendingPausedIdentityReloadVideoId,
              pendingId == (update.videoId ?? self.currentVideo?.videoId)
        else { return false }

        if effectiveIsPlaying, !completedIdentityReload {
            if self.pendingPausedIdentityReloadResumeAt == nil {
                self.pendingPausedIdentityReloadResumeAt =
                    self.explicitStartTarget(for: pendingId)
                        ?? self.deferredIdentityReloadResumeProgress(for: update)
            }
            _ = self.reloadPendingPausedIdentitySwitchForUserResume()
            return true
        }
        if !effectiveIsPlaying, !self.userUpdatedPendingPausedIdentityReloadSeek {
            self.pendingPausedIdentityReloadResumeAt =
                self.explicitStartTarget(for: pendingId)
                    ?? self.deferredIdentityReloadResumeProgress(for: update)
        }
        return false
    }

    private func completeIdentityReloadIfNeeded(_ completedIdentityReload: Bool) {
        guard completedIdentityReload else { return }
        self.pendingPausedIdentityReloadVideoId = nil
        self.pendingPausedIdentityReloadResumeAt = nil
        self.userUpdatedPendingPausedIdentityReloadSeek = false
        self.pausedIdentityReloadAwaitingFirstUpdate = false
    }

    private func applyPlaybackSnapshot(
        _ update: PlaybackUpdate,
        effectiveIsPlaying: Bool
    ) {
        if effectiveIsPlaying, !self.isPlaying {
            self.playbackWillStart?()
        }

        self.isPlaying = effectiveIsPlaying
        self.progress = update.progress
        self.duration = update.duration
        self.isShowingAd = update.isAd
        if !update.isAd,
           update.hasReadyMedia,
           let metadataVideoId = update.videoId,
           update.boundVideoId == metadataVideoId
        {
            let resolvedIsLive = update.isLive || self.currentVideo?.isLive == true
            self.currentMediaIsLive = resolvedIsLive
            if resolvedIsLive {
                self.updateCurrentVideoLiveness(true, videoId: metadataVideoId)
            }
        }
    }

    private func finishPlaybackLoadingIfReady(_ update: PlaybackUpdate) {
        guard self.readyMediaBelongsToCurrentPlayback(update) else { return }
        self.finishPlaybackLoading()
    }

    private func readyMediaBelongsToCurrentPlayback(_ update: PlaybackUpdate) -> Bool {
        guard update.hasReadyMedia, !update.hasMediaError else { return false }
        if update.isAd {
            return update.boundVideoId == self.currentVideo?.videoId
        }
        guard let currentVideoId = self.currentVideo?.videoId else { return false }
        return update.videoId == currentVideoId && update.boundVideoId == currentVideoId
    }

    private func deferMediaErrorIfNeeded(_ update: PlaybackUpdate) {
        guard self.mediaErrorBelongsToCurrentContent(update) else { return }
        self.deferCurrentVideoReload()
    }

    private func mediaErrorBelongsToCurrentContent(_ update: PlaybackUpdate) -> Bool {
        guard update.hasMediaError,
              !update.isAd,
              let currentVideoId = self.currentVideo?.videoId
        else { return false }

        if let boundVideoId = update.boundVideoId,
           boundVideoId != currentVideoId
        {
            return false
        }
        return update.videoId == nil || update.videoId == currentVideoId
    }

    private func reopenConcludedWatchIfNeeded(
        _ update: PlaybackUpdate,
        effectiveIsPlaying: Bool
    ) {
        if self.currentWatchConcluded,
           effectiveIsPlaying,
           !update.isAd,
           let videoId = update.videoId,
           videoId == self.currentVideo?.videoId
        {
            self.currentWatchConcluded = false
        }
    }

    private func completeAutoplayTransitionIfNeeded(_ update: PlaybackUpdate) {
        guard self.isAutoplayTransitionPending,
              !self.currentWatchConcluded,
              !update.isAd,
              update.hasReadyMedia,
              let boundVideoId = update.boundVideoId,
              boundVideoId == self.currentVideo?.videoId
        else { return }
        self.isAutoplayTransitionPending = false
    }

    private func refreshPlaybackMetadataIfNeeded(
        _ update: PlaybackUpdate,
        effectiveIsPlaying: Bool
    ) {
        if effectiveIsPlaying,
           let videoId = self.currentVideo?.videoId,
           self.playbackOptionsVideoId != videoId
        {
            self.playbackOptionsVideoId = videoId
            Task {
                await self.refreshPlaybackOptions()
            }
        }

        if update.isPlaying,
           !update.isAd,
           self.currentVideo != nil,
           AmbientVideoBackdrop.effectiveStyle(
               requestedStyle: SettingsManager.shared.resolvedAmbientStyle,
               reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
           ) == .live
        {
            self.startStoryboardSpecRefreshIfNeeded()
        }
    }

    private func followPageDriftIfNeeded(_ update: PlaybackUpdate) {
        guard !update.isAd,
              let videoId = update.videoId,
              let current = self.currentVideo,
              videoId != current.videoId,
              !self.isAutoplayTransitionPending
              || (update.hasReadyMedia && update.boundVideoId == videoId)
        else { return }

        self.beginYouTubePlaybackIntent(
            issuedAtMilliseconds: update.eventIssuedAtMilliseconds
        )
        self.logger.info("YouTubePlayer: page drifted to a different video, following")
        let shouldRepointDriftedVideo = self.pendingPausedIdentityReloadVideoId != nil
        let driftedContentProgress: Double? = if !update.isAd,
                                                 update.hasReadyMedia,
                                                 update.boundVideoId == videoId
        {
            update.progress
        } else {
            nil
        }
        let driftedIsLive = update.hasReadyMedia
            && update.boundVideoId == videoId
            && update.isLive
        self.resetPerVideoState()
        self.currentMediaIsLive = driftedIsLive
        self.currentVideo = YouTubeVideo(
            videoId: videoId,
            title: update.title ?? current.title,
            channelName: current.channelName,
            channelId: current.channelId,
            isLive: driftedIsLive
        )
        let readyMediaBelongsToDriftedVideo = update.hasReadyMedia
            && !update.hasMediaError
            && update.boundVideoId == videoId
        if !readyMediaBelongsToDriftedVideo {
            self.beginPlaybackLoading()
        }
        if let driftedContentProgress {
            self.lastNonAdContentProgress = driftedContentProgress
            self.lastNonAdContentVideoId = videoId
        }
        self.signalWatchConclusion()
        self.watchActivityGeneration += 1
        self.currentWatchConcluded = false
        YouTubeWatchWebView.shared.currentVideoId = videoId
        if shouldRepointDriftedVideo {
            self.reloadCurrentVideoForIdentitySwitch()
        }
    }

    private func recordReadyContentProgressIfPossible(_ update: PlaybackUpdate) {
        if !update.isAd,
           update.hasReadyMedia,
           let boundVideoId = update.boundVideoId,
           boundVideoId == self.currentVideo?.videoId
        {
            self.lastNonAdContentProgress = update.progress
            self.lastNonAdContentVideoId = boundVideoId
        }
    }

    private func updateCurrentVideoLiveness(_ isLive: Bool, videoId: String?) {
        guard let videoId,
              let current = self.currentVideo,
              current.videoId == videoId,
              current.isLive != isLive
        else { return }
        self.currentVideo = YouTubeVideo(
            videoId: current.videoId,
            title: current.title,
            channelName: current.channelName,
            channelId: current.channelId,
            lengthText: current.lengthText,
            viewCountText: current.viewCountText,
            publishedText: current.publishedText,
            thumbnailURL: current.thumbnailURL,
            isLive: isLive,
            isShort: current.isShort,
            watchedPercent: current.watchedPercent
        )
    }

    private func reconciledPlayingState(for update: PlaybackUpdate) -> (
        isPlaying: Bool,
        wasSuppressed: Bool
    ) {
        let isSuppressed = update.isPlaying
            && self.isExplicitPauseIntentActive
        return (update.isPlaying && !isSuppressed, isSuppressed)
    }

    private func reconcileObservedPauseIntent(_ update: PlaybackUpdate) {
        guard !update.isPlaying,
              !self.isExplicitPauseIntentActive,
              !self.isAwaitingResumeConfirmation,
              !self.isPlaybackLoading,
              update.hasReadyMedia,
              !update.isAd,
              self.isPlaying
        else { return }
        self.desiredPlaybackIntent = .paused
    }

    private func deferredIdentityReloadResumeProgress(for update: PlaybackUpdate) -> Double? {
        let currentVideoId = self.currentVideo?.videoId
        if !update.isAd,
           update.hasReadyMedia,
           update.boundVideoId == currentVideoId,
           update.progress > 0
        {
            return update.progress
        }
        guard self.lastNonAdContentVideoId == currentVideoId,
              self.lastNonAdContentProgress > 0
        else { return nil }
        return self.lastNonAdContentProgress
    }

    private func acknowledgeExplicitStartTarget(with update: PlaybackUpdate) {
        guard !update.isAd,
              let target = self.pendingExplicitStartTarget,
              (update.pendingSeekVideoId ?? update.videoId) == target.videoId
        else { return }
        guard update.didApplyPendingSeek else { return }
        self.pendingExplicitStartTarget = nil
    }

    private func acknowledgePendingUserSeek(with update: PlaybackUpdate) {
        guard update.didApplyPendingSeek,
              let pendingUserSeekTarget = self.pendingUserSeekTarget,
              update.pendingSeekVideoId == pendingUserSeekTarget.videoId,
              let appliedTarget = update.pendingSeekTarget,
              abs(appliedTarget - pendingUserSeekTarget.seconds) < 0.001
        else { return }
        self.pendingUserSeekTarget = nil
    }

    @discardableResult
    func handleVideoEnded(
        videoId: String?,
        playbackOccurrence: YouTubePlaybackOccurrence? = nil,
        eventIssuedAtMilliseconds: Double? = nil,
        isNativeTerminal: Bool = false
    ) -> Bool {
        self.logger.info("YouTubePlayer: video ended")
        let isStaleId = videoId != nil && videoId != self.currentVideo?.videoId
        guard !isStaleId, !self.isShowingAd else {
            self.logger.debug("YouTubePlayer: ignoring ended event (stale id or ad)")
            return false
        }
        if !isNativeTerminal, let eventIssuedAtMilliseconds {
            if Self.isEndEventStale(
                eventIssuedAtMilliseconds: eventIssuedAtMilliseconds,
                lastResumeIssuedAtMilliseconds: self.youtubePlaybackIntentIssuedAtMilliseconds
            ) {
                return false
            }
            if let lastResumeIssuedAtMilliseconds = self.lastResumeIssuedAtMilliseconds,
               Self.isEndEventStale(
                   eventIssuedAtMilliseconds: eventIssuedAtMilliseconds,
                   lastResumeIssuedAtMilliseconds: lastResumeIssuedAtMilliseconds
               )
            {
                return false
            }
        }
        guard self.claimEndedPlaybackOccurrence(
            playbackOccurrence,
            isNativeTerminal: isNativeTerminal
        ) else {
            self.logger.debug("YouTubePlayer: ignoring ended event for stale playback occurrence")
            return false
        }
        if !isNativeTerminal, let eventIssuedAtMilliseconds {
            self.beginYouTubePlaybackIntent(
                issuedAtMilliseconds: eventIssuedAtMilliseconds
            )
        }
        self.isPlaying = false
        self.desiredPlaybackIntent = .paused
        self.isAwaitingResumeConfirmation = false
        self.lastResumeIssuedAtMilliseconds = nil
        self.pendingExplicitStartTarget = nil
        self.pendingUserSeekTarget = nil
        self.finishPlaybackLoading()
        if self.signalWatchConclusion() {
            self.watchActivityGeneration += 1
            self.onVideoEnded?(videoId)
        }
        return true
    }

    nonisolated static func isEndEventStale(
        eventIssuedAtMilliseconds: Double,
        lastResumeIssuedAtMilliseconds: Double
    ) -> Bool {
        floor(eventIssuedAtMilliseconds) < floor(lastResumeIssuedAtMilliseconds)
    }

    @discardableResult
    private func signalWatchConclusion() -> Bool {
        guard !self.currentWatchConcluded else { return false }
        self.watchConclusionGeneration += 1
        self.currentWatchConcluded = true
        return true
    }

    func acceptsPlaybackOccurrence(_ occurrence: YouTubePlaybackOccurrence?) -> Bool {
        guard let occurrence else { return true }
        if let lastEndedPlaybackOccurrence,
           !Self.isPlaybackOccurrence(occurrence, newerThan: lastEndedPlaybackOccurrence)
        {
            return false
        }
        guard let currentPlaybackOccurrence else { return true }
        return Self.isPlaybackOccurrence(
            occurrence,
            newerThanOrEqualTo: currentPlaybackOccurrence
        )
    }

    private func bindPlaybackOccurrence(_ occurrence: YouTubePlaybackOccurrence?) {
        guard let occurrence else { return }
        self.currentPlaybackOccurrence = occurrence
    }

    private func claimEndedPlaybackOccurrence(
        _ occurrence: YouTubePlaybackOccurrence?,
        isNativeTerminal: Bool
    ) -> Bool {
        let isResumedNativeTerminal = isNativeTerminal
            && self.currentWatchConcluded
            && self.lastResumeIssuedAtMilliseconds != nil
        guard let occurrence = occurrence ?? self.currentPlaybackOccurrence else {
            if isResumedNativeTerminal {
                self.currentWatchConcluded = false
                return true
            }
            return !self.currentWatchConcluded
        }
        if let lastEndedPlaybackOccurrence,
           !Self.isPlaybackOccurrence(occurrence, newerThan: lastEndedPlaybackOccurrence)
        {
            guard isResumedNativeTerminal,
                  occurrence == self.currentPlaybackOccurrence
            else { return false }
            self.currentWatchConcluded = false
            return true
        }
        let isNewerThanCurrent = self.currentPlaybackOccurrence.map {
            Self.isPlaybackOccurrence(occurrence, newerThan: $0)
        } ?? true
        if let currentPlaybackOccurrence {
            guard Self.isPlaybackOccurrence(
                occurrence,
                newerThanOrEqualTo: currentPlaybackOccurrence
            ) else { return false }
        }
        if isResumedNativeTerminal || (isNewerThanCurrent && self.currentWatchConcluded) {
            self.currentWatchConcluded = false
        }
        self.currentPlaybackOccurrence = occurrence
        self.lastEndedPlaybackOccurrence = occurrence
        return true
    }

    private func resetPlaybackOccurrenceState() {
        self.currentPlaybackOccurrence = nil
        self.lastEndedPlaybackOccurrence = nil
        self.lastResumeIssuedAtMilliseconds = nil
    }

    private static func isPlaybackOccurrence(
        _ occurrence: YouTubePlaybackOccurrence,
        newerThanOrEqualTo other: YouTubePlaybackOccurrence
    ) -> Bool {
        if occurrence.documentGeneration != other.documentGeneration {
            return occurrence.documentGeneration > other.documentGeneration
        }
        return occurrence.mediaGeneration >= other.mediaGeneration
    }

    private static func isPlaybackOccurrence(
        _ occurrence: YouTubePlaybackOccurrence,
        newerThan other: YouTubePlaybackOccurrence
    ) -> Bool {
        if occurrence.documentGeneration != other.documentGeneration {
            return occurrence.documentGeneration > other.documentGeneration
        }
        return occurrence.mediaGeneration > other.mediaGeneration
    }
}
