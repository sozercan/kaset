import Foundation

extension YouTubePlayerService {
    /// Playback rates offered in the player bar speed menu, from 0.25× to 2×.
    static let playbackRateOptions: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Selects a playback rate from the speed menu, clamping it to the supported range.
    /// The rate persists across videos until the user picks another one.
    func selectPlaybackRate(_ rate: Double) {
        self.playbackRate = YouTubeWatchWebView.clampedPlaybackRate(rate)
        HapticService.toggle()
    }

    /// Formats a playback rate for display, e.g. `1.5×` or `2×`.
    static func playbackRateDisplayName(_ rate: Double) -> String {
        let formatted = rate.formatted(.number.precision(.fractionLength(0 ... 2)))
        return "\(formatted)×"
    }
}
