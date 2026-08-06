import Foundation

enum YouTubeAskPlayerOffset {
    static func milliseconds(for progress: Double) -> Int64 {
        guard progress.isFinite, progress > 0 else {
            return 0
        }

        let milliseconds = (progress * 1000).rounded()
        guard milliseconds.isFinite,
              milliseconds < Double(Int64.max)
        else {
            return Int64.max
        }
        return Int64(milliseconds)
    }
}
