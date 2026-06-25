import Foundation
import Testing
@testable import PMSKit

/// Pins the Libraries-grid track math (#124): rigid 300pt section cards bunched edge-to-edge
/// on a transiently-narrow first layout pass because the adaptive column minimum (260) sat
/// below the card width, letting the grid pack two tracks narrower than the card into a width
/// that only comfortably holds one. The fix pins the adaptive minimum to the 300pt card width,
/// so the grid forms one *correctly sized* column there instead of two sub-card tracks.
@Suite("Library grid layout")
struct LibraryGridLayoutTests {

    // The shipping parameters: 300pt cards, DS.Space.xl == 24 spacing.
    static let cardWidth: Double = 300
    static let spacing: Double = 24
    static let oldMin: Double = 260   // pre-fix: below card width → can pack sub-card tracks
    static let newMin: Double = 300   // fix: == card width → no sub-card multi-column pack
    static let maxTrack: Double = 340

    // MARK: - The width that distinguishes the fix

    @Test("a narrow-ish width packs two sub-card tracks under the OLD min (260) but one clean track under the new min (300)")
    func narrowWidthCollapsesUnderOldMinOnly() {
        // 580pt: enough for one 300 card + gap, but the old adaptive(260…340) greedily fits TWO
        // 260-eligible tracks, sizing each to ~278pt — narrower than the 300 card, so both cards
        // overflow their tracks and bunch with no gap. This is the reported first-pass collapse.
        let old = LibraryGridLayout.resolve(width: 580, cardWidth: Self.cardWidth,
                                            minTrack: Self.oldMin, maxTrack: Self.maxTrack,
                                            spacing: Self.spacing)
        #expect(old.columnCount == 2)
        #expect(old.collapsesSpacing == true)
        #expect(old.trackWidth < Self.cardWidth)

        // Same width under the fix: min == card width, so a second track can't fit (300+24+300
        // > 580). The grid forms ONE track sized to the card max — cards never overflow, no
        // collapse, and the leftover becomes outer margin rather than a sub-card track.
        let new = LibraryGridLayout.resolve(width: 580, cardWidth: Self.cardWidth,
                                            minTrack: Self.newMin, maxTrack: Self.maxTrack,
                                            spacing: Self.spacing)
        #expect(new.columnCount == 1)
        #expect(new.collapsesSpacing == false)
        #expect(new.trackWidth >= Self.cardWidth)
    }

    // MARK: - Comfortable width

    @Test("a comfortable width yields the expected multi-column count with non-negative gaps")
    func comfortableWidthFormsMultipleGappedColumns() {
        // 1000pt with newMin 300 and spacing 24: floor((1000 + 24) / (300 + 24)) = 3 columns.
        let layout = LibraryGridLayout.resolve(width: 1000, cardWidth: Self.cardWidth,
                                               minTrack: Self.newMin, maxTrack: Self.maxTrack,
                                               spacing: Self.spacing)
        #expect(layout.columnCount == 3)
        #expect(layout.collapsesSpacing == false)
        #expect(layout.trackWidth >= Self.cardWidth)

        // The gap is real: 3 tracks + 2 spacings fit within the width with room to spare,
        // so the leftover (width - cards - gaps) is non-negative.
        let leftover = 1000 - (layout.trackWidth * Double(layout.columnCount)
                               + Self.spacing * Double(layout.columnCount - 1))
        #expect(leftover >= 0)
    }

    @Test("the column count never drops below one even at zero width")
    func neverFewerThanOneColumn() {
        let layout = LibraryGridLayout.resolve(width: 0, cardWidth: Self.cardWidth,
                                               minTrack: Self.newMin, maxTrack: Self.maxTrack,
                                               spacing: Self.spacing)
        #expect(layout.columnCount == 1)
    }
}
