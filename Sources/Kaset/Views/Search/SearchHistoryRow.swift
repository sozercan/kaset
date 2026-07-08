import SwiftUI

// MARK: - SearchHistoryRow

/// A single "Latest Searches" row: a clock-history icon + the recorded query.
/// On hover the row highlights and reveals a trailing Remove button that deletes
/// just this query from history. The remove button is overlaid so revealing it
/// never shifts the row's layout.
struct SearchHistoryRow: View {
    let query: String
    let index: Int
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            HapticService.navigation()
            self.onSelect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 19, alignment: .center)

                Text(self.query)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            self.isHovered ? Color.primary.opacity(0.08) : Color.clear,
            in: .rect(cornerRadius: 8)
        )
        .overlay(alignment: .trailing) {
            RemoveHistoryButton(index: self.index, action: self.onRemove)
                .opacity(self.isHovered ? 1 : 0)
                .blur(radius: self.isHovered ? 0 : 6)
                .padding(.trailing, 3)
                .allowsHitTesting(self.isHovered)
        }
        .animation(.easeInOut(duration: 0.18), value: self.isHovered)
        .onHover { self.isHovered = $0 }
        .accessibilityIdentifier(AccessibilityID.SearchOverlay.historyRow(index: self.index))
    }
}

// MARK: - RemoveHistoryButton

/// The 26x26 "Remove" affordance revealed on history-row hover. Deletes just the
/// row's query from recent-search history.
struct RemoveHistoryButton: View {
    let index: Int
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            HapticService.toggle()
            self.action()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    self.isHovered ? Color.primary.opacity(0.10) : Color.clear,
                    in: .rect(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Remove from Search History"))
        .accessibilityLabel(String(localized: "Remove from Search History"))
        .accessibilityIdentifier(AccessibilityID.SearchOverlay.removeHistoryButton(index: self.index))
        .animation(.easeInOut(duration: 0.15), value: self.isHovered)
        .onHover { self.isHovered = $0 }
    }
}
