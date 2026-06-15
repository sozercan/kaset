import SwiftUI

/// Watch history: a paged list of video rows.
struct YouTubeHistoryView: View {
    let viewModel: YouTubeHistoryViewModel

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
                if self.viewModel.videos.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No history"), systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Videos you watch appear here.", comment: "Empty YouTube history description")
                    }
                } else {
                    self.historyList
                }
            }
        }
        .navigationTitle(Text("History", comment: "YouTube history title"))
        .task {
            await self.viewModel.load()
        }
    }

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    private var historyList: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(self.viewModel.videos) { video in
                    NavigationLink(value: YouTubeRoute.watch(video)) {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.interactiveCard)
                }

                if self.viewModel.hasMoreVideos {
                    ProgressView()
                        .controlSize(.small)
                        .task {
                            await self.viewModel.loadMore()
                        }
                }
            }
            .padding(.vertical, 20)
        }
        // Edge-to-edge with a resting inset so the grid extends under the
        // floating glass sidebar.
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
    }
}
