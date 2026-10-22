import SwiftUI

/// Replaces the content timeline while either playback WebView is showing an ad.
struct PlayerBarAdIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Ad", comment: "Compact badge shown during an advertisement")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.yellow, in: .capsule)
                .fixedSize()

            Capsule()
                .fill(.yellow)
                .frame(height: PlayerBarSliderVisuals.trackThickness)
        }
        .frame(height: 30, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Advertisement"))
        .accessibilityIdentifier(AccessibilityID.PlayerBar.adIndicator)
    }
}
