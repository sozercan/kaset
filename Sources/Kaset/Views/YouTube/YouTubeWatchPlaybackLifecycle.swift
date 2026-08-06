// MARK: - YouTubeWatchPlaybackLifecycle

@MainActor
enum YouTubeWatchPlaybackLifecycle {
    static func presentSurface(
        video: YouTubeVideo,
        player: YouTubePlayerService,
        usesCookieFreeDataStore: Bool,
        startAt: Double? = nil,
        data: WatchNextData
    ) {
        if player.currentVideo?.videoId == video.videoId {
            if player.surfaceLocation == .floating {
                player.dockInline()
            }
        } else {
            player.play(
                video: video,
                usesCookieFreeDataStore: usesCookieFreeDataStore,
                startAt: startAt
            )
        }
        player.setUpNext(data.related)
        player.setChapters(data.chapters)
        player.activeInlineVideoId = video.videoId
    }

    static func synchronizeLoadedData(
        videoId: String,
        player: YouTubePlayerService,
        data: WatchNextData
    ) {
        guard player.currentVideo?.videoId == videoId else { return }
        player.setUpNext(data.related)
        player.setChapters(data.chapters)
    }
}
