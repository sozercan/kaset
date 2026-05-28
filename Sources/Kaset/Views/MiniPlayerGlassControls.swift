import AVKit
import SwiftUI

// MARK: - MiniPlayerGlassIconLabel

struct MiniPlayerGlassIconLabel: View {
    let systemName: String
    let isActive: Bool
    let size: CGFloat
    var fontSize: CGFloat = 14

    var body: some View {
        Image(systemName: self.systemName)
            .font(.system(size: self.fontSize, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(self.isActive ? PackageResourceLookup.brandAccent : .white.opacity(0.94))
            .frame(width: self.size, height: self.size)
            .background(self.isActive ? PackageResourceLookup.brandAccent.opacity(0.20) : .white.opacity(0.05), in: .circle)
            .overlay {
                Circle()
                    .stroke(self.isActive ? PackageResourceLookup.brandAccent.opacity(0.90) : .white.opacity(0.26), lineWidth: self.isActive ? 1.2 : 1)
            }
            .contentShape(.circle)
    }
}

// MARK: - MiniPlayerAirPlayRoutePickerView

struct MiniPlayerAirPlayRoutePickerView: NSViewRepresentable {
    func makeNSView(context _: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView(frame: .zero)
        Self.configure(routePickerView)
        return routePickerView
    }

    func updateNSView(_ routePickerView: AVRoutePickerView, context _: Context) {
        Self.configure(routePickerView)
    }

    private static func configure(_ routePickerView: AVRoutePickerView) {
        routePickerView.isRoutePickerButtonBordered = false
        [
            AVRoutePickerView.ButtonState.normal,
            .normalHighlighted,
            .active,
            .activeHighlighted,
        ].forEach { state in
            routePickerView.setRoutePickerButtonColor(.clear, for: state)
        }
    }
}
