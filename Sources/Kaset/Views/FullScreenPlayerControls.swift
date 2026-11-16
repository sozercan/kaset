import SwiftUI

// MARK: - NowPlayingCapsuleSlider

/// Thin, knobless horizontal slider used by the Now Playing view for seeking and volume.
/// It thickens while hovered or dragged.
struct NowPlayingCapsuleSlider: View {
    @Binding var value: Double
    let accessibilityLabel: String
    var accessibilityValue: String?
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isHovering = false
    @State private var isDragging = false
    /// Resets when the drag ends *or* is cancelled; `onEnded` only covers the former.
    @GestureState private var isGestureActive = false

    private static let keyboardStep = 0.05

    private var isActive: Bool {
        self.isEnabled && (self.isHovering || self.isDragging)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let frame = proxy.frame(in: .global)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                Capsule()
                    .fill(.white.opacity(self.isActive ? 0.95 : 0.7))
                    .frame(width: width * min(max(self.value, 0), 1))
            }
            .frame(height: self.isActive ? 7 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                // Global coordinates are never mirrored, so the leading edge is explicit.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating(self.$isGestureActive) { _, isActive, _ in
                        isActive = true
                    }
                    .onChanged { gesture in
                        self.beginEditingIfNeeded()
                        self.value = self.fraction(atGlobalX: gesture.location.x, in: frame, width: width)
                    }
                    .onEnded { gesture in
                        self.value = self.fraction(atGlobalX: gesture.location.x, in: frame, width: width)
                    }
            )
        }
        .frame(height: 16)
        .onHover { self.isHovering = $0 }
        .onChange(of: self.isGestureActive) { _, isActive in
            if !isActive {
                self.endEditingIfNeeded()
            }
        }
        .animation(.easeOut(duration: 0.15), value: self.isActive)
        // Keyboard navigation focus only, so a mouse click doesn't leave a focus ring behind.
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            // The fill grows from the leading edge, which is on the right in RTL layouts.
            let towardTrailing = (press.key == .rightArrow) == (self.layoutDirection == .leftToRight)
            self.adjust(by: towardTrailing ? Self.keyboardStep : -Self.keyboardStep)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue(self.accessibilityValue ?? "\(Int((self.value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            self.adjust(by: direction == .increment ? Self.keyboardStep : -Self.keyboardStep)
        }
    }

    /// Distance from the leading edge as a fraction; the fill grows from the right in RTL.
    private func fraction(atGlobalX x: CGFloat, in frame: CGRect, width: CGFloat) -> Double {
        let fromLeading = self.layoutDirection == .leftToRight ? x - frame.minX : frame.maxX - x
        return min(max(fromLeading / width, 0), 1)
    }

    private func beginEditingIfNeeded() {
        guard !self.isDragging else { return }
        self.isDragging = true
        self.onEditingChanged(true)
    }

    private func endEditingIfNeeded() {
        guard self.isDragging else { return }
        self.isDragging = false
        self.onEditingChanged(false)
    }

    /// One discrete step, reported as a complete edit so seeks and volume changes commit.
    private func adjust(by delta: Double) {
        guard self.isEnabled, !self.isDragging else { return }
        let newValue = min(max(self.value + delta, 0), 1)
        guard newValue != self.value else { return }
        self.onEditingChanged(true)
        self.value = newValue
        self.onEditingChanged(false)
    }
}

// MARK: - NowPlayingGlassIconButton

/// Icon button that sits inside one of the Now Playing view's glass capsules.
/// When selected it shows a filled white circle behind a dark glyph.
struct NowPlayingGlassIconButton: View {
    let systemName: String
    let label: String
    var isSelected = false
    var tint: Color?
    var accessibilityValue = ""
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Image(systemName: self.systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(self.foreground)
                .frame(width: 24, height: 24)
                .background {
                    if self.isSelected {
                        Circle().fill(.white.opacity(0.92))
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(self.label)
        .accessibilityLabel(self.label)
        .accessibilityValue(self.accessibilityValue)
    }

    private var foreground: Color {
        if self.isSelected {
            return .black.opacity(0.85)
        }
        return self.tint ?? .white.opacity(0.92)
    }
}

// MARK: - NowPlayingVolumeControl

/// AirPlay button, volume slider and mute toggle shown in the Now Playing view's top-right
/// glass capsule.
struct NowPlayingVolumeControl: View {
    @Environment(PlayerService.self) private var playerService
    @State private var airPlayAnchor = AirPlayPickerAnchor()
    @State private var volumeValue: Double = 1
    @State private var isAdjustingVolume = false

    var body: some View {
        HStack(spacing: 6) {
            NowPlayingGlassIconButton(
                systemName: "airplayaudio",
                label: self.playerService.isAirPlayConnected ? String(localized: "AirPlay Connected") : String(localized: "AirPlay"),
                tint: self.playerService.isAirPlayConnected ? PackageResourceLookup.brandAccent : nil
            ) {
                HapticService.toggle()
                self.playerService.showAirPlayPicker(at: self.airPlayAnchor.screenPoint)
            }
            .background {
                AirPlayPickerAnchorView(anchor: self.airPlayAnchor)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .disabled(self.playerService.currentTrack == nil)

            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 16)

            NowPlayingCapsuleSlider(
                value: self.$volumeValue,
                accessibilityLabel: String(localized: "Volume")
            ) { editing in
                self.isAdjustingVolume = editing
                if !editing {
                    self.playerService.setVolumeImmediately(self.volumeValue)
                }
            }
            .frame(width: 90)
            .onChange(of: self.volumeValue) { _, newValue in
                if self.isAdjustingVolume {
                    self.playerService.setVolumeImmediately(newValue)
                }
            }

            NowPlayingGlassIconButton(
                systemName: self.volumeIcon,
                label: self.playerService.isMuted ? String(localized: "Unmute") : String(localized: "Mute")
            ) {
                Task { await self.playerService.toggleMute() }
            }
        }
        .padding(.horizontal, 4)
        .compatGlass(interactive: true, in: .capsule)
        .onChange(of: self.playerService.volume) { _, newValue in
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onAppear {
            self.volumeValue = self.playerService.volume
        }
    }

    private var volumeIcon: String {
        let volume = self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
        if volume == 0 {
            return "speaker.slash.fill"
        }
        return volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }
}
