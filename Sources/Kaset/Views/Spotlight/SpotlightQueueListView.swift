import SwiftUI

/// Reorderable up-next queue manager view for Spotlight presentation mode.
struct SpotlightQueueListView: View {
    @Binding var queueSongs: [Song]
    let currentSong: Song?
    let onSelectSong: (Song) -> Void
    let onRemoveSong: (IndexSet) -> Void
    let onMoveSong: (IndexSet, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Stats
            HStack {
                Text("UP NEXT")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(self.queueSongs.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            List {
                // Now Playing Current Track Section
                if let song = self.currentSong {
                    Section(header: Text("NOW PLAYING").font(.caption2)) {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
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

                // Queue Tracks Reorderable Section
                Section(header: Text("QUEUE LIST").font(.caption2)) {
                    ForEach(Array(self.queueSongs.enumerated()), id: \.element.id) { index, song in
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

                            Image(systemName: "line.3.horizontal")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.onSelectSong(song)
                        }
                    }
                    .onDelete(perform: self.onRemoveSong)
                    .onMove(perform: self.onMoveSong)
                }
            }
            .listStyle(.sidebar)
        }
    }
}
