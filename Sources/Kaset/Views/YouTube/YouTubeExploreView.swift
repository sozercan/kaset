import SwiftUI

// MARK: - YouTubeExploreView

/// Explore surface: public destination feeds (Gaming, News, Sports, …) —
/// YouTube's successors to the retired Trending page.
struct YouTubeExploreView: View {
    @Bindable var viewModel: YouTubeExploreViewModel

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Category"), selection: self.$viewModel.selectedDestination) {
                ForEach(YouTubeDestination.allCases) { destination in
                    Text(destination.displayName).tag(destination)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.exploreCategory)

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
                            Label(String(localized: "Nothing here right now"), systemImage: "globe")
                        }
                    } else {
                        self.grid
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text("Explore", comment: "YouTube explore title"))
        .task(id: self.viewModel.selectedDestination) {
            await self.viewModel.load()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(self.viewModel.videos) { video in
                    NavigationLink(value: YouTubeRoute.watch(video)) {
                        VideoCard(video: video)
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

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let exploreCategory = "youtubeContent.exploreCategory"
}
