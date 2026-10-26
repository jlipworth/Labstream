#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import PMSKit

struct DuoPoseLayoutTests {
    // Inner display sideways (book) with the vertical bar on either edge; the content region
    // excludes the bar's inset, so the hinge sits off-centre in it.
    @Test(arguments: [
        // Trailing bar: content 0..855.
        (CGRect(x: 0, y: 0, width: 855, height: 669), 465.0, 485.0),
        // Leading bar: content 96..951.
        (CGRect(x: 96, y: 0, width: 855, height: 669), 465.0, 485.0),
    ])
    func bookSplitsTheContentRegionAroundTheHinge(region: CGRect, hingeMinX: Double, hingeMaxX: Double) {
        let hinge = CGRect(x: hingeMinX, y: 0, width: hingeMaxX - hingeMinX, height: 669)
        let layout = DuoPoseLayout(input: .book(hinge: hinge), contentRegion: region)
        #expect(layout.kind == .book)
        #expect(layout.firstHalf == CGRect(x: region.minX, y: 0, width: hingeMinX - region.minX, height: 669))
        #expect(layout.secondHalf == CGRect(x: hingeMaxX, y: 0, width: region.maxX - hingeMaxX, height: 669))
        #expect(layout.hinge == hinge)
        #expect(layout.columnSplit(4) == (2, 2))
    }

    @Test func tabletopSplitsTopAndBottom() {
        let region = CGRect(x: 0, y: 0, width: 669, height: 951)
        let hinge = CGRect(x: 0, y: 465.5, width: 669, height: 20)
        let layout = DuoPoseLayout(input: .tabletop(hinge: hinge), contentRegion: region)
        #expect(layout.kind == .tabletop)
        #expect(layout.firstHalf == CGRect(x: 0, y: 0, width: 669, height: 465.5))
        #expect(layout.secondHalf == CGRect(x: 0, y: 485.5, width: 669, height: 465.5))
        #expect(layout.columnSplit(3) == (3, 0))
    }

    @Test func flatUsesTheWholeRegion() {
        let region = CGRect(x: 0, y: 0, width: 378, height: 678)
        let layout = DuoPoseLayout(input: .flat, contentRegion: region)
        #expect(layout.kind == .flat)
        #expect(layout.hinge == nil)
        #expect(layout.firstHalf == region)
        #expect(layout.secondHalf == region)
        #expect(layout.columnSplit(3) == (3, 0))
    }

    @Test func aHingeOutsideTheContentRegionIsFlat() {
        let region = CGRect(x: 500, y: 0, width: 355, height: 669)
        let hinge = CGRect(x: 465, y: 0, width: 20, height: 669)
        #expect(DuoPoseLayout(input: .book(hinge: hinge), contentRegion: region).kind == .flat)
    }

    @Test func classifyReadsTheDivisionStripShape() {
        #expect(DuoPoseInput.classify(division: nil) == .flat)
        #expect(DuoPoseInput.classify(division: .zero) == .flat)
        let vertical = CGRect(x: 465, y: 0, width: 20, height: 669)
        #expect(DuoPoseInput.classify(division: vertical) == .book(hinge: vertical))
        let horizontal = CGRect(x: 0, y: 465, width: 669, height: 20)
        #expect(DuoPoseInput.classify(division: horizontal) == .tabletop(hinge: horizontal))
        // A zero-thickness fold line still classifies by its axis.
        let line = CGRect(x: 475, y: 0, width: 0, height: 669)
        #expect(DuoPoseInput.classify(division: line) == .book(hinge: line))
    }

    #if DEBUG
    @Test func overrideParserReadsEnvironmentAndArgument() {
        #expect(DuoPoseOverride.parse(environment: [:], arguments: []) == nil)
        #expect(DuoPoseOverride.parse(environment: ["LABSTREAM_DEBUG_DUO_POSE": "book"], arguments: []) == .book)
        #expect(DuoPoseOverride.parse(environment: ["LABSTREAM_DEBUG_DUO_POSE": " Tabletop "], arguments: []) == .tabletop)
        #expect(DuoPoseOverride.parse(environment: ["LABSTREAM_DEBUG_DUO_POSE": "book"],
                                      arguments: ["--labstream-debug-duo-pose", "tabletop"]) == .tabletop)
    }

    @Test func overrideParserFallsBackToFlatForUnknownValues() {
        #expect(DuoPoseOverride.parse(environment: ["LABSTREAM_DEBUG_DUO_POSE": "laptop"], arguments: []) == .flat)
        #expect(DuoPoseOverride.parse(environment: [:], arguments: ["--labstream-debug-duo-pose", ""]) == .flat)
    }

    @Test func overrideSynthesisesACentredHingeOnlyInTheMatchingOrientation() {
        let sideways = CGRect(x: 0, y: 0, width: 951, height: 669)
        let upright = CGRect(x: 0, y: 0, width: 669, height: 951)
        #expect(DuoPoseOverride.book.input(in: sideways)
            == .book(hinge: CGRect(x: 465.5, y: 0, width: 20, height: 669)))
        #expect(DuoPoseOverride.book.input(in: upright) == .flat)
        #expect(DuoPoseOverride.tabletop.input(in: upright)
            == .tabletop(hinge: CGRect(x: 0, y: 465.5, width: 669, height: 20)))
        #expect(DuoPoseOverride.tabletop.input(in: sideways) == .flat)
        #expect(DuoPoseOverride.flat.input(in: sideways) == .flat)
    }
    #endif
}
