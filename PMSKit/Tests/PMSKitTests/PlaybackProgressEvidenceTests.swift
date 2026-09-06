import Foundation
import Testing
@testable import PMSKit

struct PlaybackProgressEvidenceTests {
    private func fixture() -> PlaybackProgressEvidence {
        .init(evidenceKind: "synthetic", backend: "fixture", generation: 1, holdSeconds: 60,
              stallToleranceSeconds: 10, samples: (0...60).map {
            .init(elapsedSeconds: Double($0), positionSeconds: Double($0), phase: .playing, generation: 1)
        })
    }
    @Test func sustainedProgress() { #expect(fixture().evaluate().status == .passed) }
    @Test(arguments: [PlaybackProgressEvidence.Phase.paused, .waiting, .playing])
    func threeSecondsThenFrozenFails(phase: PlaybackProgressEvidence.Phase) {
        var evidence = fixture()
        evidence.samples = evidence.samples.map {
            .init(elapsedSeconds: $0.elapsedSeconds, positionSeconds: min(3, $0.positionSeconds),
                  phase: $0.elapsedSeconds > 3 ? phase : .playing, generation: 1)
        }
        #expect(evidence.evaluate().reason == .sustainedNonprogress)
    }
    @Test func staleGenerationAndSeekAndGapsBlock() {
        var evidence = fixture()
        evidence.samples[60] = .init(elapsedSeconds: 60, positionSeconds: 60, phase: .playing, generation: 2)
        #expect(evidence.evaluate().reason == .staleGeneration)
        evidence.samples[60] = .init(elapsedSeconds: 60, positionSeconds: 600, phase: .playing, generation: 1)
        #expect(evidence.evaluate().reason == .timelineDiscontinuity)
        evidence.samples = [evidence.samples[0], evidence.samples[60]]
        #expect(evidence.evaluate().reason == .observationGap)
    }
    @Test func cancellationFailureAndInvalidNumbersNeverPass() {
        for phase in [PlaybackProgressEvidence.Phase.cancelled, .failed] {
            var evidence = fixture()
            evidence.samples[60] = .init(elapsedSeconds: 60, positionSeconds: 60, phase: phase, generation: 1)
            #expect(evidence.evaluate().status != .passed)
        }
        var evidence = fixture()
        evidence.samples[1] = .init(elapsedSeconds: 1, positionSeconds: .nan, phase: .playing, generation: 1)
        #expect(evidence.evaluate().reason == .invalidEvidence)
    }
    @Test func jsonHasOnlyContractFields() throws {
        let data = try JSONEncoder().encode(fixture())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["schemaVersion", "evidenceKind", "backend", "generation", "holdSeconds", "stallToleranceSeconds", "samples"]))
    }
}
