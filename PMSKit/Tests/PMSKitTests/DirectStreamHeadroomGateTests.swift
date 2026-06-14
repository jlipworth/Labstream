import Testing
@testable import PMSKit

@Test func headroomGateDisabledRequiresNoEvidence() {
    let gate = DirectStreamHeadroomGate(isEnabled: false, observedThroughputKbps: nil)

    #expect(gate.verdict(sourceBitrateKbps: nil) == .notRequired)
    #expect(gate.verdict(sourceBitrateKbps: nil).allowsDirectStream)
}

@Test func headroomGateBlocksWhenSourceBitrateMissing() {
    let gate = DirectStreamHeadroomGate(isEnabled: true, observedThroughputKbps: 20_000)

    #expect(gate.verdict(sourceBitrateKbps: nil) == .blocked(.missingSourceBitrate))
}

@Test func headroomGateBlocksWhenThroughputEstimateMissing() {
    let gate = DirectStreamHeadroomGate(isEnabled: true, observedThroughputKbps: nil)

    #expect(gate.verdict(sourceBitrateKbps: 10_000) == .blocked(.missingThroughputEstimate))
}

@Test func headroomGateBlocksWhenObservedThroughputLacksHeadroom() {
    let gate = DirectStreamHeadroomGate(isEnabled: true, observedThroughputKbps: 12_499)

    #expect(gate.verdict(sourceBitrateKbps: 10_000) == .blocked(.insufficientThroughput(sourceKbps: 10_000, requiredKbps: 12_500, observedKbps: 12_499)))
}

@Test func headroomGateAllowsWhenObservedThroughputHasConfiguredHeadroom() {
    let gate = DirectStreamHeadroomGate(isEnabled: true, observedThroughputKbps: 12_500)

    #expect(gate.verdict(sourceBitrateKbps: 10_000) == .allowed(sourceKbps: 10_000, requiredKbps: 12_500, observedKbps: 12_500))
}

@Test func sourceBitrateUsesSelectedMediaIndex() {
    let item = MediaItem(ratingKey: "101", key: "/library/metadata/101", title: "Example", type: "movie",
                         media: [
                            Media(id: 1, bitrate: 4_000, part: []),
                            Media(id: 2, bitrate: 18_000, part: [])
                         ])

    #expect(DirectStreamHeadroomGate.sourceBitrateKbps(for: item, mediaIndex: 1) == 18_000)
}
