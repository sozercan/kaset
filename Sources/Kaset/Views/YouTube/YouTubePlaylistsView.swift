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
        .task {
            await self.viewModel.load()
        }
    }

    private var playlistsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(self.viewModel.playlists) { playlist in
                    NavigationLink(value: YouTubeRoute.playlist(playlistId: playlist.playlistId)) {
                        YouTubePlaylistRowView(playlist: playlist)
                    }
                    .buttonStyle(.interactiveRow)
                }
            }
            .padding(20)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }
}
