import SwiftUI
import WebKit

// MARK: - VideoPlayerWindow

/// Floating Picture-in-Picture style window for video playback.
@available(macOS 26.0, *)
struct VideoPlayerWindow: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        // Video content (WebView container) with native HTML5 controls
        VideoWebViewContainer()
            .background(.black)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(minWidth: 320, minHeight: 180)
    }
}

// MARK: - VideoWebViewContainer

/// NSViewRepresentable container for the video WebView.
struct VideoWebViewContainer: NSViewRepresentable {
    func makeNSView(context _: Context) -> VideoContainerView {
        let container = VideoContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: VideoContainerView, context _: Context) {
        // Reparent the WebView into this container for video display
        SingletonPlayerWebView.shared.ensureInHierarchy(container: nsView)
    }
}

// MARK: - VideoContainerView

/// Custom NSView that observes frame changes and re-injects CSS.
final class VideoContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func frameDidChange(_: Notification) {
        // Debounce: re-inject CSS after resize settles
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.reinjectCSS), object: nil)
        self.perform(#selector(self.reinjectCSS), with: nil, afterDelay: 0.1)
    }

    @objc private func reinjectCSS() {
        // Re-inject video mode CSS to fix layout after resize
        if SingletonPlayerWebView.shared.displayMode == .video {
            SingletonPlayerWebView.shared.refreshVideoModeCSS()
        }
    }

    deinit {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - VideoControlsOverlay

/// Detailed playback controls overlay for the video window.
@available(macOS 26.0, *)
struct VideoControlsOverlay: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with time display
            HStack {
                Text(self.formatTime(self.playerService.progress))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()

                Text(self.formatTime(self.playerService.duration))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Spacer()

            // Center controls
            HStack(spacing: 40) {
                // Shuffle
                Button {
                    self.playerService.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(self.playerService.shuffleEnabled ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle")

                // Previous
                Button {
                    Task { await self.playerService.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous track")

                // Play/Pause (larger)
                Button {
                    Task { await self.playerService.playPause() }
                } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 56, height: 56)
                        .overlay {
                            Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.black)
                                .contentTransition(.symbolEffect(.replace))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(self.playerService.isPlaying ? "Pause" : "Play")

                // Next
                Button {
                    Task { await self.playerService.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")

                // Repeat
                Button {
                    self.playerService.cycleRepeatMode()
                } label: {
                    Image(systemName: self.repeatIconName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(self.playerService.repeatMode != .off ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Repeat")
            }

            Spacer()

            // Bottom bar with close button
            HStack {
                Spacer()

                // Close video
                Button {
                    self.playerService.showVideo = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close video")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.4)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var repeatIconName: String {
        switch self.playerService.repeatMode {
        case .off, .all:
            "repeat"
        case .one:
            "repeat.1"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", secs))"
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    VideoPlayerWindow()
        .environment(PlayerService())
        .frame(width: 480, height: 270)
}
