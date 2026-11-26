import Foundation

enum EQPreset: String, CaseIterable, Identifiable, Codable {
    case flat
    case acoustic
    case bassBooster
    case bassReducer
    case classical
    case dance
    case deep
    case electronic
    case hipHop
    case jazz
    case latin
    case loudness
    case lounge
    case piano
    case pop
    case rnb
    case rock
    case smallSpeakers
    case spokenWord
    case trebleBooster
    case trebleReducer
    case vocalBooster
    case custom

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .flat: String(localized: "Flat")
        case .acoustic: String(localized: "Acoustic")
        case .bassBooster: String(localized: "Bass Booster")
        case .bassReducer: String(localized: "Bass Reducer")
        case .classical: String(localized: "Classical")
        case .dance: String(localized: "Dance")
        case .deep: String(localized: "Deep")
        case .electronic: String(localized: "Electronic")
        case .hipHop: String(localized: "Hip-Hop")
        case .jazz: String(localized: "Jazz")
        case .latin: String(localized: "Latin")
        case .loudness: String(localized: "Loudness")
        case .lounge: String(localized: "Lounge")
        case .piano: String(localized: "Piano")
        case .pop: String(localized: "Pop")
        case .rnb: String(localized: "R&B")
        case .rock: String(localized: "Rock")
        case .smallSpeakers: String(localized: "Small Speakers")
        case .spokenWord: String(localized: "Spoken Word")
        case .trebleBooster: String(localized: "Treble Booster")
        case .trebleReducer: String(localized: "Treble Reducer")
        case .vocalBooster: String(localized: "Vocal Booster")
        case .custom: String(localized: "Custom")
        }
    }

    var bandGainsDB: [Float] {
        switch self {
        case .flat, .custom:
            [0, 0, 0, 0, 0, 0]
        case .acoustic:
            [4, 3, 2, 1, 2, 3]
        case .bassBooster:
            [5, 4, 3, 0, 0, 0]
        case .bassReducer:
            [-5, -4, -3, -1, 0, 0]
        case .classical:
            [4, 3, 0, 0, 2, 4]
        case .dance:
            [4, 5, 2, -1, 2, 4]
        case .deep:
            [4, 3, 1, 0, -2, -3]
        case .electronic:
            [4, 3, -1, 1, 2, 4]
        case .hipHop:
            [5, 3, 1, 0, 1, 3]
        case .jazz:
            [3, 2, 1, 2, 1, 3]
        case .latin:
            [4, 1, -1, 0, 1, 4]
        case .loudness:
            [5, 3, 0, 0, 2, 5]
        case .lounge:
            [-2, 0, 2, 3, 2, -1]
        case .piano:
            [2, 1, 0, 2, 3, 2]
        case .pop:
            [-1, 1, 3, 4, 2, -1]
        case .rnb:
            [3, 4, 2, -1, 2, 3]
        case .rock:
            [4, 3, -1, -1, 2, 4]
        case .smallSpeakers:
            [4, 3, 1, 0, -2, -3]
        case .spokenWord:
            [-2, -1, 1, 4, 3, -1]
        case .trebleBooster:
            [0, 0, 0, 1, 3, 5]
        case .trebleReducer:
            [0, 0, 0, -1, -3, -5]
        case .vocalBooster:
            [-1, 0, 3, 5, 3, 0]
        }
    }

    static var pickerOrder: [EQPreset] {
        allCases.filter { $0 != .custom }
    }
}
