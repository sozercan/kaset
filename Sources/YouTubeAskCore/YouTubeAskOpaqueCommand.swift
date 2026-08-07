import Foundation

// MARK: - YouTubeAskOpaqueCommand

/// Server-issued command material. The raw value is intentionally inaccessible
/// outside this module and has only redacted string/reflection representations.
package struct YouTubeAskOpaqueCommand: Equatable, Sendable {
    let continuation: String
    let clickTrackingParams: String?

    package init(_ continuation: String) {
        self.continuation = continuation
        self.clickTrackingParams = nil
    }

    package init(continuation: String, clickTrackingParams: String) {
        self.continuation = continuation
        self.clickTrackingParams = clickTrackingParams
    }
}

// MARK: CustomStringConvertible

extension YouTubeAskOpaqueCommand: CustomStringConvertible {
    package var description: String {
        "<redacted YouTube Ask command>"
    }
}

// MARK: CustomDebugStringConvertible

extension YouTubeAskOpaqueCommand: CustomDebugStringConvertible {
    package var debugDescription: String {
        self.description
    }
}

// MARK: CustomReflectable

extension YouTubeAskOpaqueCommand: CustomReflectable {
    package var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}
