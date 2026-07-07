/// Pure migration decisions for an account that moved from a device-local keychain item to
/// an iCloud-synchronizable item.
///
/// The app layer owns the actual Security.framework calls. Keeping the tiny state machine here
/// makes the sign-out edge case testable without touching a real keychain:
/// once a synced primary item has been observed, the legacy non-synchronizable item must be
/// deleted so a later iCloud/global delete cannot re-promote a stale local credential.
public enum KeychainSynchronizedCredentialMigrationPolicy {
    public struct ReadActions: Sendable, Equatable {
        public let shouldDeleteLegacyLocal: Bool
        public let shouldPromoteLegacyLocal: Bool
    }

    public static func actions(isSynchronized: Bool,
                               primaryValueFound: Bool,
                               legacyLocalValueFound: Bool) -> ReadActions {
        guard isSynchronized else {
            return ReadActions(shouldDeleteLegacyLocal: false,
                               shouldPromoteLegacyLocal: false)
        }

        if primaryValueFound {
            return ReadActions(shouldDeleteLegacyLocal: true,
                               shouldPromoteLegacyLocal: false)
        }

        return ReadActions(shouldDeleteLegacyLocal: false,
                           shouldPromoteLegacyLocal: legacyLocalValueFound)
    }
}
