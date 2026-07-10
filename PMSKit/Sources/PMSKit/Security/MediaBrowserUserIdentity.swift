import Foundation

/// GUID-format-insensitive comparison for Jellyfin/Emby (Media Browser) user ids.
///
/// A saved user id is compared against the id echoed by a live identity probe to confirm a
/// restored session still belongs to the same account. Media Browser servers can serialize the
/// same GUID in different canonical forms across versions and behind reverse proxies — dashed
/// (`4c1a…-…`) vs dashless (`4c1a……`), upper vs lower case — so raw string equality can report a
/// spurious mismatch for what is actually the same user. Normalize before comparing.
public enum MediaBrowserUserIdentity {
    /// Canonical form used for equality: dashes stripped, lower-cased.
    public static func normalized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// True when two ids denote the same user regardless of GUID formatting.
    public static func sameUser(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }
}
