import SwiftUI

// MARK: - CompatGlassTransition

// Liquid Glass compatibility shims so the app can build and run on macOS 15
// (Sequoia) while preserving the Liquid Glass look on macOS 26+ (Tahoe).
//
// On macOS 26+ the helpers forward to Apple's real APIs (`.glassEffect`,
// `GlassEffectContainer`, etc.). On macOS 15, and when the debug-only legacy
// UI switch is enabled, they fall back to `.ultraThinMaterial` backgrounds and
// plain containers.

enum CompatGlassTransition {
    case materialize
}

extension View {
    func compatGlass(interactive: Bool = false, in shape: some Shape) -> some View {
        self.modifier(CompatGlassModifier(interactive: interactive, shape: shape))
    }

    func compatGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        self.modifier(CompatGlassIDModifier(id: id, namespace: namespace))
    }

    func compatGlassTransition(_ transition: CompatGlassTransition) -> some View {
        self.modifier(CompatGlassTransitionModifier(transition: transition))
    }

    /// Apply `.glassProminent` on macOS 26+, `.borderedProminent` fallback otherwise.
    func compatGlassProminentButton() -> some View {
        self.modifier(CompatGlassProminentButtonModifier())
    }
}

// MARK: - CompatGlassModifier

private struct CompatGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    let interactive: Bool
    let shape: S

    func body(content: Content) -> some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            if self.interactive {
                content.glassEffect(.regular.interactive(), in: self.shape)
            } else {
                content.glassEffect(.regular, in: self.shape)
            }
        } else {
            content.background(.ultraThinMaterial, in: self.shape)
        }
    }
}

// MARK: - CompatGlassIDModifier

private struct CompatGlassIDModifier: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            content.glassEffectID(self.id, in: self.namespace)
        } else {
            content
        }
    }
}

// MARK: - CompatGlassTransitionModifier

private struct CompatGlassTransitionModifier: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    let transition: CompatGlassTransition

    func body(content: Content) -> some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            switch self.transition {
            case .materialize:
                content.glassEffectTransition(.materialize)
            }
        } else {
            content
        }
    }
}

// MARK: - CompatGlassProminentButtonModifier

private struct CompatGlassProminentButtonModifier: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    func body(content: Content) -> some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - CompatGlassContainer

struct CompatGlassContainer<Content: View>: View {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: self.spacing) { self.content() }
        } else {
            self.content()
        }
    }
}
