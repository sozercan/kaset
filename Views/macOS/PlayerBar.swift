import SwiftUI

/// Player bar shown at the bottom of the main window.
struct PlayerBar: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            ZStack {
                HStack(spacing: 16) {
                    // Track info
                    trackInfo

                    Spacer()

                    // Playback controls
                    playbackControls

                    Spacer()

                    // Progress and volume
                    progressAndVolume
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)


            }
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Track Info

    @ViewBuilder
    private var trackInfo: some View {
        HStack(spacing: 12) {
            // Thumbnail
            AsyncImage(url: playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 48, height: 48)
            .clipShape(.rect(cornerRadius: 6))

            // Title and artist
            if let track = playerService.currentTrack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text(track.artistsDisplay.isEmpty ? "Unknown Artist" : track.artistsDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 200, alignment: .leading)
            } else {
                Text("Not Playing")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 200)
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 20) {
            Button {
                Task {
                    await playerService.previous()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous track")

            Button {
                Task {
                    await playerService.playPause()
                }
            } label: {
                Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerService.isPlaying ? "Pause" : "Play")

            Button {
                Task {
                    await playerService.next()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next track")
        }
    }

    // MARK: - Progress and Volume

    private var progressAndVolume: some View {
        HStack(spacing: 16) {
            // Progress
            HStack(spacing: 8) {
                Text(playerService.progress.formattedDuration)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { playerService.progress },
                        set: { newValue in
                            Task {
                                await playerService.seek(to: newValue)
                            }
                        }
                    ),
                    in: 0 ... max(1, playerService.duration)
                )
                .frame(width: 200)

                Text(playerService.duration.formattedDuration)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }

            // Volume
            HStack(spacing: 4) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Slider(
                    value: Binding(
                        get: { playerService.volume },
                        set: { newValue in
                            Task {
                                await playerService.setVolume(newValue)
                            }
                        }
                    ),
                    in: 0 ... 1
                )
                .frame(width: 80)
            }
        }
        .frame(minWidth: 350)
    }

    private var volumeIcon: String {
        if playerService.volume == 0 {
            "speaker.slash.fill"
        } else if playerService.volume < 0.5 {
            "speaker.wave.1.fill"
        } else {
            "speaker.wave.2.fill"
        }
    }
}
