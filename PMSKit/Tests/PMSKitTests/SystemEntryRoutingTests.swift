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
