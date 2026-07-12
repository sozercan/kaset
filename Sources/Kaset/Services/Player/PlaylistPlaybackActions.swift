import Foundation

/// Playback actions for playlist-backed queues.
enum PlaylistPlaybackActions {
    struct ContinuationContext {
        let continuationToken: String?
        let loadGeneration: Int
        let playlist: Playlist
        let requiresAuth: Bool
        let client: any YTMusicClientProtocol
        let playerService: PlayerService
    }

    /// Plays a playlist immediately, replacing the current queue.
    static func playPlaylist(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        Task { @MainActor in
            let requestGeneration = playerService.playbackRequestGeneration
            do {
                let response = try await client.getPlaylist(id: playlist.id)
                guard requestGeneration == playerService.playbackRequestGeneration else {
                    DiagnosticsLogger.ui.info("Discarding stale playlist playback request after privacy boundary")
                    return
                }
                var songs = response.detail.tracks

                if self.isRadioPlaylist(playlist.id) {
                    do {
                        let allTracks = try await client.getPlaylistAllTracks(playlistId: playlist.id)
                        guard requestGeneration == playerService.playbackRequestGeneration else {
                            DiagnosticsLogger.ui.info("Discarding stale playlist all-tracks request after privacy boundary")
                            return
                        }
                        if allTracks.count >= songs.count, !allTracks.isEmpty {
                            songs = self.tracksForPlaylistPlayback(
                                browseTracks: response.detail.tracks,
                                queueTracks: allTracks
                            )
                        }
                    } catch {
                        DiagnosticsLogger.ui.debug("Falling back to browse playlist tracks: \(error.localizedDescription)")
                    }
                } else {
                    let playableSongs = self.playableSongsWithPlaylistArtwork(songs, playlist: playlist)
                    guard !playableSongs.isEmpty else { return }

                    // Defer Smart Shuffle suggestions until the whole playlist is in the queue, so
                    // they dedup against the full set; re-shuffle the complete set on finish. The
                    // load generation is established before playback's first suspension so the premature
                    // fill cannot slip through.
                    let willDeferLoad = response.continuationToken != nil
                    let loadGeneration = await playerService.playQueue(
                        playableSongs, startingAt: 0, deferringSmartShuffleFill: willDeferLoad
                    )
                    DiagnosticsLogger.ui.info("Playing playlist '\(playlist.title)' (\(playableSongs.count) initial songs)")

                    guard let loadGeneration else { return }

                    await self.appendContinuations(
                        ContinuationContext(
                            continuationToken: response.continuationToken,
                            loadGeneration: loadGeneration,
                            playlist: playlist,
                            requiresAuth: response.detail.requiresPersonalAccountForContinuations,
                            client: client,
                            playerService: playerService
                        )
                    )
                    // Stand down if a different playback superseded this load while it paged.
                    guard playerService.isCurrentQueueLoad(loadGeneration) else { return }
                    await playerService.endQueueLoading(loadGeneration)
                    return
                }

                let playableSongs = self.playableSongsWithPlaylistArtwork(songs, playlist: playlist)
                guard !playableSongs.isEmpty else { return }

                await playerService.playQueue(playableSongs, startingAt: 0)
                DiagnosticsLogger.ui.info("Playing playlist '\(playlist.title)' (\(playableSongs.count) songs)")
            } catch {
                DiagnosticsLogger.ui.error("Failed to play playlist: \(error.localizedDescription)")
            }
        }
    }

    static func isRadioPlaylist(_ playlistId: String) -> Bool {
        playlistId.contains("RDCLAK") || playlistId.hasPrefix("RD")
    }

    static func tracksForPlaylistPlayback(browseTracks: [Song], queueTracks: [Song]) -> [Song] {
        var browsePlayabilityByVideoId: [String: Bool] = [:]
        for track in browseTracks {
            browsePlayabilityByVideoId[track.videoId] = track.isPlayable
        }

        return queueTracks.map { track in
            guard let browseIsPlayable = browsePlayabilityByVideoId[track.videoId],
                  browseIsPlayable != track.isPlayable
            else {
                return track
            }

            return self.copy(
                track,
                thumbnailURL: track.thumbnailURL,
                isPlayable: browseIsPlayable
            )
        }
    }

    static func playableSongsWithPlaylistArtwork(_ songs: [Song], playlist: Playlist) -> [Song] {
        songs.filter(\.isPlayable).map { song in
            self.copy(
                song,
                thumbnailURL: song.thumbnailURL ?? playlist.thumbnailURL,
                isPlayable: song.isPlayable
            )
        }
    }

    /// Returns full-playlist tracks that were not already put in the initial queue.
    /// Uses occurrence counts per video ID so authored duplicates remain intact while
    /// user removals from the playlist do not shift a fragile numeric offset.
    static func remainingTracks(after initialTracks: [Song], in fullTracks: [Song]) -> [Song] {
        var unmatchedInitialCounts: [String: Int] = [:]
        for track in initialTracks {
            unmatchedInitialCounts[self.playlistOccurrenceIdentity(for: track), default: 0] += 1
        }

        return fullTracks.filter { track in
            let identity = self.playlistOccurrenceIdentity(for: track)
            guard let remainingCount = unmatchedInitialCounts[identity], remainingCount > 0 else {
                return true
            }
            if remainingCount == 1 {
                unmatchedInitialCounts.removeValue(forKey: identity)
            } else {
                unmatchedInitialCounts[identity] = remainingCount - 1
            }
            return false
        }
    }

    @MainActor
    static func appendContinuations(_ context: ContinuationContext) async {
        var nextContinuation = context.continuationToken

        while let c = nextContinuation, !Task.isCancelled {
            do {
                let response = try await context.client.getPlaylistContinuation(
                    token: c,
                    requiresAuth: context.requiresAuth
                )
                guard !response.tracks.isEmpty else { break }

                let playableSongs = Self.playableSongsWithPlaylistArtwork(response.tracks, playlist: context.playlist)
                if !playableSongs.isEmpty {
                    // Tolerate user edits (remove/reorder) within the same playback; only discard if a
                    // *different* playback superseded this load (which bumps the load generation).
                    guard context.playerService.isCurrentQueueLoad(context.loadGeneration) else {
                        DiagnosticsLogger.ui.debug("Discarding playlist continuations because a new playback started")
                        return
                    }
                    context.playerService.appendOriginalTracks(playableSongs)
                }

                nextContinuation = response.continuationToken
            } catch {
                DiagnosticsLogger.ui.debug("Stopped loading playlist continuations: \(error.localizedDescription)")
                break
            }
        }
    }

    private static func copy(
        _ song: Song,
        thumbnailURL: URL?,
        isPlayable: Bool
    ) -> Song {
        let carried = song.feedbackTokens
        return Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            album: song.album,
            duration: song.duration,
            thumbnailURL: thumbnailURL,
            videoId: song.videoId,
            isPlayable: isPlayable,
            hasVideo: song.hasVideo,
            musicVideoType: song.musicVideoType,
            likeStatus: song.likeStatus,
            isInLibrary: song.isInLibrary,
            feedbackTokens: carried,
            isExplicit: song.isExplicit,
            playlistSetVideoId: song.playlistSetVideoId
        )
    }

    private static func playlistOccurrenceIdentity(for song: Song) -> String {
        if let setVideoId = song.playlistSetVideoId, !setVideoId.isEmpty {
            return "set:\(setVideoId)"
        }
        return "video:\(song.videoId)"
    }
}
