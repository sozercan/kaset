import Foundation
import Synchronization

final class BiquadFilter {
    struct TargetCoefficients: Equatable {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double

        static let identity = Self(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
    }

    private var b0: Double = 1
    private var b1: Double = 0
    private var b2: Double = 0
    private var a1: Double = 0
    private var a2: Double = 0

    private let targetSlots: UnsafeMutablePointer<TargetCoefficients>
    private let publishedSlotIndex = Atomic<Int>(0)
    private let readerReservedSlot = Atomic<Int>(-1)
    private let writerLock = NSLock()
    private var writerSlotIndex = 0
    private var renderTarget = TargetCoefficients.identity

    private let smoothingAlpha: Double = 0.004

    private var leftZ1: Double = 0
    private var leftZ2: Double = 0
    private var rightZ1: Double = 0
    private var rightZ2: Double = 0

    init() {
        self.targetSlots = UnsafeMutablePointer<TargetCoefficients>.allocate(capacity: 3)
        self.targetSlots.initialize(repeating: .identity, count: 3)
    }

    deinit {
        self.targetSlots.deinitialize(count: 3)
        self.targetSlots.deallocate()
    }

    func setPeakingEQ(frequency: Float, q: Float, gainDB: Float, sampleRate: Float) {
        guard let terms = Self.commonTerms(frequency: frequency, gainDB: gainDB, sampleRate: sampleRate),
              q > 0
        else { return }

        let alpha = terms.sinOmega / (2 * Double(q))
        let capitalA = terms.capitalA

        self.installTargets(Coefficients(
            b0: 1 + alpha * capitalA,
            b1: -2 * terms.cosOmega,
            b2: 1 - alpha * capitalA,
            a0: 1 + alpha / capitalA,
            a1: -2 * terms.cosOmega,
            a2: 1 - alpha / capitalA
        ))
    }

    func setLowShelf(frequency: Float, slope: Float, gainDB: Float, sampleRate: Float) {
        self.setShelf(kind: .low, frequency: frequency, slope: slope, gainDB: gainDB, sampleRate: sampleRate)
    }

    func setHighShelf(frequency: Float, slope: Float, gainDB: Float, sampleRate: Float) {
        self.setShelf(kind: .high, frequency: frequency, slope: slope, gainDB: gainDB, sampleRate: sampleRate)
    }

    private enum ShelfKind {
        case low
        case high

        var sign: Double {
            switch self {
            case .low: 1
            case .high: -1
            }
        }
    }

    private func setShelf(
        kind: ShelfKind,
        frequency: Float,
        slope: Float,
        gainDB: Float,
        sampleRate: Float
    ) {
        guard let terms = Self.commonTerms(frequency: frequency, gainDB: gainDB, sampleRate: sampleRate),
              slope > 0
        else { return }

        let safeSlope = min(Double(slope), 1)
        let capitalA = terms.capitalA
        let sqrtA = sqrt(capitalA)
        let alpha = terms.sinOmega / 2 * sqrt((capitalA + 1 / capitalA) * (1 / safeSlope - 1) + 2)
        let cosOmega = terms.cosOmega
        let sign = kind.sign
        let aPlus1 = capitalA + 1
        let aMinus1 = capitalA - 1
        let twoSqrtAAlpha = 2 * sqrtA * alpha

        self.installTargets(Coefficients(
            b0: capitalA * (aPlus1 - sign * aMinus1 * cosOmega + twoSqrtAAlpha),
            b1: 2 * capitalA * (sign * aMinus1 - aPlus1 * cosOmega),
            b2: capitalA * (aPlus1 - sign * aMinus1 * cosOmega - twoSqrtAAlpha),
            a0: aPlus1 + sign * aMinus1 * cosOmega + twoSqrtAAlpha,
            a1: -2 * (sign * aMinus1 + aPlus1 * cosOmega),
            a2: aPlus1 + sign * aMinus1 * cosOmega - twoSqrtAAlpha
        ))
    }

