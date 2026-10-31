import Foundation
import Testing
@testable import Kaset

@MainActor
struct NowPlayingShowcaseTests {
    @Test("Panel selection preserves the showcase and does not open another window", arguments: PlayerService.NowPlayingPanel.allCases)
    func selectPanel(panel: PlayerService.NowPlayingPanel) {
        let player = PlayerService()
        player.showNowPlayingShowcase = true
        player.nowPlayingPanel = nil

        player.nowPlayingPanel = panel

        #expect(player.showNowPlayingShowcase)
        #expect(player.nowPlayingPanel == panel)
        #expect(!player.showLyrics && !player.showQueue)
        #expect(!player.showVideo && !player.isMiniPlayerVisible)
    }

    @Test("Wide saved panels still leave room for artwork at the minimum window size")
    func minimumWindowLayout() {
        let size = CGSize(width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
        let width = NowPlayingShowcaseLayout.panelWidth(in: size.width, preferred: 560)
        let artwork = NowPlayingShowcaseLayout.artworkSize(in: size, panelWidth: width)

        #expect(width <= size.width * 0.46)
        #expect(artwork + width + 24 + 48 <= size.width)
        #expect(artwork + 264 <= size.height)
        #expect(artwork >= 160)
    }

    @Test("Recommendations filter the seed and duplicate tracks")
    func recommendations() async {
        let client = MockYTMusicClient()
        let song = Self.song("recommended")
        client.radioQueueSongs["seed"] = [Self.song("seed"), song, song]
        let model = ShowcaseRecommendationsModel()

        await model.load(videoId: "seed", client: client)

        #expect(model.songs.map(\.videoId) == ["recommended"])
        #expect(!model.isLoading && !model.hasError)
    }

    @Test("An old recommendation response cannot replace the current track's results")
    func staleRecommendations() async {
        let client = MockYTMusicClient()
        let started = AsyncGate()
        let release = AsyncGate()
        client.radioQueueSongs = ["old": [Self.song("old-result")], "new": [Self.song("new-result")]]
        client.beforeRadioQueueReturn = { videoId in
            if videoId == "old" {
                await started.open()
                await release.wait()
            }
        }
        let model = ShowcaseRecommendationsModel()
        let oldRequest = Task { await model.load(videoId: "old", client: client) }
        await started.wait()

        await model.load(videoId: "new", client: client)
        await release.open()
        await oldRequest.value

        #expect(model.songs.map(\.videoId) == ["new-result"])
        #expect(!model.isLoading && !model.hasError)
    }

    @Test("A failed recommendation request can be retried")
    func recommendationRetry() async {
        let client = MockYTMusicClient()
        client.radioQueueErrors["seed"] = YTMusicError.authExpired
        let model = ShowcaseRecommendationsModel()
        await model.load(videoId: "seed", client: client)
        #expect(model.hasError && !model.isLoading)

        client.radioQueueErrors = [:]
        client.radioQueueSongs["seed"] = [Self.song("retry-result")]
        await model.load(videoId: "seed", client: client)

        #expect(!model.hasError && !model.isLoading)
        #expect(model.songs.map(\.videoId) == ["retry-result"])
    }

    private static func song(_ id: String) -> Song {
        Song(id: id, title: id, artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: id)
    }
}
