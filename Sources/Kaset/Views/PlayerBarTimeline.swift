import SwiftUI

@MainActor
@Observable
final class PlayerBarSeekController {
    var seekValue: Double = 0
    private(set) var isSeeking = false
    private(set) var hold = PlayerBarSeekHold()
    private(set) var formattedProgress = "0:00"
    private(set) var formattedRemaining = "-0:00"
    private(set) var currentSegmentID: String?

    @ObservationIgnored private var lastProgressSecond = -1

    func displayProgress(observedProgress: TimeInterval) -> TimeInterval {
        self.hold.displayProgress(observedProgress: observedProgress)
    }

    func displayFraction(progress: TimeInterval, duration: TimeInterval) -> Double {
        if self.isSeeking {
            return min(max(0, self.seekValue), 1)
        }
        guard duration > 0 else { return 0 }
        return min(max(0, self.displayProgress(observedProgress: progress) / duration), 1)
    }

    func progressDidChange(_ progress: TimeInterval, duration: TimeInterval) {
        self.reconcileHold(observedProgress: progress)
        let displayProgress = self.displayProgress(observedProgress: progress)

        if !self.isSeeking, !self.hold.isActive, duration > 0 {
            self.seekValue = displayProgress / duration
        }

        let currentSecond = Int(displayProgress)
        if currentSecond != self.lastProgressSecond {
            self.lastProgressSecond = currentSecond
            self.updateFormattedTimes(progress: displayProgress, duration: duration)
        }
    }

    func durationDidChange(_ duration: TimeInterval, progress: TimeInterval) {
        self.reconcileHold(observedProgress: progress)
        let displayProgress = self.displayProgress(observedProgress: progress)
        if !self.isSeeking, !self.hold.isActive, duration > 0 {
            self.seekValue = displayProgress / duration
        }
        self.updateFormattedTimes(progress: displayProgress, duration: duration)
    }

    func updateCurrentSegment(fraction: Double, segments: [PlayerBarProgressSegment]) {
        self.currentSegmentID = PlayerBarProgressLane.segment(at: fraction, in: segments)?.id
    }

    func scrub(to fraction: Double) {
        self.isSeeking = true
        self.seekValue = fraction
    }

    func cancelScrub() {
        self.isSeeking = false
    }

    func performSeek(playerService: PlayerService) {
        guard self.isSeeking, Self.canSeek(playerService) else { return }
        let duration = playerService.duration
        let seekTime = self.seekValue * duration
        let holdID = self.hold.begin(target: seekTime)
        self.updateFormattedTimes(progress: seekTime, duration: duration)
        self.isSeeking = false

        Task {
            await playerService.seek(to: seekTime)
        }
        Task { @MainActor in
            try? await Task.sleep(for: PlayerBarSeekHold.timeout)
            if self.hold.clearIfCurrent(holdID) {
                self.syncFromDisplayedProgress(playerService: playerService)
            }
        }
    }

    func seek(to segment: PlayerBarProgressSegment, playerService: PlayerService) {
        guard Self.canSeek(playerService) else { return }
        self.scrub(to: segment.start)
        self.performSeek(playerService: playerService)
    }

    func clearHold(playerService: PlayerService) {
        self.hold.clear()
        self.isSeeking = false
        self.syncFromDisplayedProgress(playerService: playerService)
    }

    func syncFromDisplayedProgress(playerService: PlayerService) {
        let duration = playerService.duration
        let displayProgress = self.displayProgress(observedProgress: playerService.progress)
        self.seekValue = duration > 0 ? displayProgress / duration : 0
        self.updateFormattedTimes(progress: displayProgress, duration: duration)
    }

    private func reconcileHold(observedProgress: TimeInterval) {
        var hold = self.hold
        hold.reconcile(observedProgress: observedProgress)
        if hold != self.hold {
            self.hold = hold
        }
    }

    private func updateFormattedTimes(progress: TimeInterval, duration: TimeInterval) {
        self.formattedProgress = Self.formatTime(progress)
        self.formattedRemaining = "-\(Self.formatTime(max(0, duration - progress)))"
    }

