import SwiftUI

// MARK: - ShowcaseRecommendationsModel

@MainActor
@Observable
final class ShowcaseRecommendationsModel {
    private(set) var songs: [Song] = []
    private(set) var isLoading = false
    private(set) var hasError = false
    private var generation = 0

    /// Loads radio suggestions while ignoring results superseded by a newer track.
    func load(videoId: String?, client: any YTMusicClientProtocol) async {
        self.generation += 1
        let request = self.generation
        self.songs = []
        self.hasError = false
        self.isLoading = videoId != nil
        guard let videoId else { return }

        do {
            let songs = try await client.getRadioQueue(videoId: videoId)
            guard !Task.isCancelled, self.generation == request else { return }
            self.songs = PlayerService.dedupeSuggestions(songs, against: [videoId])
            self.isLoading = false
        } catch {
            guard !Task.isCancelled, self.generation == request else { return }
            self.isLoading = false
            self.hasError = true
        }
    }
}

// MARK: - ShowcaseRecommendationsView

struct ShowcaseRecommendationsView: View {
    @Environment(PlayerService.self) private var playerService
    let client: any YTMusicClientProtocol
    @State private var model = ShowcaseRecommendationsModel()
    @State private var retry = 0

    private var availableSongs: [Song] {
        PlayerService.dedupeSuggestions(self.model.songs, against: Set(self.playerService.queue.map(\.videoId)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(String(localized: "Recommendations"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Divider().opacity(0.3)

            if self.model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.model.hasError {
                VStack(spacing: 12) {
                    Text(String(localized: "Couldn't load recommendations."))
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Retry")) { self.retry += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.availableSongs.isEmpty {
                ContentUnavailableView(String(localized: "No recommendations yet"), systemImage: "sparkles")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(self.availableSongs, id: \.videoId) { song in
                            self.songRow(song)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task(id: "\(self.playerService.currentTrack?.videoId ?? "none"):\(self.retry)") {
            await self.model.load(videoId: self.playerService.currentTrack?.videoId, client: self.client)
        }
    }

    /// Provides playback and add-to-queue actions for one recommended song.
    private func songRow(_ song: Song) -> some View {
        HStack(spacing: 8) {
            Button {
                let intent = self.playerService.beginMusicPlaybackIntent()
                Task { await self.playerService.playWithRadio(song: song, intent: intent) }
            } label: {
                HStack(spacing: 12) {
                    SongThumbnailView(song: song, size: 40, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.body).lineLimit(1)
                        Text(song.artistsDisplay).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            Button {
                self.playerService.appendToQueue([song])
            } label: {
                Image(systemName: "text.badge.plus")
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Add to Queue")) // [VERIFY] confirm queue action label.
            .help(String(localized: "Add to Queue"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
