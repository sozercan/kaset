import Foundation
import SwiftUI

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    @ViewBuilder
    func ifLet<Value>(_ value: Value?, transform: (Self, Value) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

extension URL {
    var highQualityThumbnailURL: URL? {
        guard host?.contains("ytimg.com") == true || host?.contains("googleusercontent.com") == true else {
            return self
        }

        var urlString = absoluteString

        urlString = urlString.replacingOccurrences(of: "w60-h60", with: "w226-h226")
        urlString = urlString.replacingOccurrences(of: "w120-h120", with: "w226-h226")

        return URL(string: urlString)
    }
}

extension String {
    func truncated(to length: Int, trailing: String = "…") -> String {
        if count > length {
            return String(prefix(length)) + trailing
        }
        return self
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let length = hexSanitized.count
        switch length {
        case 6:
            let red = Double((rgb >> 16) & 0xFF) / 255.0
            let green = Double((rgb >> 8) & 0xFF) / 255.0
            let blue = Double(rgb & 0xFF) / 255.0
            self.init(red: red, green: green, blue: blue)
        case 8:
            let red = Double((rgb >> 16) & 0xFF) / 255.0
            let green = Double((rgb >> 8) & 0xFF) / 255.0
            let blue = Double(rgb & 0xFF) / 255.0
            let alpha = Double((rgb >> 24) & 0xFF) / 255.0
            self.init(red: red, green: green, blue: blue, opacity: alpha)
        default:
            return nil
        }
    }
}
