import PlexKit

/// Disambiguates the Plex library `Section` model from SwiftUI's `Section` view.
///
/// In files that `import SwiftUI`, a bare `Section` is ambiguous between
/// `PlexKit.Section` and `SwiftUI.Section`, and the qualified `PlexKit.Section`
/// resolves to the same-named `enum PlexKit` version namespace rather than the
/// model. This file imports only PlexKit, so `Section` here unambiguously names
/// the model; UI code refers to it as `PlexSection`.
typealias PlexSection = Section
