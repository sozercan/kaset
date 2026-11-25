import SwiftUI

enum CompatGlassTransition {
    case materialize
}

extension View {
    func compatGlass(interactive: Bool = false, tint: Color? = nil, in shape: some Shape, isEnabled: Bool = true) -> some View {
        self.modifier(CompatGlassModifier(interactive: interactive, tint: tint, shape: shape, isEnabled: isEnabled))
    }

    func compatGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        self.modifier(CompatGlassIDModifier(id: id, namespace: namespace))
    }

    func compatGlassTransition(_ transition: CompatGlassTransition) -> some View {
        self.modifier(CompatGlassTransitionModifier(transition: transition))
    }

    func compatGlassProminentButton() -> some View {
        self.modifier(CompatGlassProminentButtonModifier())
    }

    func compatTranslucentSidebar() -> some View {
        self.modifier(CompatTranslucentSidebarModifier())
    }
}

private struct CompatGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    let interactive: Bool
    var tint: Color?
    let shape: S
    var isEnabled = true

    func body(content: Content) -> some View {
        if !self.isEnabled {
            content
        } else if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            content.glassEffect(self.glass, in: self.shape)
        } else if let tint {
            content
                .background(tint.opacity(0.55), in: self.shape)
                .background(.ultraThinMaterial, in: self.shape)
        } else {
            content.background(.ultraThinMaterial, in: self.shape)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass: Glass = .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if self.interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

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

private struct CompatTranslucentSidebarModifier: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    func body(content: Content) -> some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
                .scrollContentBackground(.hidden)
                .background(.ultraThinMaterial)
        }
    }
}
