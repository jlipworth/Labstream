import Foundation
import Testing
@testable import PMSKit

struct DownloadsLayoutPolicyTests {
    @Test func compactWidthIsOneFullColumn() {
        #expect(DownloadsLayoutPolicy.layout(width: 382, height: 644, regularWidth: false, pagePadding: 16)
                == .list(horizontalInset: 16))
        #expect(DownloadsLayoutPolicy.layout(width: 594, height: 466, regularWidth: false, pagePadding: 16)
                == .list(horizontalInset: 16))
    }

    @Test func uprightCapsRowsAt560AndCentres() {
        #expect(DownloadsLayoutPolicy.layout(width: 669, height: 900, regularWidth: true, pagePadding: 24)
                == .list(horizontalInset: 54.5))
        // A narrower regular pane keeps the page padding.
        #expect(DownloadsLayoutPolicy.layout(width: 580, height: 900, regularWidth: true, pagePadding: 24)
                == .list(horizontalInset: 24))
    }

    @Test func sidewaysIsListPlusDetail() {
        #expect(DownloadsLayoutPolicy.layout(width: 900, height: 669, regularWidth: true, pagePadding: 24)
                == .split(listWidth: 405, detailStart: 405))
    }

    @Test func bookPutsTheDividerOnTheHinge() {
        #expect(DownloadsLayoutPolicy.layout(width: 867, height: 669, regularWidth: true, pagePadding: 24,
                                             hinge: (465.5, 485.5))
                == .split(listWidth: 465.5, detailStart: 485.5))
    }
}
