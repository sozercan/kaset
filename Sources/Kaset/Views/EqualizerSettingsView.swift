import SwiftUI

struct EqualizerSettingsView: View {
    @Environment(EqualizerService.self) private var service

    private let bands: [EQBand] = EQBand.defaultBands

    private var availablePresets: [EQPreset] {
        var list = EQPreset.pickerOrder
        if self.service.settings.preset == .custom {
            list.append(.custom)
        }
        return list
    }

    private var gainRange: ClosedRange<Float> {
        EQSettings.minGainDB ... EQSettings.maxGainDB
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { self.service.settings.isEnabled },
            set: { self.service.setEnabled($0) }
        )
    }

    private var preset: Binding<EQPreset> {
        Binding(
            get: { self.service.settings.preset },
            set: { self.service.apply(preset: $0) }
        )
    }

    private var preamp: Binding<Float> {
        Binding(
            get: { self.service.settings.preampDB },
            set: { self.service.setPreamp($0) }
        )
    }

    private func gainBinding(forBandAt index: Int) -> Binding<Float> {
        Binding(
            get: { self.service.settings.bandGainsDB[safe: index] ?? 0 },
            set: { self.service.setGain(forBandAt: index, to: $0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Equalizer", isOn: self.isEnabled)
                    .help(String(localized: "Processes Kaset's audio output through a 6-band equalizer."))

                EQStatusRow(status: self.service.status)

                HStack {
                    Spacer()
                    Button(String(localized: "Reset")) {
                        self.service.reset()
                    }
                    .disabled(!self.service.settings.isEnabled)
                }
            } header: {
                Text(String(localized: "Output"))
            }

            Section {
                Picker(String(localized: "Preset"), selection: self.preset) {
                    ForEach(self.availablePresets) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .disabled(!self.service.settings.isEnabled)

                EQCurveAndSlidersView(
                    bands: self.bands,
                    gains: self.service.settings.bandGainsDB,
                    range: self.gainRange,
                    bindingForBand: self.gainBinding(forBandAt:)
                )
                .frame(height: 220)
                .padding(.vertical, 8)
                .disabled(!self.service.settings.isEnabled)
                .opacity(self.service.settings.isEnabled ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.2), value: self.service.settings.isEnabled)
            } header: {
                Text(String(localized: "Bands"))
            }

            Section {
                HStack {
                    Text(String(localized: "Preamp"))
                    Spacer()
                    Text(Self.formatGain(self.service.settings.preampDB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Slider(
                    value: self.preamp,
                    in: self.gainRange,
                    step: 0.5
                )
                .disabled(!self.service.settings.isEnabled)
            } header: {
                Text(String(localized: "Preamp"))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .localizedNavigationTitle("Equalizer")
    }

    fileprivate static func formatGain(_ value: Float) -> String {
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", value)) dB"
    }
}

private struct EQStatusRow: View {
    let status: EqualizerService.Status

    private static let screenRecordingPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: self.iconName)
                .foregroundStyle(self.iconColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.subheadline.weight(.medium))
                if let subtitle = self.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if self.showsSettingsLink, let url = Self.screenRecordingPaneURL {
                Link(destination: url) {
                    Text(String(localized: "Open Settings"))
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch self.status {
        case .off: "power.circle"
        case .active: "checkmark.circle.fill"
        case .standby: "pause.circle"
        case .permissionNeeded: "lock.shield"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch self.status {
        case .off: .secondary
        case .active: .green
        case .standby: .accentColor
        case .permissionNeeded: .orange
        case .error: .red
        }
    }

    private var title: String {
        switch self.status {
        case .off: String(localized: "Off")
        case .active: String(localized: "Active")
        case .standby: String(localized: "Waiting for playback")
        case .permissionNeeded: String(localized: "Permission needed")
        case .error: String(localized: "Engine error")
        }
    }

    private var subtitle: String? {
        switch self.status {
        case .off:
            nil
        case .active:
            String(localized: "Equalizer is processing Kaset's audio output.")
        case .standby:
            String(localized: "The equalizer activates as soon as you press play.")
        case let .permissionNeeded(message), let .error(message):
            message
        }
    }

    private var showsSettingsLink: Bool {
        if case .permissionNeeded = self.status {
            return true
        }
        return false
    }
}

private struct EQCurveAndSlidersView: View {
    let bands: [EQBand]
    let gains: [Float]
    let range: ClosedRange<Float>
    let bindingForBand: (Int) -> Binding<Float>

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack {
                    EQCurveShape(gains: self.gains, range: self.range)
                        .stroke(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.8), .accentColor.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: .accentColor.opacity(0.35), radius: 4, y: 1)
                        .drawingGroup()

                    HStack(spacing: 0) {
                        ForEach(Array(self.bands.enumerated()), id: \.element.id) { index, band in
                            EQBandSlider(
                                band: band,
                                gain: self.bindingForBand(index),
                                range: self.range
                            )
                            .frame(width: geometry.size.width / CGFloat(self.bands.count))
                        }
                    }
                }
            }
        }
    }
}

private struct EQBandSlider: View {
    let band: EQBand
    @Binding var gain: Float
    let range: ClosedRange<Float>

    var body: some View {
        VStack(spacing: 6) {
            Text(EqualizerSettingsView.formatGain(self.gain))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: self.$gain, in: self.range, step: 0.5)
                .rotationEffect(.degrees(-90))
                .frame(width: 140)
                .fixedSize()
                .frame(width: 36)

            Text(self.band.displayLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(String(localized: "Hz"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct EQCurveShape: Shape {
    let gains: [Float]
    let range: ClosedRange<Float>

    private static let verticalFillRatio: CGFloat = 0.85

    func path(in rect: CGRect) -> Path {
        guard self.gains.count >= 2 else { return Path() }

        let stepX = rect.width / CGFloat(self.gains.count)
        let midY = rect.midY
        let span = CGFloat(self.range.upperBound - self.range.lowerBound)
        let scaleY = rect.height * Self.verticalFillRatio / span

        let points: [CGPoint] = self.gains.enumerated().map { index, gain in
            let x = stepX * (CGFloat(index) + 0.5)
            let y = midY - CGFloat(gain) * scaleY
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: points[0])

        for index in 0 ..< points.count - 1 {
            let p0 = index == 0 ? points[0] : points[index - 1]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = index + 2 < points.count ? points[index + 2] : p2

            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }

        return path
    }
}
