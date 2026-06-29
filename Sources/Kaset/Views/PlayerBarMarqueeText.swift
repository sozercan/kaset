import AppKit
import SwiftUI

// MARK: - PlayerBarMarqueeText

struct PlayerBarMarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let height: CGFloat
    let reduceMotion: Bool

    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var fadeMaskPhase = PlayerBarMarqueeFadeMaskPhase.inactive

    private let copyGap: CGFloat = 24
    private let initialDelay: TimeInterval = 1.4
    private let scrollSpeed: CGFloat = 18

    private var needsMarquee: Bool {
        !self.reduceMotion && self.effectiveTextWidth > self.containerWidth + 1
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: self.copyGap) {
                self.textView

                if self.needsMarquee {
                    self.textView
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: self.needsMarquee ? self.offset : 0)
            .frame(width: proxy.size.width, height: self.height, alignment: .leading)
            .clipped()
            .mask(self.maskView(phase: self.fadeMaskPhase))
            .overlay(alignment: .leading) {
                self.textMeasurer
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: self.text))
            .onAppear {
                self.containerWidth = proxy.size.width
            }
            .onChange(of: proxy.size.width) { _, width in
                guard abs(self.containerWidth - width) > 0.5 else { return }
                self.containerWidth = width
            }
        }
        .frame(height: self.height)
        .frame(maxWidth: .infinity)
        .onPreferenceChange(PlayerBarTextWidthPreferenceKey.self) { width in
            guard abs(self.textWidth - width) > 0.5 else { return }
            self.textWidth = width
        }
        .task(id: self.marqueeTaskID) {
            await self.runMarqueeLoop()
        }
    }

    private var textView: some View {
        Text(self.text)
            .font(self.font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(self.color)
    }

    private var textMeasurer: some View {
        Text(self.text)
            .font(self.font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PlayerBarTextWidthPreferenceKey.self, value: proxy.size.width)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func maskView(phase: PlayerBarMarqueeFadeMaskPhase) -> some View {
        LinearGradient(
            stops: [
                .init(color: phase.showsLeadingFade ? .clear : .black, location: 0),
                .init(color: .black, location: phase.showsLeadingFade ? 0.18 : 0),
                .init(color: .black, location: phase.showsTrailingFade ? 0.82 : 1),
                .init(color: phase.showsTrailingFade ? .clear : .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var effectiveTextWidth: CGFloat {
        max(self.textWidth, self.appKitTextWidth)
    }

    private var appKitTextWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: self.height)
        let width = (self.text as NSString).size(withAttributes: [.font: font]).width
        return ceil(width)
    }

    private var marqueeTaskID: String {
        [
            self.text,
            "\(Int(self.containerWidth.rounded()))",
            "\(Int(self.effectiveTextWidth.rounded()))",
            "\(self.reduceMotion)",
        ].joined(separator: "|")
    }

    @MainActor
    private func runMarqueeLoop() async {
        self.resetMarqueePosition()

        guard self.needsMarquee, self.containerWidth > 0 else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(self.initialDelay))
            guard !Task.isCancelled, self.needsMarquee else { return }

            withAnimation(.easeInOut(duration: 0.18)) {
                self.fadeMaskPhase = .bothEdges
            }

            let travel = self.effectiveTextWidth + self.copyGap
            let duration = max(TimeInterval(travel / self.scrollSpeed), 0.1)
            let leadingFadeDuration = max(TimeInterval(self.effectiveTextWidth / self.scrollSpeed), 0.1)

            withAnimation(.linear(duration: duration)) {
                self.offset = -travel
            }

            try? await Task.sleep(for: .seconds(leadingFadeDuration))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.18)) {
                self.fadeMaskPhase = .trailingOnly
            }

            try? await Task.sleep(for: .seconds(max(0, duration - leadingFadeDuration)))
            guard !Task.isCancelled else { return }

            self.resetOffsetWithoutAnimation()

            withAnimation(.easeInOut(duration: 0.2)) {
                self.fadeMaskPhase = .inactive
            }
        }
    }

    @MainActor
    private func resetMarqueePosition() {
        self.resetOffsetWithoutAnimation()
        withAnimation(.easeInOut(duration: 0.12)) {
            self.fadeMaskPhase = .inactive
        }
    }

    @MainActor
    private func resetOffsetWithoutAnimation() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            self.offset = 0
        }
    }
}

// MARK: - PlayerBarMarqueeFadeMaskPhase

private enum PlayerBarMarqueeFadeMaskPhase {
    case inactive
    case bothEdges
    case trailingOnly

    var showsLeadingFade: Bool {
        self == .bothEdges
    }

    var showsTrailingFade: Bool {
        self == .bothEdges || self == .trailingOnly
    }
}

// MARK: - PlayerBarTextWidthPreferenceKey

private struct PlayerBarTextWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
