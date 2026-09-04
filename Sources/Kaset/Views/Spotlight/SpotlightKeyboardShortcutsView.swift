import SwiftUI

/// Keyboard shortcuts cheat sheet overlay view for Spotlight presentation mode.
struct SpotlightKeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    struct ShortcutItem: Identifiable {
        let id = UUID()
        let keyCombination: String
        let description: String
        let category: ShortcutCategory

        enum ShortcutCategory: String, CaseIterable {
            case playback = "Playback"
            case navigation = "Navigation"
            case viewMode = "View Controls"
        }
    }

    private let shortcuts: [ShortcutItem] = [
        ShortcutItem(keyCombination: "Space", description: "Toggle Play / Pause", category: .playback),
        ShortcutItem(keyCombination: "⌘ →", description: "Skip to Next Track", category: .playback),
        ShortcutItem(keyCombination: "⌘ ←", description: "Skip to Previous Track", category: .playback),
        ShortcutItem(keyCombination: "⌘ ↑", description: "Volume Up (+10%)", category: .playback),
        ShortcutItem(keyCombination: "⌘ ↓", description: "Volume Down (-10%)", category: .playback),
        ShortcutItem(keyCombination: "M", description: "Toggle Audio Mute", category: .playback),
        ShortcutItem(keyCombination: "L", description: "Toggle Synced Lyrics Side Drawer", category: .navigation),
        ShortcutItem(keyCombination: "Q", description: "Toggle Up-Next Queue Side Drawer", category: .navigation),
        ShortcutItem(keyCombination: "F", description: "Toggle Fullscreen Spotlight View", category: .viewMode),
        ShortcutItem(keyCombination: "Esc", description: "Dismiss Spotlight Presentation", category: .viewMode),
    ]

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Label("Spotlight Keyboard Shortcuts", systemImage: "command")
                    .font(.headline)
                Spacer()
                Button(action: { self.dismiss() }, label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                })
                .buttonStyle(.plain)
            }
            .padding([.top, .horizontal], 20)

            // Shortcuts List grouped by Category
            List {
                ForEach(ShortcutItem.ShortcutCategory.allCases, id: \.self) { category in
                    Section(header: Text(category.rawValue).font(.caption.weight(.bold))) {
                        ForEach(self.shortcuts.filter { $0.category == category }) { shortcut in
                            HStack {
                                Text(shortcut.description)
                                    .font(.body)
                                Spacer()
                                Text(shortcut.keyCombination)
                                    .font(.system(.subheadline, design: .monospaced, weight: .bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            HStack {
                Spacer()
                Button("Done") {
                    self.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.bottom, .horizontal], 20)
        }
        .frame(width: 440, height: 480)
    }
}