    func processNonInterleavedStereo(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var b0 = self.b0, b1 = self.b1, b2 = self.b2
        var a1 = self.a1, a2 = self.a2
        let targets = self.readPublishedTargets()
        let tb0 = targets.b0, tb1 = targets.b1, tb2 = targets.b2
        let ta1 = targets.a1, ta2 = targets.a2
        let alpha = self.smoothingAlpha

        var lz1 = self.leftZ1, lz2 = self.leftZ2
        var rz1 = self.rightZ1, rz2 = self.rightZ2

        for index in 0 ..< frameCount {
            b0 += (tb0 - b0) * alpha
            b1 += (tb1 - b1) * alpha
            b2 += (tb2 - b2) * alpha
            a1 += (ta1 - a1) * alpha
            a2 += (ta2 - a2) * alpha

            let xLeft = Double(left[index])
            let yLeft = b0 * xLeft + lz1
            lz1 = b1 * xLeft - a1 * yLeft + lz2
            lz2 = b2 * xLeft - a2 * yLeft
            left[index] = Float(yLeft)

            let xRight = Double(right[index])
            let yRight = b0 * xRight + rz1
            rz1 = b1 * xRight - a1 * yRight + rz2
            rz2 = b2 * xRight - a2 * yRight
            right[index] = Float(yRight)
        }

        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
        self.leftZ1 = lz1
        self.leftZ2 = lz2
        self.rightZ1 = rz1
        self.rightZ2 = rz2
    }

    func processMono(
        samples: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var b0 = self.b0, b1 = self.b1, b2 = self.b2
        var a1 = self.a1, a2 = self.a2
        let targets = self.readPublishedTargets()
        let tb0 = targets.b0, tb1 = targets.b1, tb2 = targets.b2
        let ta1 = targets.a1, ta2 = targets.a2
        let alpha = self.smoothingAlpha

        var z1 = self.leftZ1
        var z2 = self.leftZ2

        for index in 0 ..< frameCount {
            b0 += (tb0 - b0) * alpha
            b1 += (tb1 - b1) * alpha
            b2 += (tb2 - b2) * alpha
            a1 += (ta1 - a1) * alpha
            a2 += (ta2 - a2) * alpha

            let x = Double(samples[index])
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            samples[index] = Float(y)
        }

        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
        self.leftZ1 = z1
        self.leftZ2 = z2
    }

    private struct CommonTerms {
        let capitalA: Double
        let cosOmega: Double
        let sinOmega: Double
    }

    private static func commonTerms(frequency: Float, gainDB: Float, sampleRate: Float) -> CommonTerms? {
        guard sampleRate > 0, frequency > 0 else { return nil }
        let omega = 2 * Double.pi * Double(frequency) / Double(sampleRate)
        return CommonTerms(
            capitalA: pow(10, Double(gainDB) / 40),
            cosOmega: cos(omega),
            sinOmega: sin(omega)
        )
    }

    private struct Coefficients {
        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double
    }

    func readPublishedTargets(
        onSlotReserved: (() -> Void)? = nil
    ) -> TargetCoefficients {
        var index = self.publishedSlotIndex.load(ordering: .acquiring)
        for _ in 0 ..< 4 {
            self.readerReservedSlot.store(index, ordering: .sequentiallyConsistent)
            let confirmed = self.publishedSlotIndex.load(ordering: .sequentiallyConsistent)
            if confirmed == index {
                onSlotReserved?()
                let snapshot = self.targetSlots[index]
                self.readerReservedSlot.store(-1, ordering: .releasing)
                self.renderTarget = snapshot
                return snapshot
            }
            index = confirmed
        }
        self.readerReservedSlot.store(-1, ordering: .releasing)
        return self.renderTarget
    }

    private func installTargets(_ coeffs: Coefficients) {
        guard coeffs.a0.isFinite, abs(coeffs.a0) > 1e-10 else { return }
        let inverseA0 = 1 / coeffs.a0
        let snapshot = TargetCoefficients(
            b0: coeffs.b0 * inverseA0,
            b1: coeffs.b1 * inverseA0,
            b2: coeffs.b2 * inverseA0,
            a1: coeffs.a1 * inverseA0,
            a2: coeffs.a2 * inverseA0
        )
        self.writerLock.lock()
        let published = self.writerSlotIndex
        let reserved = self.readerReservedSlot.load(ordering: .sequentiallyConsistent)
        var nextSlot = (published + 1) % 3
        if nextSlot == reserved {
            nextSlot = (nextSlot + 1) % 3
        }
        self.targetSlots[nextSlot] = snapshot
        self.publishedSlotIndex.store(nextSlot, ordering: .sequentiallyConsistent)
        self.writerSlotIndex = nextSlot
        self.writerLock.unlock()
    }
}
