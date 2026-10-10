import SwiftUI

// MARK: - TrackCreditsAction

struct TrackCreditsAction: @unchecked Sendable {
    var present: ((Song) -> Void)?

    static let disabled = TrackCreditsAction()
}

extension EnvironmentValues {
    @Entry var trackCreditsAction: TrackCreditsAction = .disabled
}

// MARK: - TrackCreditsSheet

struct TrackCreditsSheet: View {
    let song: Song
    let client: any YTMusicClientProtocol

    @Environment(\.dismiss) private var dismiss
    @State private var loadState: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded(TrackCredits)
        case unavailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.header

            self.content
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)

            HStack {
                Spacer()
                Button(String(localized: "Done")) {
                    self.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task {
            await self.load()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SongThumbnailView(song: self.song, size: 48, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                if case let .loaded(credits) = self.loadState, let title = credits.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(self.song.title)
                    .font(.headline)
                    .lineLimit(2)
                if !self.song.artistsDisplay.isEmpty {
                    Text(self.song.artistsDisplay)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch self.loadState {
        case .loading:
            ProgressView(String(localized: "Loading…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            Text(String(localized: "Credits unavailable"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(credits):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(credits.sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ForEach(Array(section.names.enumerated()), id: \.offset) { _, name in
                                Text(name)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 360)
        }
    }

    private func load() async {
        do {
            let credits = try await self.client.getTrackCredits(videoId: self.song.preferredAudioVideoId)
            self.loadState = credits.isAvailable ? .loaded(credits) : .unavailable
        } catch is CancellationError {
            return
        } catch {
            DiagnosticsLogger.api.error("Failed to load track credits: \(error.localizedDescription)")
            self.loadState = .unavailable
        }
    }
}
