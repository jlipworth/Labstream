import Foundation

/// A Settings category: one sidebar row in the regular-width two-column Settings (iPhone Duo
/// unfolded, iPad), grouping one or more sections of the single compact form.
public enum SettingsCategory: String, CaseIterable, Hashable, Sendable, Identifiable {
    case accountServer, libraries, playback, audioSubtitles, downloads, maintenance, diagnostics, about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accountServer: "Account & Server"
        case .libraries: "Libraries"
        case .playback: "Playback"
        case .audioSubtitles: "Audio & Subtitles"
        case .downloads: "Downloads"
        case .maintenance: "Maintenance"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    public var systemImage: String {
        switch self {
        case .accountServer: "person.crop.circle"
        case .libraries: "rectangle.stack"
        case .playback: "play.rectangle"
        case .audioSubtitles: "captions.bubble"
        case .downloads: "arrow.down.circle"
        case .maintenance: "wrench.and.screwdriver"
        case .diagnostics: "ladybug"
        case .about: "info.circle"
        }
    }
}

/// The sections of the single Settings form, in form order (compact width and every platform
/// without the two-column layout).
public enum SettingsFormSection: String, CaseIterable, Hashable, Sendable {
    case backend, server, libraries, playback, audioSubtitles, downloads, maintenance, diagnostics, about, account
}

/// Maps between the compact form and the two-column layout, so a size-class change (iPhone Duo
/// fold/unfold, iPad resize) keeps the user's place in Settings (design spec global rule 9).
public enum SettingsCategoryPolicy {
    /// Sidebar rows in order. Downloads only where the platform has downloads.
    public static func sidebar(includesDownloads: Bool) -> [SettingsCategory] {
        SettingsCategory.allCases.filter { includesDownloads || $0 != .downloads }
    }

    public static func category(of section: SettingsFormSection) -> SettingsCategory {
        switch section {
        case .backend, .server, .account: .accountServer
        case .libraries: .libraries
        case .playback: .playback
        case .audioSubtitles: .audioSubtitles
        case .downloads: .downloads
        case .maintenance: .maintenance
        case .diagnostics: .diagnostics
        case .about: .about
        }
    }

    /// The form sections a category's detail pane shows, in form order.
    public static func sections(of category: SettingsCategory) -> [SettingsFormSection] {
        SettingsFormSection.allCases.filter { self.category(of: $0) == category }
    }

    /// Where the compact form scrolls to when it takes over from a category.
    public static func anchorSection(for category: SettingsCategory) -> SettingsFormSection {
        sections(of: category)[0]
    }

    /// The category the two-column layout selects when it takes over from the form: the section
    /// whose header is the last one at or above `topLine`, given each rendered header's last known
    /// top edge in the form's scroll-view coordinates. Above the first header, the first section.
    public static func category(headerTops: [SettingsFormSection: Double], topLine: Double) -> SettingsCategory {
        let current = SettingsFormSection.allCases.last { section in
            guard let top = headerTops[section], top.isFinite else { return false }
            return top <= topLine
        }
        return category(of: current ?? .backend)
    }

    /// The category selected when the two-column layout has nothing to restore.
    public static let defaultCategory: SettingsCategory = .accountServer

    /// Sidebar width. In book pose the split sits on the hinge, so the list is exactly the first
    /// page (`bookFirstHalfWidth`); otherwise about a third of the container, 280–360 pt.
    public static func sidebarWidth(containerWidth: Double, bookFirstHalfWidth: Double? = nil) -> Double {
        if let first = bookFirstHalfWidth, first.isFinite, first > 0 { return first.rounded(.down) }
        guard containerWidth.isFinite, containerWidth > 0 else { return 320 }
        return min(max((containerWidth * 0.34).rounded(.down), 280), 360)
    }
}
