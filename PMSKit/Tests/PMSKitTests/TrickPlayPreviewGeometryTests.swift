import Testing
@testable import PMSKit

struct TrickPlayPreviewGeometryTests {
    @Test func pointerPositionMapsToClampedTimelineTarget() {
        #expect(TrickPlayPreviewGeometry.targetMs(pointerX: -10, trackWidth: 200, durationMs: 120_000) == 0)
        #expect(TrickPlayPreviewGeometry.targetMs(pointerX: 50, trackWidth: 200, durationMs: 120_000) == 30_000)
        #expect(TrickPlayPreviewGeometry.targetMs(pointerX: 250, trackWidth: 200, durationMs: 120_000) == 120_000)
    }

    @Test func invalidTimelineGeometryHasNoTarget() {
        #expect(TrickPlayPreviewGeometry.targetMs(pointerX: 20, trackWidth: 0, durationMs: 120_000) == nil)
        #expect(TrickPlayPreviewGeometry.targetMs(pointerX: 20, trackWidth: 100, durationMs: 0) == nil)
    }

    @Test func cardCenterClampsAtBothEdges() {
        #expect(TrickPlayPreviewGeometry.cardCenterX(pointerX: 0, trackWidth: 500, cardWidth: 210) == 105)
        #expect(TrickPlayPreviewGeometry.cardCenterX(pointerX: 250, trackWidth: 500, cardWidth: 210) == 250)
        #expect(TrickPlayPreviewGeometry.cardCenterX(pointerX: 500, trackWidth: 500, cardWidth: 210) == 395)
    }

    @Test func cardWiderThanTrackFallsBackToTrackCenter() {
        #expect(TrickPlayPreviewGeometry.cardCenterX(pointerX: 0, trackWidth: 100, cardWidth: 210) == 50)
        #expect(TrickPlayPreviewGeometry.cardCenterX(pointerX: 100, trackWidth: 100, cardWidth: 210) == 50)
    }
}
