import Foundation

// MARK: - NowPlayingCommand

enum NowPlayingCommand: Equatable {
    case play
    case pause
    case togglePlay
    case next
    case previous
    case seek(seconds: TimeInterval)
    case setVolume(Double)
    case toggleShuffle
    case cycleRepeatMode
    case like
    case dislike
}

// MARK: - NowPlayingCommandRouting

@MainActor
protocol NowPlayingCommandRouting: AnyObject {
    func handle(_ command: NowPlayingCommand) async
}

// MARK: - PlayerNowPlayingCommandRouter

@MainActor
final class PlayerNowPlayingCommandRouter: NowPlayingCommandRouting {
    private let playerService: any PlayerServiceProtocol

    init(playerService: any PlayerServiceProtocol) {
        self.playerService = playerService
    }

    func handle(_ command: NowPlayingCommand) async {
        switch command {
        case .play:
            await self.playerService.resume()
        case .pause:
            await self.playerService.pause()
        case .togglePlay:
            await self.playerService.playPause()
        case .next:
            await self.playerService.next()
        case .previous:
            await self.playerService.previous()
        case let .seek(seconds):
            await self.playerService.seek(to: max(0, seconds))
        case let .setVolume(volume):
            await self.playerService.setVolume(max(0, min(1, volume)))
        case .toggleShuffle:
            self.playerService.toggleShuffle()
        case .cycleRepeatMode:
            self.playerService.cycleRepeatMode()
        case .like:
            self.playerService.likeCurrentTrack()
        case .dislike:
            self.playerService.dislikeCurrentTrack()
        }
    }
}
