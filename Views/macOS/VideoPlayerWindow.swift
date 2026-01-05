import SwiftUI
import WebKit

// MARK: - VideoPlayerWindow

/// Floating Picture-in-Picture style window for video playback.
@available(macOS 26.0, *)
struct VideoPlayerWindow: View {
    @Environment(PlayerService.self) private var playerService

    @State private var isHovering = false

    var body: some View {
        ZStack {
            // Video content (WebView container)
            VideoWebViewContainer()
                .background(.black)

            // Controls overlay (shown on hover)
            if self.isHovering {
                VideoControlsOverlay()
                    .transition(.opacity)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(minWidth: 320, minHeight: 180)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovering = hovering
            }
        }
    }
}

// MARK: - VideoWebViewContainer

/// NSViewRepresentable container for the video WebView.
struct VideoWebViewContainer: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        // Reparent the WebView into this container for video display
        SingletonPlayerWebView.shared.ensureInHierarchy(container: nsView)
    }
}

// MARK: - VideoControlsOverlay

/// Minimal playback controls overlay for the video window.
@available(macOS 26.0, *)
struct VideoControlsOverlay: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 24) {
                // Previous
                Button {
                    Task { await self.playerService.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous track")

                // Play/Pause
                Button {
                    Task { await self.playerService.playPause() }
                } label: {
                    Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(self.playerService.isPlaying ? "Pause" : "Play")

                // Next
                Button {
                    Task { await self.playerService.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")

                Spacer()

                // Close video
                Button {
                    self.playerService.showVideo = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close video")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
            .padding()
        }
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    VideoPlayerWindow()
        .environment(PlayerService())
        .frame(width: 480, height: 270)
}
