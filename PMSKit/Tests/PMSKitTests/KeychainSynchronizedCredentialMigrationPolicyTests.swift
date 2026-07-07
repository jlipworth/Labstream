import Testing
@testable import PMSKit

@Suite("Keychain synchronized credential migration policy")
struct KeychainSynchronizedCredentialMigrationPolicyTests {
    @Test("Reading synced primary retires legacy local token")
    func primaryReadRetiresLegacyLocalToken() {
        let actions = KeychainSynchronizedCredentialMigrationPolicy.actions(
            isSynchronized: true,
            primaryValueFound: true,
            legacyLocalValueFound: true)

        #expect(actions.shouldDeleteLegacyLocal)
        #expect(!actions.shouldPromoteLegacyLocal)
    }

    @Test("Global delete does not re-promote stale local token after primary cleanup")
    func globalDeleteDoesNotRePromoteStaleLocalToken() {
        var keychain = FakeSynchronizedTokenKeychain(syncedToken: "synced-token",
                                                     legacyLocalToken: "stale-local-token")

        #expect(keychain.readToken() == "synced-token")
        #expect(keychain.legacyLocalToken == nil)

        keychain.syncedToken = nil

        #expect(keychain.readToken() == nil)
        #expect(keychain.syncedToken == nil)
        #expect(keychain.legacyLocalToken == nil)
    }

    @Test("Pre-sync local token still promotes when no synced primary exists")
    func preSyncLocalTokenStillPromotes() {
        var keychain = FakeSynchronizedTokenKeychain(syncedToken: nil,
                                                     legacyLocalToken: "legacy-token")

        #expect(keychain.readToken() == "legacy-token")
        #expect(keychain.syncedToken == "legacy-token")
        #expect(keychain.legacyLocalToken == nil)
    }

    @Test("Device-local accounts do not run synchronized migration")
    func deviceLocalAccountsDoNotMigrate() {
        let actions = KeychainSynchronizedCredentialMigrationPolicy.actions(
            isSynchronized: false,
            primaryValueFound: true,
            legacyLocalValueFound: true)

        #expect(!actions.shouldDeleteLegacyLocal)
        #expect(!actions.shouldPromoteLegacyLocal)
    }
}

private struct FakeSynchronizedTokenKeychain {
    var syncedToken: String?
    var legacyLocalToken: String?

    mutating func readToken() -> String? {
        let primaryFound = syncedToken != nil
        var actions = KeychainSynchronizedCredentialMigrationPolicy.actions(
            isSynchronized: true,
            primaryValueFound: primaryFound,
            legacyLocalValueFound: legacyLocalToken != nil)

        if primaryFound {
            if actions.shouldDeleteLegacyLocal {
                legacyLocalToken = nil
            }
            return syncedToken
        }

        actions = KeychainSynchronizedCredentialMigrationPolicy.actions(
            isSynchronized: true,
            primaryValueFound: false,
            legacyLocalValueFound: legacyLocalToken != nil)

        if actions.shouldPromoteLegacyLocal, let legacyLocalToken {
            syncedToken = legacyLocalToken
            self.legacyLocalToken = nil
            return legacyLocalToken
        }

        return nil
    }
}
