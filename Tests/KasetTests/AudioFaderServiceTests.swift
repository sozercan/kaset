import Testing
@testable import Kaset

// MARK: - AudioFaderServiceTests

@MainActor
struct AudioFaderServiceTests {
    @Test("Default fader instance is accessible")
    func defaultFaderInstance() {
        let fader = AudioFaderService.shared
        #expect(fader.idForTesting == "AudioFaderService.shared")
    }

    @Test("FadeCurve displayName values are non-empty")
    func fadeCurveDisplayNames() {
        for curve in AudioFaderService.FadeCurve.allCases {
            #expect(!curve.displayName.isEmpty)
            #expect(!curve.id.isEmpty)
        }
    }

    @Test("Linear curve calculation preserves linear progression")
    func linearCurveCalculation() {
        #expect(AudioFaderService.calculateFactor(progress: 0.0, curve: .linear) == 0.0)
        #expect(AudioFaderService.calculateFactor(progress: 0.5, curve: .linear) == 0.5)
        #expect(AudioFaderService.calculateFactor(progress: 1.0, curve: .linear) == 1.0)
    }

    @Test("Logarithmic curve calculation follows acoustic power progression")
    func logarithmicCurveCalculation() {
        #expect(AudioFaderService.calculateFactor(progress: 0.0, curve: .logarithmic) == 0.0)
        let mid = AudioFaderService.calculateFactor(progress: 0.5, curve: .logarithmic)
        #expect(mid < 0.3) // Exponential ease-in has low early energy
        #expect(AudioFaderService.calculateFactor(progress: 1.0, curve: .logarithmic) == 1.0)
    }

    @Test("Nil WebView completes callback immediately without crashing")
    func nilWebViewCompletion() {
        var completed = false
        AudioFaderService.shared.fadeOut(webView: nil) {
            completed = true
        }
        #expect(completed)
    }
}

extension AudioFaderService {
    var idForTesting: String {
        "AudioFaderService.shared"
    }
}
