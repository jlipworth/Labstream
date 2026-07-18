import Testing
@testable import PMSKit

@Suite("SharePlay playback attachment revision (#198)")
struct SharePlayPlaybackAttachmentRevisionTests {
    @Test("An unchanged item must reattach when the group session is replaced")
    func replacementSessionChangesRevision() {
        let first = SharePlayPlaybackAttachmentRevision(sessionGeneration: 1, itemID: "item-a")
        let replacement = SharePlayPlaybackAttachmentRevision(sessionGeneration: 2, itemID: "item-a")

        #expect(first != replacement)
    }

    @Test("A replacement player item must reattach within the same group session")
    func replacementItemChangesRevision() {
        let first = SharePlayPlaybackAttachmentRevision(sessionGeneration: 1, itemID: "item-a")
        let replacement = SharePlayPlaybackAttachmentRevision(sessionGeneration: 1, itemID: "item-b")

        #expect(first != replacement)
    }

    @Test("A successfully attached item and session remain idempotent")
    func unchangedAttachmentIsEqual() {
        let first = SharePlayPlaybackAttachmentRevision(sessionGeneration: 7, itemID: "item-a")
        let repeated = SharePlayPlaybackAttachmentRevision(sessionGeneration: 7, itemID: "item-a")

        #expect(first == repeated)
    }
}
