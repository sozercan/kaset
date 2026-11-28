import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct UnitTestIsolationTests {
    @Test("UITestConfig explicitly detects the unit test host")
    func uiTestConfigDetectsUnitTestHost() {
        #expect(UITestConfig.isRunningUnitTests)
    }

    #if DEBUG
        @Test("UITestConfig explicit override enables unit test host detection without ambient signals")
        func uiTestConfigExplicitOverride() {
            #expect(
                UITestConfig.detectUnitTestHost(
                    environment: [:],
                    hasXCTestCaseClass: false,
                    explicitOverride: false
                ) == false
            )
            #expect(
                UITestConfig.detectUnitTestHost(
                    environment: [:],
                    hasXCTestCaseClass: false,
                    explicitOverride: true
                ) == true
            )

            let original = UITestConfig.explicitUnitTestHostOverride
            defer { UITestConfig.explicitUnitTestHostOverride = original }

            UITestConfig.explicitUnitTestHostOverride = false
            #expect(UITestConfig.explicitUnitTestHostOverride == false)
            UITestConfig.explicitUnitTestHostOverride = true
            #expect(UITestConfig.explicitUnitTestHostOverride == true)
            #expect(
                UITestConfig.detectUnitTestHost(
                    environment: [:],
                    hasXCTestCaseClass: false,
                    explicitOverride: UITestConfig.explicitUnitTestHostOverride
                ) == true
            )
        }
    #endif
}
