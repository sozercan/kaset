import SwiftUI

// MARK: - MiniPlayerSeekState

/// Seek state owned by `MiniPlayerWindow` and shared by its per-layout seek sections, so a
/// pending seek hold survives panel layout changes. The window must not read these
/// properties in `body`, or progress ticks re-evaluate the whole window again.
@MainActor
@Observable
final class MiniPlayerSeekState {
    var seekValue: Double = 0
    var isSeeking = false
    var hold = PlayerBarSeekHold()

    /// Reconciles a copy so observers are only notified when the hold actually changes;
    /// calling a mutating method on the stored property notifies on every progress tick.
    func reconcileHold(observedProgress: TimeInterval) {
        var hold = self.hold
        hold.reconcile(observedProgress: observedProgress)
        if hold != self.hold {
            self.hold = hold
        }
    }
}

// MARK: - MiniPlayerSeekSection

/// Mini player seek slider and elapsed/remaining labels.
///
/// This is the only mini player view that observes `PlayerService.progress`, so each
/// playback tick re-evaluates just this section instead of the whole mini player window.
struct MiniPlayerSeekSection: View {
    /// `.nowPlaying` swaps the system slider for the Now Playing view's thin capsule bar.
    enum Style {
        case mini
        case nowPlaying
    }

    @Bindable var state: MiniPlayerSeekState
    var style: Style = .mini

    @Environment(PlayerService.self) private var playerService

    var body: some View {
        VStack(spacing: self.style == .mini ? 8 : 4) {
            self.slider
                .disabled(self.playerService.duration <= 0 || self.playerService.isCurrentItemLive || self.playerService.isShowingAd)
            HStack {
                Text(PlayerBarSeekController.formatTime(self.state.isSeeking ? self.state.seekValue * self.playerService.duration : self.displayedPlaybackProgress))
                Spacer()
                Text(self.playerService.isCurrentItemLive ? String(localized: "LIVE") : self.remainingTimeText)
            }
            .font(.system(size: self.style == .mini ? 9 : 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(self.style == .mini ? 0.76 : 0.55))
            .shadow(color: .black.opacity(self.style == .mini ? 0.56 : 0), radius: 2, y: 1)
            .overlay { WindowDragHandle() }
        }
        .onChange(of: self.playerService.progress) { _, newValue in
            self.state.reconcileHold(observedProgress: newValue)
            if !self.state.isSeeking, !self.state.hold.isActive, self.playerService.duration > 0 {
                self.state.seekValue = self.displayedPlaybackProgress / self.playerService.duration
            }
        }
        .onChange(of: self.playerService.duration) { _, _ in
            self.state.reconcileHold(observedProgress: self.playerService.progress)
            if !self.state.isSeeking, !self.state.hold.isActive {
                self.syncSeekValue()
            }
        }
        .onChange(of: self.currentTrackIdentity) { _, _ in
            self.clearSeekHold()
        }
        .onChange(of: self.playerService.isShowingAd) { _, isShowingAd in
            if isShowingAd {
                self.clearSeekHold()
            }
        }
        .onAppear {
            self.syncSeekValue()
        }
        .onDisappear {
            // A panel switch mid-drag can remove the slider before it reports the end of editing.
            self.state.isSeeking = false
        }
    }

    @ViewBuilder
    private var slider: some View {
        switch self.style {
        case .mini:
            Slider(value: self.$state.seekValue, in: 0 ... 1, onEditingChanged: self.seekEditingChanged)
                .controlSize(.small)
                .tint(PackageResourceLookup.brandAccent)
                .accessibilityIdentifier(AccessibilityID.MiniPlayer.seekSlider)
        case .nowPlaying:
            NowPlayingCapsuleSlider(
                value: self.$state.seekValue,
                accessibilityLabel: String(localized: "Playback position"),
                accessibilityValue: PlayerBarSeekController.formatTime(self.state.seekValue * self.playerService.duration),
                onEditingChanged: self.seekEditingChanged
            )
        }
    }

    private func seekEditingChanged(_ editing: Bool) {
        self.state.isSeeking = editing
        if !editing {
            self.performSeek()
        }
    }

    private var remainingTimeText: String {
        "-\(PlayerBarSeekController.formatTime(max(0, self.playerService.duration - self.displayedPlaybackProgress)))"
    }

    private var displayedPlaybackProgress: TimeInterval {
        self.state.hold.displayProgress(observedProgress: self.playerService.progress)
    }

    private var currentTrackIdentity: String {
        self.playerService.currentTrack?.videoId ?? "none"
    }

    private func syncSeekValue() {
        if self.playerService.duration > 0 {
            self.state.seekValue = self.displayedPlaybackProgress / self.playerService.duration
        } else {
            self.state.seekValue = 0
        }
    }

    private func performSeek() {
        guard self.playerService.duration > 0, !self.playerService.isShowingAd else { return }
        let target = self.state.seekValue * self.playerService.duration
        let holdID = self.state.hold.begin(target: target)
        Task { await self.playerService.seek(to: target) }
        Task { @MainActor in
            try? await Task.sleep(for: PlayerBarSeekHold.timeout)
            if self.state.hold.clearIfCurrent(holdID) {
                self.syncSeekValue()
            }
        }
    }

    private func clearSeekHold() {
        self.state.hold.clear()
        self.state.isSeeking = false
        self.syncSeekValue()
    }
}
