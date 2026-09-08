/// Associates playback state with a navigation only while that object exists.
///
/// WebKit does not always deliver a terminal callback after `stopLoading()`.
/// An `ObjectIdentifier` alone can then outlive its navigation and alias a later
/// load. Weak keys preserve late-callback ownership without retaining cancelled
/// navigations indefinitely.
struct WebPlaybackNavigationMap<Navigation: AnyObject, Value>: Sequence {
    typealias Element = (key: Navigation, value: Value)

    private struct Entry {
        weak var navigation: Navigation?
        let value: Value
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    subscript(navigation: Navigation) -> Value? {
        get {
            guard let entry = self.entries[ObjectIdentifier(navigation)],
                  entry.navigation === navigation
            else { return nil }
            return entry.value
        }
        set {
            self.entries = self.entries.filter { $0.value.navigation != nil }
            self.entries[ObjectIdentifier(navigation)] = newValue.map {
                Entry(navigation: navigation, value: $0)
            }
        }
    }

    var values: [Value] {
        self.map(\.value)
    }

    var count: Int {
        self.values.count
    }

    @discardableResult
    mutating func removeValue(forKey navigation: Navigation) -> Value? {
        guard let entry = self.entries.removeValue(forKey: ObjectIdentifier(navigation)),
              entry.navigation === navigation
        else { return nil }
        return entry.value
    }

    mutating func removeAll() {
        self.entries.removeAll()
    }

    func filter(_ isIncluded: (Element) -> Bool) -> Self {
        var result = Self()
        for entry in self where isIncluded(entry) {
            result[entry.key] = entry.value
        }
        return result
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        self.entries.values.compactMap { entry in
            entry.navigation.map { (key: $0, value: entry.value) }
        }.makeIterator()
    }
}
