import Foundation

/// Pure, backend-agnostic logic for the "choose which libraries are displayed" feature (GH #104).
///
/// Persists a per-backend Set of **hidden** library ids (so a library added server-side later
/// defaults to visible without re-prompting) keyed by a token-free backend identity. Lives in
/// PMSKit so the store/filter/key/preselection/prompt-gating are unit-testable without a simulator.
///
/// The store deliberately does NOT reuse the app's load-cache keys (`loadIdentity`), which include
/// the auth token on purpose to bust on re-auth. Re-auth changes the token but not the server/user
/// identity, so this persistence must survive it — hence the token-free key below.
public enum LibraryVisibility {

    // MARK: - Backend key

    /// The stable, token-free backend identity used to scope hidden-set persistence.
    ///
    /// `id` falls back to the server base-URL host for legacy sessions that never recorded a
    /// server id; a fully unresolvable identity yields `nil`, which callers treat as "all visible".
    public static func backendKey(backend: MediaBackendChoice,
                                  serverID: String?,
                                  baseURLHost: String?) -> String? {
        let resolved = nonEmpty(serverID) ?? nonEmpty(baseURLHost)
        guard let resolved else { return nil }
        switch backend {
        case .plex:     return "plex:\(resolved)"
        case .jellyfin: return "jellyfin:\(resolved)"
        case .emby:     return "emby:\(resolved)"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    // MARK: - Visibility filter

    /// Filters a backend's library list to the visible ones, given the set of hidden ids.
    ///
    /// A library whose id is NOT in `hiddenIDs` is visible — so an id the server adds later
    /// (never recorded as hidden) defaults to visible. Order is preserved.
    public static func visible<Library>(_ libraries: [Library],
                                        hiddenIDs: Set<String>,
                                        id: (Library) -> String) -> [Library] {
        guard !hiddenIDs.isEmpty else { return libraries }
        return libraries.filter { !hiddenIDs.contains(id($0)) }
    }

    // MARK: - First-run noise pre-selection

    /// A library candidate presented in the first-run picker. `kind` is the backend-agnostic
    /// `LibrarySectionKind`-equivalent (lower-cased), and `title` lets us catch Plex "Trailers"
    /// libraries, which are not a distinct type.
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let title: String
        /// Lower-cased kind token, e.g. "collections" / "folders" / "homevideos" / "movies".
        public let kind: String

        public init(id: String, title: String, kind: String) {
            self.id = id
            self.title = title
            self.kind = kind
        }
    }

    /// Kinds the first-run prompt pre-checks as "hide" by default. These are the common
    /// non-primary-content libraries (collections views, generic folder roots, home-video dumps).
    public static let noiseKinds: Set<String> = ["collections", "folders", "homevideos"]

    /// The set of candidate ids the first-run picker should pre-select for hiding.
    ///
    /// This is ONLY the prompt's initial checkbox state, which the user confirms — nothing is
    /// hidden until they accept. Pre-checks the known-noise `kinds` plus any library whose title
    /// reads as Trailers/extras (Plex surfaces these as ordinary sections, so a type filter alone
    /// can't catch them).
    public static func defaultHiddenSelection(from candidates: [Candidate]) -> Set<String> {
        var hidden: Set<String> = []
        for candidate in candidates {
            if noiseKinds.contains(candidate.kind.lowercased()) || titleReadsAsExtras(candidate.title) {
                hidden.insert(candidate.id)
            }
        }
        return hidden
    }

    private static func titleReadsAsExtras(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.contains("trailer") || lowered.contains("extras")
    }
}

// MARK: - UserDefaults-backed store

/// Reads/writes the per-backend hidden-set and the once-per-backend prompt flag.
///
/// Pure aside from the injected `UserDefaults`, so tests pass a throwaway suite. Storage shape:
/// - `libraryVisibility.hidden.<backendKey>` → `[String]` (JSON) of hidden library ids.
/// - `libraryVisibility.promptShown.<backendKey>` → `Bool`.
public struct LibraryVisibilityStore {
    public static let didChangeNotification = Notification.Name("LibraryVisibilityStore.didChange")
    public static let didChangeBackendKeyUserInfoKey = "backendKey"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func hiddenKey(_ backendKey: String) -> String { "libraryVisibility.hidden.\(backendKey)" }
    private func promptKey(_ backendKey: String) -> String { "libraryVisibility.promptShown.\(backendKey)" }

    /// The hidden-id set for a backend key. A nil key (unresolved identity) is "nothing hidden".
    public func hiddenIDs(forBackendKey backendKey: String?) -> Set<String> {
        guard let backendKey else { return [] }
        guard let data = defaults.data(forKey: hiddenKey(backendKey)),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    public func setHiddenIDs(_ ids: Set<String>, forBackendKey backendKey: String?) {
        guard let backendKey else { return }
        let previous = hiddenIDs(forBackendKey: backendKey)
        if ids.isEmpty {
            defaults.removeObject(forKey: hiddenKey(backendKey))
            postChangeIfNeeded(previous: previous, current: ids, backendKey: backendKey)
            return
        }
        let data = (try? JSONEncoder().encode(ids.sorted())) ?? Data()
        defaults.set(data, forKey: hiddenKey(backendKey))
        postChangeIfNeeded(previous: previous, current: ids, backendKey: backendKey)
    }

    /// Toggle a single library's hidden state, returning the updated set.
    @discardableResult
    public func toggle(id: String, hidden: Bool, forBackendKey backendKey: String?) -> Set<String> {
        var current = hiddenIDs(forBackendKey: backendKey)
        if hidden { current.insert(id) } else { current.remove(id) }
        setHiddenIDs(current, forBackendKey: backendKey)
        return current
    }

    public func isHidden(id: String, forBackendKey backendKey: String?) -> Bool {
        hiddenIDs(forBackendKey: backendKey).contains(id)
    }

    /// Whether the first-run picker has already been shown for this backend key. A nil key is
    /// treated as "already shown" so we never prompt against an unresolved identity.
    public func hasShownPrompt(forBackendKey backendKey: String?) -> Bool {
        guard let backendKey else { return true }
        return defaults.bool(forKey: promptKey(backendKey))
    }

    public func markPromptShown(forBackendKey backendKey: String?) {
        guard let backendKey else { return }
        defaults.set(true, forKey: promptKey(backendKey))
    }

    private func postChangeIfNeeded(previous: Set<String>, current: Set<String>, backendKey: String) {
        guard previous != current else { return }
        NotificationCenter.default.post(name: Self.didChangeNotification,
                                        object: nil,
                                        userInfo: [Self.didChangeBackendKeyUserInfoKey: backendKey])
    }
}
