import CryptoKit
import Foundation

enum InnerTubeSupport {
    static func sapisidHash(sapisid: String, origin: String, timestamp: Int) -> String {
        let input = "\(timestamp) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(timestamp)_\(hash)"
    }

    static func utcOffsetMinutes(for timeZone: TimeZone) -> Int {
        timeZone.secondsFromGMT() / 60
    }
}
