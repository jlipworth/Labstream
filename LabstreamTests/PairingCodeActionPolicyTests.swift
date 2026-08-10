import Foundation
import PMSKit
import Testing
@testable import Labstream

struct PairingCodeActionPolicyTests {
    @Test func browserHandoffsAreBackendSpecific() {
        #expect(PairingCodeActionPolicy.browserHandoff(for: .jellyfin) == .copyOnly)
        #expect(PairingCodeActionPolicy.browserHandoff(for: .plex)
                == .copyAndOpen(URL(string: "https://plex.tv/link")!))
        #expect(PairingCodeActionPolicy.browserHandoff(for: .emby)
                == .copyAndOpen(URL(string: "https://emby.media/pin.html")!))
    }

    @Test func plexEmbeddedAuthURLDoesNotRequestDisplayCodeCopy() {
        let url = URL(string: "https://app.plex.tv/auth#?clientID=fixture")!
        #expect(PairingCodeActionPolicy.plexEmbeddedHandoff(url: url) == .openEmbeddedCodeURL(url))
    }
}
