import SwiftUI

/// Side drawer container inside Spotlight View for switching between Synced Lyrics and Queue tabs.
struct SpotlightSideDrawer: View {
    enum Tab: String, CaseIterable, Identifiable {
        case lyrics = "Lyrics"
        case queue = "Queue"

        var id: String {
            self.rawValue
        }

        var iconName: String {
            switch self {
            case .lyrics: "quote.bubble.fill"
            case .queue: "list.bullet.rectangle.portrait.fill"
            }
        }
    }

    @Binding var selectedTab: Tab
    let isVisible: Bool
    let lyricsText: String?
    let queueSongs: [Song]

    var body: some View {
        if self.isVisible {
            VStack(spacing: 16) {
                // Segmented tab selector
                Picker("Drawer View", selection: self.$selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.iconName)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Tab Content Body
                switch self.selectedTab {
                case .lyrics:
                    ScrollView {
                        if let lyrics = self.lyricsText, !lyrics.isEmpty {
                            Text(lyrics)
                                .font(.system(size: 18, weight: .medium))
                                .lineSpacing(10)
                                .multilineTextAlignment(.center)
                                .padding(20)
                        } else {
                            ContentUnavailableView(
                                "No Lyrics Available",
                                systemImage: "quote.bubble",
                                description: Text("Lyrics could not be loaded for the current track.")
                            )
                            .padding(.top, 40)
                        }
                    }
                case .queue:
                    List {
                        Section(header: Text("UP NEXT")) {
                            ForEach(Array(self.queueSongs.enumerated()), id: \.offset) { index, song in
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 20)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(song.title)
                                            .font(.body.weight(.medium))
                                            .lineLimit(1)

                                        Text(song.artists.map(\.name).joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(width: 340)
            .compatGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}
