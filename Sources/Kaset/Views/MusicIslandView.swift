import SwiftUI

/// A floating Dynamic Island-style view for displaying playback info and lyrics.
@available(macOS 26.0, *)
struct MusicIslandView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var lyricsService

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Album Art
            if let url = self.playerService.currentTrack?.thumbnailURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        CassetteIcon(size: 28)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                CassetteIcon(size: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let line = self.currentLyricLine {
                    Text(line.text.isEmpty ? "♪" : line.text)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: line.text)
                    
                    if let romaji = line.romanizedText {
                        Text(romaji)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: romaji)
                    }
                } else {
                    Text(self.playerService.currentTrack?.title ?? "Kaset")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    Text(self.playerService.currentTrack?.artistsDisplay ?? "Not Playing")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            
            if self.isHovered {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 200, idealWidth: 320, maxWidth: 450)
        // Liquid glass effect for macOS 26+
        .background(.black.opacity(0.6))
        .background(Material.ultraThin)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isHovered = hovering
            }
        }
        .onTapGesture {
            self.bringAppToFront()
        }
    }

    private var currentLyricLine: SyncedLyricLine? {
        guard case let .synced(syncedLyrics) = self.lyricsService.currentLyrics else {
            return nil
        }
        let currentTime = self.playerService.currentTimeMs
        if let idx = syncedLyrics.currentLineIndex(at: currentTime) {
            return syncedLyrics.lines[idx]
        }
        return nil
    }

    private func bringAppToFront() {
        for window in NSApplication.shared.windows where window.frameAutosaveName == "KasetMainWindow" {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        
        // Fallback
        for window in NSApplication.shared.windows where window.canBecomeMain {
            if window.identifier?.rawValue == AccessibilityID.VideoWindow.container { continue }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
    }
}
