import SwiftUI

enum AppAnimation {
    static let quick = Animation.easeOut(duration: 0.15)

    static let standard = Animation.easeInOut(duration: 0.25)

    static let smooth = Animation.easeInOut(duration: 0.35)

    static let ambient = Animation.easeInOut(duration: 0.5)

    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.7)

    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)

    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.8)

    static let staggerDelay: Double = 0.05

    static let maxStaggerDelay: Double = 0.5

    static func stagger(for index: Int, base: Double = staggerDelay) -> Double {
        min(Double(index) * base, self.maxStaggerDelay)
    }
}
