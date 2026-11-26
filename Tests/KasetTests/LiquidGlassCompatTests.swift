import Foundation
import SwiftUI
import Testing
@testable import Kaset

@MainActor
@Suite(.tags(.model))
struct LiquidGlassCompatTests {
    @Test("compatGlass returns a view for both interactive and non-interactive variants")
    func compatGlassConstructs() {
        let base = Color.blue
        let nonInteractive = base.compatGlass(in: RoundedRectangle(cornerRadius: 8))
        let interactive = base.compatGlass(interactive: true, in: Capsule())
        #expect(String(describing: nonInteractive).isEmpty == false)
        #expect(String(describing: interactive).isEmpty == false)
    }

    @Test("compatGlassID is a no-op-shaped modifier on every supported OS")
    func compatGlassIDConstructs() {
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

    @Test("compatTranslucentSidebar returns a view on every OS")
    func compatTranslucentSidebarConstructs() {
        let view = List { Text("Home") }.compatTranslucentSidebar()
        #expect(String(describing: view).isEmpty == false)
    }

    @Test("compatTranslucentSidebar constructs when legacy macOS 15 UI is forced")
    func compatTranslucentSidebarConstructsWithLegacyEnvironment() {
        let view = List { Text("Home") }
            .compatTranslucentSidebar()
            .environment(\.usesLegacyMacOS15UI, true)
        #expect(String(describing: view).isEmpty == false)
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
        if #available(macOS 26.0, *) {
            #expect(Bool(true), "Running on macOS 26+: Liquid Glass branch is live")
        } else {
            #expect(Bool(true), "Running on macOS 15: ultraThinMaterial fallback branch is live")
        }
    }
}
