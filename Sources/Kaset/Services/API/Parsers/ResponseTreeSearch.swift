import Foundation

/// Recursive search helpers for YouTube Music response trees.
enum ResponseTreeSearch {
    static func firstDictionary(named key: String, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let match = dictionary[key] as? [String: Any] {
                return match
            }

            for child in dictionary.values {
                if let match = self.firstDictionary(named: key, in: child) {
                    return match
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let match = self.firstDictionary(named: key, in: child) {
                    return match
                }
            }
        }

        return nil
    }

    static func containsKey(_ key: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary[key] != nil { return true }
            return dictionary.values.contains { self.containsKey(key, in: $0) }
        }

        if let array = value as? [Any] {
            return array.contains { self.containsKey(key, in: $0) }
        }

        return false
    }

    static func containsText(_ text: String, in value: Any) -> Bool {
        if let string = value as? String {
            return string.localizedCaseInsensitiveContains(text)
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { self.containsText(text, in: $0) }
        }

        if let array = value as? [Any] {
            return array.contains { self.containsText(text, in: $0) }
        }

        return false
    }
}
