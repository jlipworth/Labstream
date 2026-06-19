import Foundation

// Audio/subtitle preference key strings now live in `PlaybackPreferences.Keys`
// (see UI/PlayerExperiencePreferences.swift) so all defaults keys share one namespace.

enum SubtitleAutoSelectMode: String, CaseIterable, Identifiable {
    case manual
    case foreignAudio
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manually Selected"
        case .foreignAudio: return "Shown with Foreign Audio"
        case .always: return "Always Enabled"
        }
    }

    var help: String {
        switch self {
        case .manual:
            return "Subtitles stay off until selected in the player."
        case .foreignAudio:
            return "Subtitles are selected when the audio language is different from your preferred audio language."
        case .always:
            return "Subtitles are selected whenever your preferred subtitle language is available."
        }
    }
}

enum SubtitleBurnMode: String, CaseIterable, Identifiable {
    case automatic
    case imageFormatsOnly
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .imageFormatsOnly: return "Only Image Formats"
        case .always: return "Always"
        }
    }

    var help: String {
        switch self {
        case .automatic:
            return "Let Plex decide whether subtitles should stay selectable or be burned in."
        case .imageFormatsOnly:
            return "Burn image-based subtitles such as PGS or VobSub when VisionPlay can identify them."
        case .always:
            return "Burn the selected subtitle stream into the video when a matching stream is known."
        }
    }
}

struct PlaybackLanguageOption: Identifiable, Hashable {
    let id: String
    let label: String

    static let none = PlaybackLanguageOption(id: "", label: "System Default")

    static let common: [PlaybackLanguageOption] = [
        .none,
        .init(id: "en", label: "English"),
        .init(id: "es", label: "Spanish"),
        .init(id: "fr", label: "French"),
        .init(id: "de", label: "German"),
        .init(id: "it", label: "Italian"),
        .init(id: "pt", label: "Portuguese"),
        .init(id: "ja", label: "Japanese"),
        .init(id: "ko", label: "Korean"),
        .init(id: "zh", label: "Chinese"),
        .init(id: "nl", label: "Dutch"),
        .init(id: "sv", label: "Swedish"),
        .init(id: "no", label: "Norwegian"),
        .init(id: "da", label: "Danish"),
        .init(id: "fi", label: "Finnish"),
    ]

    static func label(for code: String?) -> String {
        guard let code, !code.isEmpty else { return none.label }
        return common.first { $0.id == code }?.label
            ?? Locale.current.localizedString(forIdentifier: code)
            ?? code
    }
}
