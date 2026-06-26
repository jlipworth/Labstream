import Foundation

/// Stable categories used by VisionPlay's opt-in diagnostic report.
///
/// Keep these raw values human-readable and durable: they are written into user-exported
/// reports and are intentionally broader than implementation file names.
public enum DiagnosticCategory: String, CaseIterable, Codable, Sendable, Equatable {
    case playback = "Playback"
    case transcode = "Transcode"
    case downloads = "Downloads"
    case music = "Music"
    case timeline = "Timeline"
    case auth = "Auth"
    case discovery = "Discovery"
    case networking = "Networking"
    case browse = "Browse"
    case settingsUI = "Settings/UI"

    public var logCategory: String { rawValue }
}
