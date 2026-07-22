import Foundation

/// Canonical identity rules for rows in the offline download index.
///
/// Download rows live in one shared store even though Plex, Jellyfin, and Emby item ids come from
/// different namespaces. Plex keeps its historical bare ratingKey for compatibility; MediaBrowser
/// backends are prefixed so their item ids cannot collide with Plex rows or each other.
public enum DownloadRecordIdentity {
    public static let jellyfinPrefix = "jellyfin:"
    public static let embyPrefix = "emby:"

    /// Stable row key for a specific backend/item pair.
    public static func recordKey(for itemID: String, backend: DownloadBackendKind) -> String {
        switch backend {
        case .plex:
            return itemID
        case .jellyfin:
            return namespaced(itemID, prefix: jellyfinPrefix)
        case .emby:
            return namespaced(itemID, prefix: embyPrefix)
        }
    }

    /// Prefix-derived backend fallback for legacy rows without persisted `backendKind`.
    public static func backendKind(forRecordKey recordKey: String) -> DownloadBackendKind {
        if isJellyfinRecordKey(recordKey) { return .jellyfin }
        if isEmbyRecordKey(recordKey) { return .emby }
        return .plex
    }

    public static func isJellyfinRecordKey(_ recordKey: String) -> Bool {
        recordKey.hasPrefix(jellyfinPrefix)
    }

    public static func isEmbyRecordKey(_ recordKey: String) -> Bool {
        recordKey.hasPrefix(embyPrefix)
    }

    /// Backend-local item id carried by a row key. Passing a bare id is intentionally idempotent for
    /// Jellyfin/Emby retry paths that may be handed either an item id or a persisted row key.
    public static func itemID(fromRecordKey recordKey: String, backend: DownloadBackendKind) -> String {
        switch backend {
        case .plex:
            return recordKey
        case .jellyfin:
            return strip(prefix: jellyfinPrefix, from: recordKey)
        case .emby:
            return strip(prefix: embyPrefix, from: recordKey)
        }
    }

    public static func jellyfinItemID(fromRecordKey recordKey: String) -> String {
        itemID(fromRecordKey: recordKey, backend: .jellyfin)
    }

    public static func embyItemID(fromRecordKey recordKey: String) -> String {
        itemID(fromRecordKey: recordKey, backend: .emby)
    }

    private static func namespaced(_ itemID: String, prefix: String) -> String {
        itemID.hasPrefix(prefix) ? itemID : "\(prefix)\(itemID)"
    }

    private static func strip(prefix: String, from recordKey: String) -> String {
        recordKey.hasPrefix(prefix)
            ? String(recordKey.dropFirst(prefix.count))
            : recordKey
    }
}
