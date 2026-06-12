import SwiftUI

// MARK: - YouTubeShortsView

/// Dedicated Shorts surface: a grid of vertical (9:16) cards.
struct YouTubeShortsView: View {
    let viewModel: YouTubeShortsViewModel

    private static let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 14),
    ]

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
                if self.viewModel.shorts.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Shorts right now"), systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                    } description: {
                        Text("Shorts from your feed appear here.", comment: "Empty Shorts surface description")
                    }
                } else {
                    self.shortsGrid
                }
            }
        }
        .navigationTitle(Text("Shorts", comment: "YouTube Shorts title"))
        .task {
            await self.viewModel.load()
        }
    }

    private var shortsGrid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 18) {
                ForEach(self.viewModel.shorts) { short in
                    NavigationLink(value: YouTubeRoute.watch(short)) {
                        ShortCard(short: short)
                    }
                    .buttonStyle(.interactiveCard)
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.shortsGrid)
    }
}

// MARK: - ShortCard

/// Vertical 9:16 card for a Short.
private struct ShortCard: View {
    let short: YouTubeVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(
                url: self.short.thumbnailURL,
                targetSize: CGSize(width: 360, height: 640)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.tertiary)
                    }
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 10))

            Text(self.short.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let viewCountText = self.short.viewCountText {
                Text(viewCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let shortsGrid = "youtubeContent.shortsGrid"
}
