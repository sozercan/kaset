import Combine
import SwiftUI

/// Dynamic ambient particle and audio visualizer canvas backdrop for Spotlight presentation mode.
struct SpotlightBackdropVisualizerView: View {
    let isPlaying: Bool
    let accentColor: Color

    @State private var phase: Double = 0.0
    @State private var barHeights: [CGFloat] = Array(repeating: 0.2, count: 24)

    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Ambient Radial Glow Circles
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height

                Circle()
                    .fill(self.accentColor.opacity(0.20))
                    .frame(width: width * 0.7, height: width * 0.7)
                    .blur(radius: 60)
                    .offset(
                        x: cos(self.phase * 0.5) * (width * 0.15),
                        y: sin(self.phase * 0.5) * (height * 0.15)
                    )

                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: width * 0.6, height: width * 0.6)
                    .blur(radius: 70)
                    .offset(
                        x: sin(self.phase * 0.4) * (width * 0.12),
                        y: cos(self.phase * 0.4) * (height * 0.12)
                    )
            }

            // Realtime Ambient Waveform Equalizer Canvas
            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0 ..< self.barHeights.count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [self.accentColor.opacity(0.6), self.accentColor.opacity(0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 4, height: max(6, self.barHeights[index] * 120))
                            .animation(.easeInOut(duration: 0.1), value: self.barHeights[index])
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .allowsHitTesting(false)
        .onReceive(self.timer) { _ in
            guard self.isPlaying else {
                for i in self.barHeights.indices {
                    self.barHeights[i] = 0.05
                }
                return
            }

            self.phase += 0.1
            for i in self.barHeights.indices {
                let randomNoise = Double.random(in: 0.15 ... 0.85)
                let harmonic = (sin(self.phase + Double(i) * 0.3) + 1.0) * 0.5
                self.barHeights[i] = CGFloat(randomNoise * harmonic)
            }
        }
    }
}
