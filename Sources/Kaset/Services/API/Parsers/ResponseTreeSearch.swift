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

    static func dictionaries(named key: String, in value: Any) -> [[String: Any]] {
        var matches: [[String: Any]] = []
        if let dictionary = value as? [String: Any] {
            if let match = dictionary[key] as? [String: Any] {
                matches.append(match)
            }
            for child in dictionary.values {
                matches.append(contentsOf: self.dictionaries(named: key, in: child))
            }
        } else if let array = value as? [Any] {
            for child in array {
                matches.append(contentsOf: self.dictionaries(named: key, in: child))
            }
        }
        return matches
    }

    static func containsKey(_ key: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary[key] != nil {
                return true
            }
            for child in dictionary.values where self.containsKey(key, in: child) {
                return true
            }
            return false
        }

        if let array = value as? [Any] {
            for child in array where self.containsKey(key, in: child) {
                return true
            }
            return false
        }

        return false
    }

    static func containsAny(keys: Set<String>, text: String? = nil, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for key in keys where dictionary[key] != nil {
                return true
            }

            for child in dictionary.values where self.containsAny(keys: keys, text: text, in: child) {
                return true
            }
            return false
        }

        if let array = value as? [Any] {
            for child in array where self.containsAny(keys: keys, text: text, in: child) {
                return true
            }
            return false
        }

        if let text, let string = value as? String {
            return string.localizedCaseInsensitiveContains(text)
        }

        return false
    }

    static func containsText(_ text: String, in value: Any) -> Bool {
        if let string = value as? String {
            return string.localizedCaseInsensitiveContains(text)
        }

        if let dictionary = value as? [String: Any] {
            for child in dictionary.values where self.containsText(text, in: child) {
                return true
            }
            return false
        }

        if let array = value as? [Any] {
            for child in array where self.containsText(text, in: child) {
                return true
            }
            return false
        }

        return false
    }
}
