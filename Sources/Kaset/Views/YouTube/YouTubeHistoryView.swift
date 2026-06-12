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

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(self.viewModel.videos) { video in
                    NavigationLink(value: YouTubeRoute.watch(video)) {
                        VideoRowView(video: video)
                    }
                    .buttonStyle(.interactiveRow)
                }

                if self.viewModel.hasMoreVideos {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .task {
                            await self.viewModel.loadMore()
                        }
                }
            }
            .padding(20)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }
}
