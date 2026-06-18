import SwiftUI

/// The signed-in user's YouTube playlists.
struct YouTubePlaylistsView: View {
    let viewModel: YouTubePlaylistsViewModel

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView()
            case let .error(error):
                ErrorView(
                    title: error.title,
                    message: error.message,
                    isRetryable: error.isRetryable
                ) {
                    Task {
                        await self.viewModel.refresh()
                    }
                }
            case .loaded, .loadingMore:
                if self.viewModel.playlists.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No playlists"), systemImage: "list.and.film")
                    } description: {
                        Text("Playlists you create or save appear here.", comment: "Empty YouTube playlists description")
                    }
                } else {
                    self.playlistsList
                }
            }
        }
        .navigationTitle(Text("Playlists", comment: "YouTube playlists title"))
        // Keyed on the view-model identity so a cold-launch account swap (which
        // rebuilds the model) re-fires the load instead of leaving the fresh,
        // idle model stuck. See YouTubeHomeView for the full rationale.
        .task(id: ObjectIdentifier(self.viewModel)) {
            await self.viewModel.load()
        }
    }

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    private var playlistsList: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(self.viewModel.playlists) { playlist in
                    NavigationLink(value: YouTubeRoute.playlist(playlistId: playlist.playlistId)) {
                        YouTubePlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.interactiveCard)
                }
            }
            .padding(.vertical, 20)
        }
        // Edge-to-edge with a resting inset so the grid extends under the
        // floating glass sidebar.
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
    }
}
