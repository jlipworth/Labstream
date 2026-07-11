import Testing
@testable import PMSKit

struct MobileDetailArtworkPolicyTests {
    @Test func backdropWinsOverPoster() {
        #expect(MobileDetailArtworkPolicy.selection(art: "/art", thumb: "/poster") == .landscape(path: "/art"))
    }

    @Test func blankBackdropFallsBackToPoster() {
        #expect(MobileDetailArtworkPolicy.selection(art: "  ", thumb: "/poster") == .croppedPoster(path: "/poster"))
    }

    @Test func blankPosterIsTreatedAsMissing() {
        #expect(MobileDetailArtworkPolicy.selection(art: nil, thumb: "") == .none)
    }
}
