import SwiftUI

/// Compact "E" badge marking explicit-content tracks.
///
/// Mirrors YouTube Music's inline `MUSIC_EXPLICIT_BADGE` indicator. Render
/// only when `Song.isExplicit == true`.
@available(macOS 26.0, *)
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.background)
            .frame(width: 14, height: 14)
            .background(.secondary, in: .rect(cornerRadius: 3))
            .accessibilityLabel(Text("Explicit"))
    }
}

@available(macOS 26.0, *)
#Preview {
    ExplicitBadge()
        .padding()
}
