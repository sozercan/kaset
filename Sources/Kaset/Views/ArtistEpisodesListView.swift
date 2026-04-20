import SwiftUI

/// View displaying the full list of episodes (or other filtered subset) behind
/// a `MUSIC_PAGE_TYPE_ARTIST` "See all" affordance — Latest episodes, Live
/// performances, etc.
@available(macOS 26.0, *)
struct ArtistEpisodesListView: View {
    @State var viewModel: ArtistEpisodesListViewModel
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading..."))
            case .loaded, .loadingMore:
                if self.viewModel.episodes.isEmpty {
                    ErrorView(
                        title: String(localized: "Nothing to show"),
                        message: String(localized: "This list is empty.")
                    ) {
                        Task { await self.viewModel.load() }
                    }
                } else {
                    self.listView(self.viewModel.episodes)
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .navigationTitle(self.viewModel.destination.sectionTitle)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
            }
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
    }

    private func listView(_ episodes: [ArtistEpisode]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(episodes) { episode in
                    self.episodeRow(episode)
                    Divider().padding(.leading, 24)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func episodeRow(_ episode: ArtistEpisode) -> some View {
        Button {
            Task { await self.playerService.playEpisode(episode) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                CachedAsyncImage(url: episode.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 90)
                .clipShape(.rect(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if episode.isLive {
                            HStack(spacing: 4) {
                                Circle().fill(.white).frame(width: 6, height: 6)
                                Text("LIVE", comment: "Live badge on artist episode list row")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .tracking(0.5)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: .capsule)
                        }
                        Text(episode.title)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(2)
                    }

                    if let subtitle = episode.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if let description = episode.description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
