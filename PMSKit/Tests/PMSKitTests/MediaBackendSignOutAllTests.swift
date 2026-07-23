import Testing
@testable import PMSKit

struct MediaBackendSignOutAllTests {
    @Test func completeSavedProfilesAreDetectedInStableProductOrder() {
        let snapshot = MediaBackendCredentialSnapshot(
            plexToken: "plex",
            jellyfinServerURLString: "https://jellyfin.invalid",
            jellyfinAccessToken: "jellyfin",
            jellyfinUserID: "user",
            embyServerURLString: "https://emby.invalid",
            embyAccessToken: "emby",
            embyUserID: "user")

        #expect(snapshot.savedAuthenticatedBackends == [.plex, .jellyfin, .emby])
        #expect(MediaBackendSignOutAllPresentation.shouldOfferAction(
            for: snapshot.savedAuthenticatedBackends))
        #expect(MediaBackendSignOutAllPresentation.affectedBackendsDescription(
            snapshot.savedAuthenticatedBackends) == "Plex, Jellyfin, and Emby")
    }

    @Test func partialProfilesAreNotPresentedAsAuthenticatedAccounts() {
        let snapshot = MediaBackendCredentialSnapshot(
            plexToken: "plex",
            jellyfinServerURLString: "https://jellyfin.invalid",
            jellyfinAccessToken: nil,
            jellyfinUserID: "user")

        #expect(snapshot.savedAuthenticatedBackends == [.plex])
        #expect(!MediaBackendSignOutAllPresentation.shouldOfferAction(
            for: snapshot.savedAuthenticatedBackends))
    }

    @Test func presentationDeduplicatesAndUsesCanonicalOrder() {
        let backends: [MediaBackendChoice] = [.emby, .plex, .emby]
        #expect(MediaBackendSignOutAllPresentation.shouldOfferAction(for: backends))
        #expect(MediaBackendSignOutAllPresentation.affectedBackendsDescription(backends)
                == "Plex and Emby")
    }

    @Test func confirmationAndCancelResolveToExplicitEffects() {
        #expect(MediaBackendSignOutAllPresentation.effect(for: .confirm) == .signOutAll)
        #expect(MediaBackendSignOutAllPresentation.effect(for: .cancel) == .none)
    }
}
