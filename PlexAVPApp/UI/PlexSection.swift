import PMSKit

/// Disambiguates the Plex library `Section` model from SwiftUI's `Section` view.
///
/// In files that `import SwiftUI`, a bare `Section` is ambiguous between
/// `PMSKit.Section` and `SwiftUI.Section`, and the qualified `PMSKit.Section`
/// resolves to the same-named `enum PMSKit` version namespace rather than the
/// model. This file imports only PMSKit, so `Section` here unambiguously names
/// the model; UI code refers to it as `PlexSection`.
typealias PlexSection = Section
