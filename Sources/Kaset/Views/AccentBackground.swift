import SwiftUI

// MARK: - AccentBackground

/// A background view that displays a gradient based on colors extracted from an image.
/// Creates an effect similar to Apple Music/YouTube Music album backgrounds.
/// In light mode, uses a subtle tint; in dark mode, uses a rich gradient.
@available(macOS 26.0, *)
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

    /// Rich gradient background for dark mode.
    private var darkModeBackground: some View {
        ZStack {
            // Base gradient from extracted colors
            LinearGradient(
                colors: [self.palette.primary, self.palette.secondary, Color(nsColor: .windowBackgroundColor).opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Subtle radial overlay for depth
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

    /// Subtle tinted background for light mode - just a hint of color at the top.
    private var lightModeBackground: some View {
        ZStack {
            // Base window background
            Color(nsColor: .windowBackgroundColor)

            // Very subtle tint at the top from extracted color
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

        // Fetch image data
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let extracted = await ColorExtractor.extractPalette(from: data)
            self.palette = extracted
            self.isLoaded = true
        } catch is CancellationError {
            // Task was cancelled (e.g., imageURL changed) - expected behavior, no logging needed
            return
        } catch {
            DiagnosticsLogger.ui.debug("Failed to extract accent colors: \(error.localizedDescription)")
            self.palette = .default
            self.isLoaded = true
        }
    }
}

// MARK: - AccentBackgroundModifier

/// View modifier to apply accent background based on album art.
@available(macOS 26.0, *)
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

@available(macOS 26.0, *)
extension View {
    /// Applies an accent color background gradient extracted from the given image URL.
    /// - Parameter imageURL: The URL of the image to extract colors from.
    /// - Returns: A view with the accent background applied.
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
