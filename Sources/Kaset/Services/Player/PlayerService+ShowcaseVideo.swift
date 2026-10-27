import Foundation

// MARK: - ResolvedShowcaseMusicVideo

/// The music video located for a track: its videoId plus the recording's own
/// title/duration when the search surfaced them. Companion pairing carries
/// only an id; a search result carries the recording's real metadata (a live
/// MV differs from the studio track), which the lyrics stack needs to key its
/// recording match.
struct ResolvedShowcaseMusicVideo {
    let videoId: String
    let title: String?
    let duration: TimeInterval?
}

// MARK: - Showcase Video Source Swap

@MainActor
extension PlayerService {
    /// Toggles the showcase's music-video surface in place.
    ///
    /// Port of YouTube Music's own Song/Video switch: the same playing occurrence
    /// stops the audio-version stream and loads the official music video (OMV) of
    /// the same track at the aligned position; toggling back loads the audio
    /// recording and lines the position up again. No video window and no second
    /// playback stream is involved. YT Music pairs the two versions server-side
    /// (`next` wraps each av-switchable queue row in a
    /// `playlistPanelVideoWrapperRenderer` whose `counterpart` carries the sibling
    /// version), and its player requests differ only by `videoId` — verified with
    /// `api-explorer videomode-diff`.
    func toggleNowPlayingVideo() async {
        // A dismissal may still be in flight from a rapid re-toggle; wait it out
        // so the two play() calls cannot interleave (max ~1s, bounded).
        var waits = 0
        while self.isDismissingShowcaseVideoSurface, waits < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waits += 1
        }
        if self.showNowPlayingVideo {
            await self.dismissShowcaseVideoSurface()
            return
        }
        guard self.showNowPlayingShowcase,
              self.canShowCurrentTrackVideo,
              let track = self.currentTrack
        else { return }
        if self.isMiniPlayerVisible {
            self.closeMiniPlayer(restoringMainWindow: false)
        }
        // The floating video window cannot keep hosting while the showcase takes over.
        self.showVideo = false
        await self.beginShowcaseVideoSource(for: track)
    }

    /// Loads the official music video of `track` in place of the audio version.
    /// Returns whether video mode was entered; `false` means no MV resolved.
    @discardableResult
    private func beginShowcaseVideoSource(for track: Song) async -> Bool {
        let loadedVideoId = SingletonPlayerWebView.shared.currentVideoId

        // Hosting the current stream in place requires REAL evidence that the
        // loaded stream itself carries video: it is the OMV-typed track's own
        // stream, or the WebView reports actual video dimensions for the media
        // element. Availability flags (`currentTrackHasVideo`, `hasVideo`) only
        // mean a video counterpart exists — for an audio recording the loaded
        // stream is audio-only (observed videoWidth/videoHeight == 0, traced on
        // WFRB9zl8tS8), and an ATV stream is a static image. Without this
        // evidence the MV version is force-loaded below; there is no mechanism
        // that switches the loaded audio stream to video on its own.
        let loadedStreamCarriesVideo: Bool = if loadedVideoId == track.videoId, track.musicVideoType?.hasVideoContent == true {
            true
        } else if loadedVideoId == track.videoId,
                  track.musicVideoType != .atv,
                  track.musicVideoType != .podcastEpisode
        {
            await SingletonPlayerWebView.shared.loadedStreamHasVideoContent()
        } else {
            false
        }
        // Revalidate after the async probe: the user may have toggled off,
        // closed the showcase, or moved to another track while it ran.
        guard self.showNowPlayingShowcase,
              !self.isDismissingShowcaseVideoSurface,
              self.currentTrack?.videoId == track.videoId
        else { return false }
        if loadedStreamCarriesVideo {
            let audioSong = Self.audioVariant(of: track)
            if audioSong.videoId != track.videoId {
                self.showcaseVideoSourceSwap = ShowcaseVideoSourceSwap(
                    entryID: self.queueEntryIDOwningCurrentPlayback,
                    audioSong: audioSong,
                    videoSong: track
                )
            }
            self.showNowPlayingVideo = true
            self.videoWindowDidOpen()
            return true
        }

        let resolvedMusicVideo: ResolvedShowcaseMusicVideo? = if track.musicVideoType == .omv {
            // The track itself is the music video; its own metadata is the
            // recording's metadata.
            .init(videoId: track.videoId, title: nil, duration: nil)
        } else {
            await self.locateOfficialMusicVideo(for: track)
        }
        guard let resolvedMusicVideo else {
            // Permanent record: a TV press that resolves no MV is a user-visible
            // dead button, so the reason must be findable in diagnostics.
            self.logger.warning(
                "Showcase video: no music video resolved for \(track.videoId) (type \(track.musicVideoType?.rawValue ?? "nil"), companion: \(track.companionMusicVideoId ?? "none"), search unavailable: \(self.ytMusicClient == nil)); TV keeps the artwork"
            )
            return false
        }

        // Revalidate after the async lookup: the user may have selected another
        // queue row (or closed the showcase) while the MV was being located.
        // Overwriting the new selection's queue row or restarting playback on a
        // stale track would be worse than not toggling.
        guard self.showNowPlayingShowcase,
              self.currentTrack?.videoId == track.videoId
        else {
            self.logger.info("Showcase video: dropping stale swap for \(track.videoId); playback moved on during lookup")
            return false
        }

        let videoSong = Self.videoVariant(of: track, musicVideo: resolvedMusicVideo)
        let audioSong = Self.audioVariant(of: track)

        if loadedVideoId == videoSong.videoId {
            // The video version is already loaded: host it without a swap. The
            // swap state still records the audio version for the way back.
            if audioSong.videoId != videoSong.videoId {
                self.showcaseVideoSourceSwap = ShowcaseVideoSourceSwap(
                    entryID: self.queueEntryIDOwningCurrentPlayback,
                    audioSong: audioSong,
                    videoSong: videoSong
                )
            }
            self.showNowPlayingVideo = true
            self.videoWindowDidOpen()
            return true
        }

        let entryID = self.queueEntryIDOwningCurrentPlayback
        let swap = ShowcaseVideoSourceSwap(
            entryID: entryID,
            audioSong: audioSong,
            videoSong: videoSong
        )
        if let entryID {
            self.replaceQueueEntrySong(entryID: entryID, with: videoSong)
        }
        self.showcaseVideoSourceSwap = swap
        self.showNowPlayingVideo = true
        self.videoWindowDidOpen()
        // Capture playback state NOW, not at function entry: the dimension
        // probe and MV lookup awaited above can span a pause or seek, and a
        // stale snapshot would clobber the user's state.
        let wasPaused = self.state == .paused
        // Clamp against the old stream's duration so a late-duration read cannot
        // seek past the end of the NEW stream (versions of different cuts can
        // differ by more than the ~0.5s tail).
        let alignedProgress = min(self.progress, max(self.duration - 2, 0))
        let alignedDuration = self.duration
        let intent = self.beginMusicPlaybackIntent()
        await self.play(
            song: videoSong,
            webLoadStrategy: .standard,
            queueEntryID: entryID,
            startsPaused: wasPaused,
            restoreClock: MusicPlaybackRestoreClock(
                progress: alignedProgress,
                duration: alignedDuration
            ),
            intent: intent
        )
        return true
    }

    /// Dismisses the video surface (toggle-off, showcase close, window close) and
    /// swaps the loaded stream back to the audio recording at the aligned position.
    /// Single-flight: concurrent dismissal requests (didSets + user clicks) collapse
    /// into the first run.
    func dismissShowcaseVideoSurface() async {
        self.showcaseVideoAdvanceContinuation?.cancel()
        self.showcaseVideoAdvanceContinuation = nil
        guard !self.isDismissingShowcaseVideoSurface else { return }
        self.isDismissingShowcaseVideoSurface = true
        defer { self.isDismissingShowcaseVideoSurface = false }

        let swap = self.showcaseVideoSourceSwap
        self.showcaseVideoSourceSwap = nil
        self.showNowPlayingVideo = false

        // OMV-row fallback: the loaded stream already is the music video, so the
        // audio recording comes from the track's own pairing fields.
        let track = self.currentTrack
        let audioSong: Song? = if swap != nil {
            swap?.audioSong
        } else {
            track.flatMap { track in
                track.preferredAudioVideoId != track.videoId ? Self.audioVariant(of: track) : nil
            }
        }

        guard let audioSong,
              SingletonPlayerWebView.shared.currentVideoId != audioSong.videoId
        else { return }

        let wasPaused = self.state == .paused
        // Same clamp as the swap-in path: never restore a seek past the end.
        let alignedProgress = min(self.progress, max(self.duration - 2, 0))
        let alignedDuration = self.duration
        let entryID = self.queueEntryIDOwningCurrentPlayback ?? swap?.entryID
        if let entryID {
            self.replaceQueueEntrySong(entryID: entryID, with: audioSong)
            self.saveQueueForPersistence()
        }
        let intent = self.beginMusicPlaybackIntent()
        await self.play(
            song: audioSong,
            webLoadStrategy: .standard,
            queueEntryID: entryID,
            startsPaused: wasPaused,
            restoreClock: MusicPlaybackRestoreClock(
                progress: alignedProgress,
                duration: alignedDuration
            ),
            intent: intent
        )
    }

    /// Passive cleanup for dismissal paths that run from synchronous didSets.
    func dismissShowcaseVideoSurfaceIfNeeded() {
        guard self.showNowPlayingVideo || self.showcaseVideoSourceSwap != nil else { return }
        Task { await self.dismissShowcaseVideoSurface() }
    }

    /// Keeps the showcase video surface up across an automatic track advance.
    ///
    /// The track-change didSet fires while the advance pipeline is still loading
    /// the next track's own version; loading the MV here would interleave with
    /// that navigation and double-load. The continuation therefore waits for a
    /// deterministic settle signal — `currentVideoId` matching the new track
    /// (set synchronously by `loadVideo` when the advance's navigation commits,
    /// and by observations for web-driven advances) and the load no longer being
    /// in the `.loading` state — then force-loads the MV version exactly like a
    /// TV press, with the fresh track's own clock (~0). Every await revalidates:
    /// a toggle-off, showcase close, or newer advance supersedes the
    /// continuation. A bounded wait covers a failed advance load: the dead
    /// surface falls back to artwork instead of lingering black.
    func continueShowcaseVideoAfterAdvance(for track: Song) {
        self.showcaseVideoAdvanceContinuation?.cancel()
        self.showcaseVideoAdvanceContinuation = Task { @MainActor [weak self] in
            await self?.runShowcaseVideoAdvanceContinuation(for: track)
        }
    }

    private func runShowcaseVideoAdvanceContinuation(for track: Song) async {
        var waits = 0
        while SingletonPlayerWebView.shared.currentVideoId != track.videoId
            || self.state == .loading, waits < 100
        {
            waits += 1
            if Task.isCancelled {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            // ponytail: 50ms predicate poll (≤5s) instead of an observation
            // hook into the advance pipeline; replace with a load-completion
            // callback if the poll ever shows up in traces.
            guard self.showNowPlayingVideo,
                  self.showNowPlayingShowcase,
                  self.currentTrack?.videoId == track.videoId
            else { return }
        }
        guard !Task.isCancelled,
              self.showNowPlayingVideo,
              self.showNowPlayingShowcase,
              self.currentTrack?.videoId == track.videoId
        else { return }
        if SingletonPlayerWebView.shared.currentVideoId != track.videoId {
            // The advance's stream never landed; a dead video surface is worse
            // than artwork, so fall back gracefully.
            self.dismissShowcaseVideoSurfaceIfNeeded()
            return
        }
        let entered = await self.beginShowcaseVideoSource(for: track)
        if !entered, self.currentTrack?.videoId == track.videoId {
            // No resolvable MV for the new track: back to artwork while the
            // advance's audio version keeps playing.
            self.dismissShowcaseVideoSurfaceIfNeeded()
        }
    }

    /// Restores the swapped queue row to its audio song without touching playback.
    /// Used when playback advances on its own while a swap is active.
    func revertShowcaseVideoSwapEntry() {
        guard let swap = self.showcaseVideoSourceSwap else { return }
        self.showcaseVideoSourceSwap = nil
        guard let entryID = swap.entryID else { return }
        self.replaceQueueEntrySong(entryID: entryID, with: swap.audioSong)
        self.saveQueueForPersistence()
    }

    /// Locates the official music video for an audio-version track.
    /// Resolution order: the server-paired counterpart from the `next` endpoint
    /// (`companionMusicVideoId`), then a keyless YouTube videos search.
    private func locateOfficialMusicVideo(for track: Song) async -> ResolvedShowcaseMusicVideo? {
        if let companion = track.companionMusicVideoId {
            return .init(videoId: companion, title: nil, duration: nil)
        }
        guard let client = self.ytMusicClient else { return nil }
        let query = ([track.title] + track.artists.map(\.name)).joined(separator: " ")
        guard let response = try? await client.searchVideos(query: query) else { return nil }
        // ponytail: naive title heuristic (case/diacritic fold + parenthetical
        // strip); replace with duration/album corroboration if mismatches surface.
        let titleKey = Self.normalizedTitleKey(track.title)
        let video = response.videos.first { candidate in
            guard candidate.musicVideoType == .omv else { return false }
            let candidateKey = Self.normalizedTitleKey(candidate.title)
            return candidateKey == titleKey
                || candidateKey.hasPrefix(titleKey)
                || titleKey.hasPrefix(candidateKey)
        }
        return video.map {
            // The search result carries the recording's real title and
            // duration (a live version differs from the studio track) — the
            // lyrics stack keys its recording match off these.
            .init(videoId: $0.videoId, title: $0.title, duration: $0.duration)
        }
    }

    static func normalizedTitleKey(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The music-video variant of `track`, keeping the song's own identity. When
    /// the recording's real title/duration are known (search-resolved MVs), they
    /// replace the studio track's so lyrics matching keys to the recording.
    static func videoVariant(of track: Song, musicVideo: ResolvedShowcaseMusicVideo) -> Song {
        Song(
            id: musicVideo.videoId,
            title: musicVideo.title ?? track.title,
            artists: track.artists,
            album: track.album,
            duration: musicVideo.duration ?? track.duration,
            thumbnailURL: track.thumbnailURL,
            videoId: musicVideo.videoId,
            isPlayable: track.isPlayable,
            hasVideo: true,
            musicVideoType: .omv,
            likeStatus: track.likeStatus,
            isInLibrary: track.isInLibrary,
            feedbackTokens: track.feedbackTokens,
            isExplicit: track.isExplicit,
            playlistSetVideoId: track.playlistSetVideoId,
            audioTrackVideoId: track.preferredAudioVideoId,
            companionMusicVideoId: nil
        )
    }

    /// The audio-recording variant of `track`. The restored song must NOT claim
    /// OMV metadata (or the next TV press would host the audio stream as video
    /// again), and it must carry the OMV as its companion so the next toggle
    /// finds it without a search.
    static func audioVariant(of track: Song) -> Song {
        let audioId = track.preferredAudioVideoId
        guard audioId != track.videoId else { return track }
        let sourceClaimsVideo = track.musicVideoType?.hasVideoContent == true
        return Song(
            id: audioId,
            title: track.title,
            artists: track.artists,
            album: track.album,
            duration: track.duration,
            thumbnailURL: track.thumbnailURL,
            videoId: audioId,
            isPlayable: track.isPlayable,
            hasVideo: track.hasVideo,
            musicVideoType: sourceClaimsVideo ? .atv : track.musicVideoType,
            likeStatus: track.likeStatus,
            isInLibrary: track.isInLibrary,
            feedbackTokens: track.feedbackTokens,
            isExplicit: track.isExplicit,
            playlistSetVideoId: track.playlistSetVideoId,
            audioTrackVideoId: nil,
            companionMusicVideoId: sourceClaimsVideo
                ? track.videoId
                : track.companionMusicVideoId
        )
    }
}
