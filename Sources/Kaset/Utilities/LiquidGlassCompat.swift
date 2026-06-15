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
    func compatGlass(interactive: Bool = false, tint: Color? = nil, in shape: some Shape) -> some View {
        self.modifier(CompatGlassModifier(interactive: interactive, tint: tint, shape: shape))
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

    /// Hide a sidebar `List`'s opaque scroll-content background so the
    /// `NavigationSplitView` column's automatic Liquid Glass shows through
    /// (macOS 26+). On the legacy macOS 15 path the opaque sidebar material is
    /// preserved, since there is no column-level glass to reveal there.
    ///
    /// Gated on BOTH `usesLegacyMacOS15UI` AND `#available(macOS 26.0, *)`:
    /// `usesLegacyMacOS15UI` is a debug toggle, not the OS version, so hiding
    /// the list background on real macOS 15 hardware would expose the window
    /// background instead of glass.
    func compatHideSidebarListBackground() -> some View {
        self.modifier(CompatHideSidebarListBackgroundModifier())
    }
}

// MARK: - CompatGlassModifier

private struct CompatGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    let interactive: Bool
    var tint: Color?
    let shape: S

    func body(content: Content) -> some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
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

// MARK: - CompatHideSidebarListBackgroundModifier

private struct CompatHideSidebarListBackgroundModifier: ViewModifier {
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    func body(content: Content) -> some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            // Reveal the NavigationSplitView column's system Liquid Glass by
            // dropping the List's own opaque `.sidebar` material. The frosted
            // column glass (not clear glass) keeps labels legible while detail
            // content sliding underneath is faintly visible through it.
            content.scrollContentBackground(.hidden)
        } else {
            // Legacy macOS 15: keep the opaque sidebar material — there is no
            // column-level glass to reveal.
            content
        }
    }
}
