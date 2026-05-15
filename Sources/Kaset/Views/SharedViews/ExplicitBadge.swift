import SwiftUI

/// Compact "E" badge marking explicit-content tracks.
///
/// Mirrors YouTube Music's inline `MUSIC_EXPLICIT_BADGE` indicator. Render
/// only when `Song.isExplicit == true`.
@available(macOS 26.0, *)
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.background)
            .frame(width: 12, height: 12)
            .background(.secondary, in: .rect(cornerRadius: 2.5))
            .accessibilityLabel(Text("Explicit"))
    }
}

@available(macOS 26.0, *)
#Preview {
    ExplicitBadge()
        .padding()
}
