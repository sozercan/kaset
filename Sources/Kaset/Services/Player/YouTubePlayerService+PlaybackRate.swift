import Foundation

extension YouTubePlayerService {
    static let playbackRateOptions: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    func selectPlaybackRate(_ rate: Double) {
        self.playbackRate = YouTubeWatchWebView.clampedPlaybackRate(rate)
        HapticService.toggle()
    }

    static func playbackRateDisplayName(_ rate: Double) -> String {
        let formatted = rate.formatted(.number.precision(.fractionLength(0 ... 2)))
        return "\(formatted)×"
    }
}
