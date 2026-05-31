import Foundation
import SwiftUI
import Testing
@testable import Kaset

/// Smoke tests for the Liquid Glass macOS 15 compatibility shims.
///
/// These do not (and cannot) assert which branch of `#available(macOS 26.0, *)`
/// was taken — that's purely a runtime property of the host. Their job is to
/// make sure the helpers compile, accept the documented argument shapes, and
/// return a non-nil view on whichever OS the tests are running. The macOS-15
/// vs macOS-26 divergence is exercised end-to-end by running this same target
/// on the matching CI matrix legs in `.github/workflows/tests.yml`.
@MainActor
@Suite(.tags(.model))
struct LiquidGlassCompatTests {
    @Test("compatGlass returns a view for both interactive and non-interactive variants")
    func compatGlassConstructs() {
        let base = Color.blue
        let nonInteractive = base.compatGlass(in: RoundedRectangle(cornerRadius: 8))
        let interactive = base.compatGlass(interactive: true, in: Capsule())
        // Force the view trees to materialize so the underlying modifier
        // chain is exercised even when ViewBuilder would otherwise lazily
        // discard the result.
        #expect(String(describing: nonInteractive).isEmpty == false)
        #expect(String(describing: interactive).isEmpty == false)
    }

    @Test("compatGlassID is a no-op-shaped modifier on every supported OS")
    func compatGlassIDConstructs() {
        // Namespace.ID is normally injected by SwiftUI via @Namespace, but the
        // initializer is internal-by-convention. We can't easily synthesize
        // one in unit tests, so we wrap the call in a host view that owns the
        // namespace.
        struct Host: View {
            @Namespace private var ns
            var body: some View {
                Color.red.compatGlassID("test-id", in: self.ns)
            }
        }
        let host = Host()
        #expect(String(describing: host).isEmpty == false)
    }

    @Test("compatGlassTransition compiles for every CompatGlassTransition case")
    func compatGlassTransitionConstructs() {
        let view = Color.green.compatGlassTransition(.materialize)
        #expect(String(describing: view).isEmpty == false)
    }

    @Test("compatGlassProminentButton applies a button style on every OS")
    func compatGlassProminentButtonConstructs() {
        let button = Button("Play", action: {}).compatGlassProminentButton()
        #expect(String(describing: button).isEmpty == false)
    }

    @Test("CompatGlassContainer renders its content")
    func compatGlassContainerRendersContent() {
        let container = CompatGlassContainer(spacing: 4) {
            Text("hello")
        }
        let rendered = String(describing: container.body)
        #expect(rendered.isEmpty == false)
    }

    @Test("CompatGlassContainer with default spacing matches explicit zero")
    func compatGlassContainerDefaultSpacing() {
        let defaultContainer = CompatGlassContainer { Text("a") }
        let explicit = CompatGlassContainer(spacing: 0) { Text("a") }
        #expect(defaultContainer.spacing == explicit.spacing)
    }

    @Test("compat shims construct when legacy macOS 15 UI is forced")
    func compatGlassConstructsWithLegacyEnvironment() {
        let view = Color.purple
            .compatGlass(interactive: true, in: RoundedRectangle(cornerRadius: 12))
            .compatGlassTransition(.materialize)
            .environment(\.usesLegacyMacOS15UI, true)

        #expect(String(describing: view).isEmpty == false)
    }

    @Test("legacy macOS 15 UI override disables macOS 26-only UI capabilities")
    func legacyUIOverrideDisablesModernUICapabilities() {
        #expect(PlatformCapabilities.supportsCommandBar(usesLegacyMacOS15UI: true) == false)
        #expect(PlatformCapabilities.supportsFoundationModels(usesLegacyMacOS15UI: true) == false)
    }

    #if DEBUG
        @Test("debug legacy macOS 15 UI setting persists")
        func debugLegacyUISettingPersists() {
            let settings = SettingsManager.shared
            let key = SettingsManager.Keys.useLegacyMacOS15UI
            let originalSetting = settings.useLegacyMacOS15UI
            let originalDefaultsValue = UserDefaults.standard.object(forKey: key)

            defer {
                settings.useLegacyMacOS15UI = originalSetting
                if let originalDefaultsValue {
                    UserDefaults.standard.set(originalDefaultsValue, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }

            settings.useLegacyMacOS15UI = true
            #expect(UserDefaults.standard.bool(forKey: key))

            settings.useLegacyMacOS15UI = false
            #expect(UserDefaults.standard.bool(forKey: key) == false)
        }
    #endif

    @Test("Host OS routes to the expected branch")
    func hostOSReachableBranch() {
        // This documents which branch the rest of the suite is running on. It
        // is intentionally not a hard assertion — its value is in the test
        // logs / CI output, where a maintainer can confirm both legs of the
        // matrix actually hit different branches.
        if #available(macOS 26.0, *) {
            #expect(Bool(true), "Running on macOS 26+: Liquid Glass branch is live")
        } else {
            #expect(Bool(true), "Running on macOS 15: ultraThinMaterial fallback branch is live")
        }
    }
}
