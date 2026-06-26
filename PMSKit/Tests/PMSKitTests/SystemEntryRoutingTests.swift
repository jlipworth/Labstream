import Foundation
import Testing
@testable import PMSKit

@Suite("System entry routing")
struct SystemEntryRoutingTests {
    @Test func searchIdentifierAddsServerNamespaceAndStripsItBack() throws {
        let server = try #require(URL(string: "https://plex.example.test:32400"))

        let identifier = MediaSearchIdentifier.make(ratingKey: "12345", server: server)

        #expect(identifier == "plex.example.test:32400|12345")
        #expect(MediaSearchIdentifier.ratingKey(from: identifier) == "12345")
    }

    @Test func searchIdentifierKeepsBareRatingKeysForLegacySpotlightResults() {
        #expect(MediaSearchIdentifier.ratingKey(from: "98765") == "98765")
    }

    @Test func searchIdentifierPreservesRatingKeysContainingSeparator() throws {
        let server = try #require(URL(string: "https://plex.example.test"))

        let identifier = MediaSearchIdentifier.make(ratingKey: "plex://movie|abc", server: server)

        #expect(MediaSearchIdentifier.ratingKey(from: identifier) == "plex://movie|abc")
    }


    @Test func backendScopedIdentifierCarriesBackendServerAndRatingKey() throws {
        let server = try #require(URL(string: "https://emby.example.test:8096/emby"))

        let identifier = MediaSearchIdentifier.make(ratingKey: "items/abc|part", server: server, backend: .emby)
        let route = MediaSearchIdentifier.routeKey(from: identifier)

        #expect(identifier == "vp1|emby|emby.example.test:8096|items/abc|part")
        #expect(route == BackendScopedMediaID(backend: .emby,
                                             serverNamespace: "emby.example.test:8096",
                                             ratingKey: "items/abc|part"))
        #expect(MediaSearchIdentifier.ratingKey(from: identifier) == "items/abc|part")
    }

    @Test func legacyServerScopedIdentifierParsesAsPlexRouteKey() throws {
        let legacy = "plex.example.test:32400|plex://movie|abc"
        let route = MediaSearchIdentifier.routeKey(from: legacy)

        #expect(route.backend == .plex)
        #expect(route.serverNamespace == "plex.example.test:32400")
        #expect(route.ratingKey == "plex://movie|abc")
    }

    @Test func bareLegacyIdentifierParsesAsPlexRouteKey() {
        let route = MediaSearchIdentifier.routeKey(from: "98765")

        #expect(route.backend == .plex)
        #expect(route.serverNamespace == nil)
        #expect(route.ratingKey == "98765")
    }

    @Test func backendScopedIdentifierAllowsMissingServerNamespace() {
        let id = BackendScopedMediaID(backend: .jellyfin, ratingKey: "abc").identifier
        let route = MediaSearchIdentifier.routeKey(from: id)

        #expect(id == "vp1|jellyfin||abc")
        #expect(route.backend == .jellyfin)
        #expect(route.serverNamespace == nil)
        #expect(route.ratingKey == "abc")
    }

    @Test func autoPlayGateConsumesMatchingFreshArmOnce() throws {
        let start = try #require(DateComponents(calendar: .current, year: 2026, month: 6, day: 16).date)
        var gate = PendingAutoPlayGate()

        gate.arm(ratingKey: "abc", now: start)

        #expect(gate.consume(ratingKey: "abc", now: start.addingTimeInterval(2)) == true)
        #expect(gate.consume(ratingKey: "abc", now: start.addingTimeInterval(3)) == false)
    }

    @Test func autoPlayGateIgnoresDifferentRatingKeyWithoutConsumingArm() throws {
        let start = try #require(DateComponents(calendar: .current, year: 2026, month: 6, day: 16).date)
        var gate = PendingAutoPlayGate()

        gate.arm(ratingKey: "wanted", now: start)

        #expect(gate.consume(ratingKey: "other", now: start.addingTimeInterval(1)) == false)
        #expect(gate.consume(ratingKey: "wanted", now: start.addingTimeInterval(2)) == true)
    }

    @Test func autoPlayGateConsumesButRejectsStaleArm() throws {
        let start = try #require(DateComponents(calendar: .current, year: 2026, month: 6, day: 16).date)
        var gate = PendingAutoPlayGate()

        gate.arm(ratingKey: "abc", now: start)

        #expect(gate.consume(ratingKey: "abc", now: start.addingTimeInterval(31)) == false)
        #expect(gate.consume(ratingKey: "abc", now: start.addingTimeInterval(32)) == false)
    }
}
