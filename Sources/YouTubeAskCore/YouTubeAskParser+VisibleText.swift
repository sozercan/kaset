import Foundation

extension YouTubeAskParser {
    static func visibleText(
        from value: YouTubeAskJSONValue,
        malformedError: YouTubeAskCoreError
    ) throws -> String {
        if let string = value.stringValue {
            return string
        }
        guard let object = value.objectValue else {
            throw malformedError
        }

        let recognizedKeys = ["content", "simpleText", "runs"]
            .filter { object[$0] != nil }
        guard recognizedKeys.count == 1, let selectedKey = recognizedKeys.first else {
            throw malformedError
        }

        switch selectedKey {
        case "content", "simpleText":
            guard let text = object[selectedKey]?.stringValue else {
                throw malformedError
            }
            return text
        case "runs":
            guard let runs = object["runs"]?.arrayValue, !runs.isEmpty else {
                throw malformedError
            }
            var text = ""
            for run in runs {
                guard let runObject = run.objectValue,
                      let runText = runObject["text"]?.stringValue
                else {
                    throw malformedError
                }
                text.append(contentsOf: runText)
            }
            return text
        default:
            throw malformedError
        }
    }
}
