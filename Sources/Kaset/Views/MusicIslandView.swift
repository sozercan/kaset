import SwiftUI

/// A floating Dynamic Island-style view for displaying playback info and lyrics.
@available(macOS 26.0, *)
struct MusicIslandView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var lyricsService

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Album Art
            if let url = self.playerService.currentTrack?.thumbnailURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        CassetteIcon(size: 48)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                CassetteIcon(size: 64)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let line = self.currentLyricLine {
                    Text(line.text.isEmpty ? "♪" : line.text)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: line.text)
                    
                    if let romaji = line.romanizedText {
                        Text(romaji)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: romaji)
                    }
                } else {
                    Text(self.playerService.currentTrack?.title ?? "Kaset")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    Text(self.playerService.currentTrack?.artistsDisplay ?? "Not Playing")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 24) // Anchor text below the notch so it safely grows downwards

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12) // Smaller top padding so the thumbnail can expand upwards
        .padding(.bottom, 16)
        .frame(minWidth: 200, idealWidth: 320, maxWidth: 450)
        // Absolute black to blend with physical notch
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous)
                .fill(.black)
                .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 8)
        )
        .overlay(alignment: .topTrailing) {
            if self.isHovered {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .transition(.scale.combined(with: .opacity))
                    .padding(.top, 16)
                    .padding(.trailing, 16)
            }
        }
        // Add outer padding to give room for the shadow in the window bounds
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isHovered = hovering
            }
        }
        .onTapGesture {
            self.bringAppToFront()
        }
        .task(id: self.playerService.currentTrack?.videoId) {
            if let videoId = self.playerService.currentTrack?.videoId {
                await self.fetchLyrics(for: videoId)
            }
        }
        .onChange(of: self.lyricsService.currentLyrics) { _, newLyrics in
            self.updateLyricsPolling(for: newLyrics)
        }
        .onDisappear {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
        .onAppear {
            self.updateLyricsPolling(for: self.lyricsService.currentLyrics)
        }
    }

    private func updateLyricsPolling(for result: LyricResult) {
        if case .synced = result {
            SingletonPlayerWebView.shared.startLyricsPoll()
        } else {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
    }

    private func fetchLyrics(for videoId: String) async {
        guard let track = self.playerService.currentTrack, track.videoId == videoId else { return }
        
        let info = LyricsSearchInfo(
            title: track.title,
            artist: track.artistsDisplay,
            album: track.album?.title,
            duration: track.duration,
            videoId: track.videoId
        )
        
        if SettingsManager.shared.syncedLyricsEnabled {
            await self.lyricsService.fetchLyrics(for: info)
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