    static func canSeek(_ playerService: PlayerService) -> Bool {
        playerService.currentTrack != nil
            && playerService.duration > 0
            && !playerService.isCurrentItemLive
            && !playerService.isShowingAd
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%d:%02d", mins, secs)
        }
    }

    static func progressSegments(
        tracklist: MixTracklist?,
        duration: TimeInterval,
        isLive: Bool
    ) -> [PlayerBarProgressSegment] {
        guard let tracklist, duration > 0, !isLive else { return [] }

        let entries = tracklist.entries
        let count = entries.count
        return entries.enumerated().map { index, entry in
            let end = entry.endTime ?? duration
            return PlayerBarProgressSegment(
                id: entry.id.uuidString,
                start: entry.startTime / duration,
                end: end / duration,
                index: index,
                count: count,
                title: entry.title,
                subtitle: entry.artist,
                rangeText: "\(Self.formatTime(entry.startTime)) – \(Self.formatTime(end))"
            )
        }
    }
}

struct PlayerBarTimelineLane: View {
    let seekController: PlayerBarSeekController
    let segments: [PlayerBarProgressSegment]
    let accent: Color

    @Environment(PlayerService.self) private var playerService

    var body: some View {
        let duration = self.playerService.duration
        let isSeeking = self.seekController.isSeeking
        let fraction = self.seekController.displayFraction(
            progress: self.playerService.progress,
            duration: duration
        )

        PlayerBarProgressLane(
            fraction: fraction,
            accent: self.accent,
            elapsedText: isSeeking
                ? PlayerBarSeekController.formatTime(self.seekController.seekValue * duration)
                : self.seekController.formattedProgress,
            remainingText: isSeeking
                ? "-\(PlayerBarSeekController.formatTime(max(0, duration - self.seekController.seekValue * duration)))"
                : self.seekController.formattedRemaining,
            segments: self.segments,
            isLive: self.playerService.isCurrentItemLive,
            canSeek: PlayerBarSeekController.canSeek(self.playerService),
            isLoading: self.isLoading,
            onScrub: { fraction in
                self.seekController.scrub(to: fraction)
            },
            onCommit: {
                self.seekController.performSeek(playerService: self.playerService)
            }
        )
        .onChange(of: self.playerService.progress) { _, newValue in
            self.seekController.progressDidChange(newValue, duration: self.playerService.duration)
        }
        .onChange(of: self.playerService.duration) { _, newValue in
            self.seekController.durationDidChange(newValue, progress: self.playerService.progress)
        }
        .onChange(of: fraction) { _, newValue in
            self.seekController.updateCurrentSegment(fraction: newValue, segments: self.segments)
        }
        .onChange(of: self.segments) { _, _ in
            self.updateCurrentSegment()
        }
        .onAppear {
            self.seekController.syncFromDisplayedProgress(playerService: self.playerService)
            self.updateCurrentSegment()
        }
        .onDisappear {
            self.seekController.cancelScrub()
        }
    }

    private var isLoading: Bool {
        switch self.playerService.state {
        case .loading, .buffering:
            self.playerService.currentTrack != nil
        case .idle, .playing, .paused, .ended, .error:
            false
        }
    }

    private func updateCurrentSegment() {
        let fraction = self.seekController.displayFraction(
            progress: self.playerService.progress,
            duration: self.playerService.duration
        )
        self.seekController.updateCurrentSegment(fraction: fraction, segments: self.segments)
    }
}

struct PlayerBarMixTracksMenu: View {
    let seekController: PlayerBarSeekController
    let segments: [PlayerBarProgressSegment]

    @Environment(PlayerService.self) private var playerService

    var body: some View {
        PlayerBarIconMenu(
            accessibilityID: AccessibilityID.PlayerBar.mixTracksButton,
            accessibilityLabel: String(localized: "Mix tracks")
        ) {
            ForEach(self.segments) { segment in
                Button {
                    self.seekController.seek(to: segment, playerService: self.playerService)
                } label: {
                    if segment.id == self.seekController.currentSegmentID {
                        Label(segment.accessibilityDescription, systemImage: "checkmark")
                    } else {
                        Text(segment.accessibilityDescription)
                    }
                }
                .disabled(!PlayerBarSeekController.canSeek(self.playerService))
            }
        } icon: {
            Image(systemName: "list.number")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
        }
    }
}
