import Testing
@testable import PMSKit

@Suite("Keychain synchronized credential migration policy")
struct KeychainSynchronizedCredentialMigrationPolicyTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let isSynchronized: Bool
        let primaryValueFound: Bool
        let legacyLocalValueFound: Bool
        let shouldDeleteLegacyLocal: Bool
        let shouldPromoteLegacyLocal: Bool

        var testDescription: String {
            "sync=\(isSynchronized) primary=\(primaryValueFound) legacy=\(legacyLocalValueFound)"
        }
    }

    @Test("Migration actions cover every (synchronized, primary, legacy) combination", arguments: [
        // Synchronized + primary found: always retire the legacy local token and never promote.
        // A global delete must not re-promote a stale local token after a primary read has
        // already retired it; (true, true, false) is the exact call KeychainStore.read makes
        // once the primary exists.
        Row(isSynchronized: true, primaryValueFound: true, legacyLocalValueFound: true,
            shouldDeleteLegacyLocal: true, shouldPromoteLegacyLocal: false),
        Row(isSynchronized: true, primaryValueFound: true, legacyLocalValueFound: false,
            shouldDeleteLegacyLocal: true, shouldPromoteLegacyLocal: false),
        // Synchronized, no primary: a pre-sync legacy local token still promotes.
        Row(isSynchronized: true, primaryValueFound: false, legacyLocalValueFound: true,
            shouldDeleteLegacyLocal: false, shouldPromoteLegacyLocal: true),
        Row(isSynchronized: true, primaryValueFound: false, legacyLocalValueFound: false,
            shouldDeleteLegacyLocal: false, shouldPromoteLegacyLocal: false),
        // Device-local accounts never run synchronized migration.
        Row(isSynchronized: false, primaryValueFound: true, legacyLocalValueFound: true,
            shouldDeleteLegacyLocal: false, shouldPromoteLegacyLocal: false),
        Row(isSynchronized: false, primaryValueFound: true, legacyLocalValueFound: false,
            shouldDeleteLegacyLocal: false, shouldPromoteLegacyLocal: false),
        Row(isSynchronized: false, primaryValueFound: false, legacyLocalValueFound: true,
            shouldDeleteLegacyLocal: false, shouldPromoteLegacyLocal: false),
        Row(isSynchronized: false, primaryValueFound: false, legacyLocalValueFound: false,
            shouldDeleteLegacyLocal: false, shouldPromoteLegacyLocal: false),
    ])
    func migrationActions(row: Row) {
        let actions = KeychainSynchronizedCredentialMigrationPolicy.actions(
            isSynchronized: row.isSynchronized,
            primaryValueFound: row.primaryValueFound,
            legacyLocalValueFound: row.legacyLocalValueFound)

        #expect(actions.shouldDeleteLegacyLocal == row.shouldDeleteLegacyLocal)
        #expect(actions.shouldPromoteLegacyLocal == row.shouldPromoteLegacyLocal)
    }
}
