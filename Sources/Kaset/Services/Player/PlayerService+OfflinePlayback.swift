import AVFoundation
import Foundation

@MainActor
extension PlayerService {
    var isOfflinePlaybackActive: Bool {
        self.offlinePlaybackPlayer != nil
    }

    func startOfflinePlayback(song: Song, fileURL: URL) async {
        self.stopOfflinePlayback()

        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.volume = Float(self.volume)
            player.delegate = self
            player.prepareToPlay()

            self.offlinePlaybackPlayer = player
            self.pendingPlayVideoId = nil
            self.isKasetInitiatedPlayback = false
            self.showMiniPlayer = false
            self.state = .loading
            self.progress = 0
            self.currentTimeMs = 0
            self.duration = player.duration > 0 ? player.duration : (song.duration ?? 0)

            self.offlinePlaybackProgressTask = Task { @MainActor in
                while !Task.isCancelled, self.offlinePlaybackPlayer != nil {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let player = self.offlinePlaybackPlayer else { return }
                    self.progress = player.currentTime
                    self.currentTimeMs = Int((player.currentTime * 1000).rounded())
                    if player.isPlaying {
                        self.state = .playing
                    }
                }
            }

            guard player.play() else {
                self.stopOfflinePlayback()
                self.state = .error(String(localized: "Unable to start offline playback"))
                return
            }

            self.state = .playing
            if !self.hasUserInteractedThisSession {
                self.markUserInteractedThisSession()
            }
        } catch {
            self.state = .error(String(localized: "Unable to start offline playback"))
            DiagnosticsLogger.player.error(
                "Failed to start offline playback for \(song.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func stopOfflinePlayback() {
        self.offlinePlaybackProgressTask?.cancel()
        self.offlinePlaybackProgressTask = nil
        self.offlinePlaybackPlayer?.stop()
        self.offlinePlaybackPlayer = nil
    }

    func pauseOfflinePlayback() {
        self.offlinePlaybackPlayer?.pause()
        self.state = .paused
    }

    func resumeOfflinePlayback() {
        if self.state == .ended {
            self.seekOfflinePlayback(to: 0)
        }

        guard let player = self.offlinePlaybackPlayer else { return }
        player.play()
        self.state = .playing
    }

    func seekOfflinePlayback(to time: TimeInterval) {
        guard let player = self.offlinePlaybackPlayer else { return }
        let clampedTime = max(0, self.duration > 0 ? min(time, self.duration) : time)
        player.currentTime = clampedTime
        self.progress = clampedTime
        self.currentTimeMs = Int((clampedTime * 1000).rounded())
    }

    func setOfflinePlaybackVolume(_ value: Double) {
        let clampedValue = max(0, min(1, value))
        self.offlinePlaybackPlayer?.volume = Float(clampedValue)
    }
}

// MARK: - PlayerService + AVAudioPlayerDelegate

extension PlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        let playerIdentifier = ObjectIdentifier(player)
        Task { @MainActor in
            guard let currentPlayer = self.offlinePlaybackPlayer,
                  ObjectIdentifier(currentPlayer) == playerIdentifier
            else { return }
            await self.handleTrackEnded(observedVideoId: self.currentTrack?.videoId)
        }
    }
}
