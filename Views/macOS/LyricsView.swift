import SwiftUI

/// Right sidebar panel displaying lyrics for the current track.
@available(macOS 26.0, *)
struct LyricsView: View {
    @Environment(PlayerService.self) private var playerService

    let client: any YTMusicClientProtocol

    @State private var lyrics: Lyrics?
    @State private var isLoading = false
    @State private var lastLoadedVideoId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            self.headerView

            Divider()

            // Content
            self.contentView
        }
        .frame(minWidth: 280, maxWidth: 280)
        .background(.background.opacity(0.95))
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            if let videoId = newVideoId, videoId != lastLoadedVideoId {
                Task {
                    await self.loadLyrics(for: videoId)
                }
            }
        }
        .task {
            if let videoId = playerService.currentTrack?.videoId {
                await self.loadLyrics(for: videoId)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Lyrics")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if self.isLoading {
            self.loadingView
        } else if let lyrics, lyrics.isAvailable {
            self.lyricsContentView(lyrics)
        } else {
            self.noLyricsView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading lyrics...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricsContentView(_ lyrics: Lyrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Lyrics text
                Text(lyrics.text)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(8)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)

                // Source attribution
                if let source = lyrics.source {
                    Divider()
                        .padding(.horizontal, 16)

                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var noLyricsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No Lyrics Available")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("There aren't any lyrics available for this song.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadLyrics(for videoId: String) async {
        self.isLoading = true
        self.lastLoadedVideoId = videoId

        do {
            let fetchedLyrics = try await client.getLyrics(videoId: videoId)
            // Only update if still relevant (user hasn't changed tracks)
            if self.playerService.currentTrack?.videoId == videoId {
                self.lyrics = fetchedLyrics
            }
        } catch {
            DiagnosticsLogger.api.error("Failed to load lyrics: \(error.localizedDescription)")
            self.lyrics = .unavailable
        }

        self.isLoading = false
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LyricsView(client: client)
        .environment(PlayerService())
        .frame(height: 600)
}
