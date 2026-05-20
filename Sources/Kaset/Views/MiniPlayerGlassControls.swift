import AVKit
import SwiftUI

// MARK: - MiniPlayerGlassSurface

@available(macOS 26.0, *)
struct MiniPlayerGlassSurface: View {
    let cornerRadius: CGFloat
    let fillOpacity: Double
    let artworkURL: URL?
    let artworkOpacity: Double

    var body: some View {
        ZStack {
            MiniPlayerArtworkTint(url: self.artworkURL, opacity: self.artworkOpacity)

            RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                .fill(.black.opacity(self.fillOpacity))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: self.cornerRadius))
                .overlay {
                    LinearGradient(
                        colors: [
                            .white.opacity(0.14),
                            .clear,
                            .black.opacity(0.20),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(.rect(cornerRadius: self.cornerRadius))
                    .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.20), lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.38),
                                    .white.opacity(0.08),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                }
        }
        .clipShape(.rect(cornerRadius: self.cornerRadius))
    }
}

// MARK: - MiniPlayerArtworkTint

@available(macOS 26.0, *)
struct MiniPlayerArtworkTint: View {
    let url: URL?
    let opacity: Double

    var body: some View {
        if let url {
            CachedAsyncImage(url: url, targetSize: CGSize(width: 180, height: 180)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(1.28)
                    .blur(radius: 28)
                    .scaleEffect(1.18)
                    .opacity(self.opacity)
            } placeholder: {
                Color.clear
            }
            .overlay {
                LinearGradient(
                    colors: [
                        .black.opacity(0.20),
                        .black.opacity(0.58),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

// MARK: - MiniPlayerGlassIconLabel

@available(macOS 26.0, *)
struct MiniPlayerGlassIconLabel: View {
    let systemName: String
    let isActive: Bool
    let size: CGFloat
    var fontSize: CGFloat = 14

    var body: some View {
        Image(systemName: self.systemName)
            .font(.system(size: self.fontSize, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(self.isActive ? .white : .white.opacity(0.94))
            .frame(width: self.size, height: self.size)
            .background {
                Circle()
                    .fill(self.isActive ? PackageResourceLookup.brandAccent.opacity(0.58) : .white.opacity(0.07))
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(self.isActive ? 0.34 : 0.20),
                                .clear,
                                .black.opacity(0.18),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(self.isActive ? 0.86 : 0.38),
                                .white.opacity(self.isActive ? 0.20 : 0.12),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: self.isActive ? 1.2 : 1
                    )
            }
            .overlay(alignment: .top) {
                Circle()
                    .fill(.white.opacity(self.isActive ? 0.34 : 0.18))
                    .frame(width: self.size * 0.44, height: self.size * 0.16)
                    .blur(radius: 2)
                    .offset(y: 3)
            }
            .contentShape(.circle)
    }
}

// MARK: - MiniPlayerProgressSlider

@available(macOS 26.0, *)
struct MiniPlayerProgressSlider: View {
    @Binding var value: Double

    let isActive: Bool
    let isDisabled: Bool
    let accessibilityID: String
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.10), lineWidth: 0.7)
                    }
                    .frame(height: 4)

                Capsule()
                    .fill(PackageResourceLookup.brandAccent)
                    .shadow(color: PackageResourceLookup.brandAccent.opacity(0.42), radius: self.isActive ? 7 : 3)
                    .frame(width: max(0, proxy.size.width * self.clampedValue), height: 4)

                Circle()
                    .fill(.white.opacity(0.94))
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.38), radius: 4, y: 1)
                    .offset(x: max(0, min(proxy.size.width - 13, proxy.size.width * self.clampedValue - 6.5)))
                    .opacity(self.isActive ? 1 : 0)

                Slider(value: self.$value, in: 0 ... 1, onEditingChanged: self.onEditingChanged)
                    .controlSize(.small)
                    .tint(.clear)
                    .opacity(0.02)
                    .disabled(self.isDisabled)
                    .accessibilityIdentifier(self.accessibilityID)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 14)
    }

    private var clampedValue: Double {
        min(max(self.value, 0), 1)
    }
}

// MARK: - MiniPlayerAirPlayRoutePickerView

@available(macOS 26.0, *)
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
