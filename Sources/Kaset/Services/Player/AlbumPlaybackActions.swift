import Foundation

@MainActor
enum AlbumPlaybackActions {
    @discardableResult
    static func addAlbumToQueueNext(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) -> Task<Void, Never> {
        let queueGeneration = playerService.queueLoadGeneration
        return Task {
            do {
                let songs = try await self.albumSongs(album, client: client, purpose: .queue)
                guard !songs.isEmpty,
                      playerService.isCurrentQueueLoad(queueGeneration)
                else { return }
                playerService.insertNextInQueue(songs)
                DiagnosticsLogger.ui.info("Added album '\(album.title)' (\(songs.count) songs) to play next")
            } catch {
                DiagnosticsLogger.ui.error("Failed to add album to queue: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    static func addAlbumToQueueLast(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) -> Task<Void, Never> {
        let queueGeneration = playerService.queueLoadGeneration
        return Task {
            do {
                let songs = try await self.albumSongs(album, client: client, purpose: .queue)
                guard !songs.isEmpty,
                      playerService.isCurrentQueueLoad(queueGeneration)
                else { return }
                playerService.appendToQueue(songs)
                DiagnosticsLogger.ui.info("Added album '\(album.title)' (\(songs.count) songs) to end of queue")
            } catch {
                DiagnosticsLogger.ui.error("Failed to add album to queue: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    @MainActor
    static func playAlbum(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService,
        onStart: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> Task<Void, Never> {
        let intent = playerService.beginMusicPlaybackIntent()
        return Task { @MainActor in
            var didStart = false
            defer {
                if !didStart {
                    onStart(false)
                }
            }
            do {
                let response = try await client.getPlaylist(id: album.id)
                guard playerService.acceptsMusicPlaybackIntent(intent) else {
                    DiagnosticsLogger.ui.info("Discarding stale album playback request after newer playback intent")
                    return
                }
                let songs = QueueSongMetadata.albumSongs(
                    response.detail.tracks,
                    album: album,
                    purpose: .playback(trackCount: response.detail.tracks.count)
                )
                guard let startIndex = songs.firstIndex(where: \.isPlayable) else { return }
                await playerService.playQueue(
                    songs,
                    startingAt: startIndex,
                    deferringSmartShuffleFill: false,
                    intent: intent
                )
                didStart = true
                onStart(true)
                DiagnosticsLogger.ui.info("Playing album '\(album.title)' (\(songs.count) songs)")
            } catch {
                DiagnosticsLogger.ui.error("Failed to play album: \(error.localizedDescription)")
            }
        }
    }

    private static func albumSongs(
        _ album: Album,
        client: any YTMusicClientProtocol,
        purpose: QueueSongMetadata.AlbumSongPurpose
    ) async throws -> [Song] {
        let response = try await client.getPlaylist(id: album.id)
        return QueueSongMetadata.albumSongs(
            response.detail.tracks,
            album: album,
            purpose: purpose
        )
    }
}
