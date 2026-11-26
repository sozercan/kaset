import SwiftUI

struct AccentBackground: View {
    let imageURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var palette: ColorExtractor.ColorPalette = .default
    @State private var isLoaded = false

    var body: some View {
        Group {
            if self.colorScheme == .dark {
                self.darkModeBackground
            } else {
                self.lightModeBackground
            }
        }
        .animation(.easeInOut(duration: 0.5), value: self.isLoaded)
        .animation(.easeInOut(duration: 0.3), value: self.colorScheme)
        .task(id: self.imageURL) {
            await self.loadPalette()
        }
    }

    private var darkModeBackground: some View {
        ZStack {
            LinearGradient(
                colors: [self.palette.primary, self.palette.secondary, Color(nsColor: .windowBackgroundColor).opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    self.palette.primary.opacity(0.3),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 500
            )
        }
    }

    private var lightModeBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    self.palette.lightTint.opacity(0.4),
                    self.palette.lightTint.opacity(0.15),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    private func loadPalette() async {
        guard let url = imageURL else {
            self.palette = .default
            self.isLoaded = true
            return
        }

        let extracted = await ColorExtractor.cachedPalette(for: url)
        guard !Task.isCancelled else { return }
        self.palette = extracted
        self.isLoaded = true
    }
}

struct AccentBackgroundModifier: ViewModifier {
    let imageURL: URL?

    func body(content: Content) -> some View {
        content
            .background {
                AccentBackground(imageURL: self.imageURL)
                    .ignoresSafeArea()
            }
    }
}

extension View {
    func accentBackground(from imageURL: URL?) -> some View {
        modifier(AccentBackgroundModifier(imageURL: imageURL))
    }
}

#Preview {
    VStack {
        Text("Accent Background Preview")
            .font(.largeTitle)
            .foregroundStyle(.primary)
    }
    .frame(width: 400, height: 600)
    .accentBackground(from: nil)
}
