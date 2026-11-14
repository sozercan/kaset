import SwiftUI

// MARK: - YouTubeFeedbackContextMenu

/// Adds YouTube's "Not interested" / "Don't recommend channel" entries to a
/// video card's context menu. Cards without feedback actions (signed out,
/// Continue Watching) get no menu.
struct YouTubeFeedbackContextMenu: ViewModifier {
    let video: YouTubeVideo
    let send: (YouTubeFeedbackAction) -> Void

    func body(content: Content) -> some View {
        if self.video.feedbackActions.isEmpty {
            content
        } else {
            content.contextMenu {
                ForEach(self.video.feedbackActions, id: \.kind) { action in
                    Button {
                        self.send(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            }
        }
    }
}

extension View {
    /// Attaches the recommendation-feedback context menu for `video`.
    func youtubeFeedbackContextMenu(
        for video: YouTubeVideo,
        send: @escaping (YouTubeFeedbackAction) -> Void
    ) -> some View {
        self.modifier(YouTubeFeedbackContextMenu(video: video, send: send))
    }
}

// MARK: - YouTubeFeedbackToastOverlay

/// Confirms a dismissal ("Video removed · Undo") and reports feedback
/// failures for the YouTube home feed.
struct YouTubeFeedbackToastOverlay: View {
    let viewModel: YouTubeHomeViewModel

    @State private var showsFailure = false

    /// Long enough to reach Undo after reading YouTube's confirmation text.
    private static let confirmationDuration: Duration = .seconds(10)
    private static let failureDuration: Duration = .seconds(4)

    var body: some View {
        VStack(spacing: 8) {
            if let dismissal = self.viewModel.lastDismissal {
                YouTubeFeedbackToast(dismissal: dismissal) {
                    Task {
                        await self.viewModel.undoLastDismissal()
                    }
                } dismiss: {
                    self.viewModel.clearLastDismissal(id: dismissal.id)
                }
                .task(id: dismissal.id) {
                    try? await Task.sleep(for: Self.confirmationDuration)
                    guard !Task.isCancelled else { return }
                    self.viewModel.clearLastDismissal(id: dismissal.id)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if self.showsFailure {
                ToastView(
                    message: String(localized: "Couldn't send feedback to YouTube."),
                    isError: true
                ) {
                    self.showsFailure = false
                }
                .task(id: self.viewModel.feedbackFailureCount) {
                    try? await Task.sleep(for: Self.failureDuration)
                    guard !Task.isCancelled else { return }
                    self.showsFailure = false
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 12)
        .animation(.spring(duration: 0.3), value: self.viewModel.lastDismissal?.id)
        .animation(.spring(duration: 0.3), value: self.showsFailure)
        .onChange(of: self.viewModel.feedbackFailureCount) { _, _ in
            self.showsFailure = true
        }
    }
}

// MARK: - YouTubeFeedbackToast

/// "Video removed · Undo" confirmation, using YouTube's own localized text.
private struct YouTubeFeedbackToast: View {
    let dismissal: YouTubeFeedbackDismissal
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: self.dismissal.action.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(self.dismissal.action.confirmationText ?? self.dismissal.action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                if self.dismissal.canUndo {
                    Button(self.dismissal.action.undoTitle ?? String(localized: "Undo"), action: self.undo)
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier(AccessibilityID.YouTubeContent.feedbackUndoButton)
                }

                Button(action: self.dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Dismiss"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minWidth: 250, maxWidth: 420)
            .compatGlass(in: .rect(cornerRadius: 10))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
        .compatGlassTransition(.materialize)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.feedbackToast)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let feedbackToast = "youtubeContent.feedbackToast"
    static let feedbackUndoButton = "youtubeContent.feedbackUndoButton"
}
