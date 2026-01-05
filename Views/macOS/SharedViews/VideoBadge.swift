import SwiftUI

// MARK: - VideoBadge

/// Small video indicator badge for thumbnails.
@available(macOS 26.0, *)
struct VideoBadge: View {
    var body: some View {
        Image(systemName: "video.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.6), in: .circle)
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    ZStack {
        RoundedRectangle(cornerRadius: 8)
            .fill(.blue.gradient)
            .frame(width: 100, height: 100)

        VideoBadge()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(4)
    }
    .frame(width: 100, height: 100)
    .padding()
}
