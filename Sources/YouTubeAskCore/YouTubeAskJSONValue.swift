import Foundation

/// Sendable JSON representation used across the app and API Explorer targets.
package indirect enum YouTubeAskJSONValue: Equatable, Sendable {
    case object([String: YouTubeAskJSONValue])
    case array([YouTubeAskJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    package var objectValue: [String: YouTubeAskJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    package var arrayValue: [YouTubeAskJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    package var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    package subscript(key: String) -> YouTubeAskJSONValue? {
        self.objectValue?[key]
    }
}
