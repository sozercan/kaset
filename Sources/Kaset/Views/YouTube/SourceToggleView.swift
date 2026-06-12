import SwiftUI

// MARK: - SourceToggleView

/// A two-segment glass capsule that flips the whole app between the
/// YouTube Music and YouTube video experiences.
///
/// Lives at the bottom of both sidebars, just above the profile section.
struct SourceToggleView: View {
    private static let brandAccent = PackageResourceLookup.brandAccent

    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @State private var settings = SettingsManager.shared

    /// Namespace for the sliding selection highlight.
    @Namespace private var segmentNamespace

    var body: some View {
        Group {
            if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                self.segments
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                self.segments
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
        .accessibilityIdentifier(AccessibilityID.SourceToggle.container)
        .accessibilityElement(children: .contain)
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(AppSource.allCases) { source in
                self.segment(for: source)
            }
        }
        .padding(3)
    }

    private func segment(for source: AppSource) -> some View {
        let isSelected = self.settings.appSource == source

        return Button {
            self.select(source)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: source.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(source.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .background {
            if isSelected {
                Capsule()
                    .fill(Self.brandAccent)
                    .matchedGeometryEffect(id: "selectedSegment", in: self.segmentNamespace)
            }
        }
        .accessibilityIdentifier(AccessibilityID.SourceToggle.segment(for: source))
        .accessibilityLabel(source.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(
            source == .music
                ? String(localized: "Switch to YouTube Music")
                : String(localized: "Switch to YouTube")
        )
    }

    private func select(_ source: AppSource) {
        guard self.settings.appSource != source else { return }

        if source == .music {
            // Pause a docked video in place — don't hand it to the pop-out.
            self.youtubePlayer.prepareForSourceSwitch()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            self.settings.appSource = source
        }
        HapticService.navigation()
        DiagnosticsLogger.ui.info("Source toggled to \(source.rawValue)")
    }
}

// MARK: - AccessibilityID.SourceToggle

extension AccessibilityID {
    enum SourceToggle {
        static let container = "sidebar.sourceToggle"

        static func segment(for source: AppSource) -> String {
            "sidebar.sourceToggle.\(source.rawValue)"
        }
    }
}

// MARK: - Preview

#Preview {
    SourceToggleView()
        .frame(width: 220)
        .padding()
}
