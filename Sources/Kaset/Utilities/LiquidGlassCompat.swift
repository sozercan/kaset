import SwiftUI

// MARK: - CompatGlassTransition

// Liquid Glass compatibility shims so the app can build and run on macOS 15
// (Sequoia) while preserving the Liquid Glass look on macOS 26+ (Tahoe).
//
// On macOS 26+ the helpers forward to Apple's real APIs (`.glassEffect`,
// `GlassEffectContainer`, etc.). On macOS 15 they fall back to
// `.ultraThinMaterial` backgrounds and plain containers.

enum CompatGlassTransition {
    case materialize
}

extension View {
    @ViewBuilder
    func compatGlass(interactive: Bool = false, in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func compatGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatGlassTransition(_ transition: CompatGlassTransition) -> some View {
        if #available(macOS 26.0, *) {
            switch transition {
            case .materialize:
                self.glassEffectTransition(.materialize)
            }
        } else {
            self
        }
    }
}

extension View {
    /// Apply `.glassProminent` on macOS 26+, `.borderedProminent` fallback otherwise.
    @ViewBuilder
    func compatGlassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - CompatGlassContainer

struct CompatGlassContainer<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: self.spacing) { self.content() }
        } else {
            self.content()
        }
    }
}
