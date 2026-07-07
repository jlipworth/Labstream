import SwiftUI
import PMSKit

/// The trailing A–Z jump rail shared by the movies/TV `LibraryGridView` and the music
/// `MusicPagedGrid` (#96, #111). Each entry scrolls the grid to the first item under that
/// character; the offset math lives in `AlphabetBucket`, so every backend's rail jumps to
/// the same place. Extracted from `LibraryGridView` so the music grids reuse it verbatim.
///
/// A full A–Z+# rail is ~610 pt tall — taller than iPhone landscape or a short iPad
/// Split View pane — so the rail thins itself (every 2nd/3rd/4th bucket) until it fits
/// the height it's offered instead of clipping the ends off-screen unreachably.
struct LibraryAlphabetRail: View {
    let entries: [AlphabetBucket]
    let onPick: (AlphabetBucket) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            railColumn(thinning: 1)
            railColumn(thinning: 2)
            railColumn(thinning: 3)
            railColumn(thinning: 4)
        }
    }

    private func railColumn(thinning step: Int) -> some View {
        let shown = stride(from: 0, to: entries.count, by: step).map { entries[$0] }
        return AlphabetRailColumn(entries: shown, onPick: onPick)
    }
}

/// One concrete rail column (a specific thinning level). Owns the drag-to-scrub
/// state so each `ViewThatFits` candidate maps finger position against its own rows.
private struct AlphabetRailColumn: View {
    let entries: [AlphabetBucket]
    let onPick: (AlphabetBucket) -> Void

    /// Last bucket index delivered during an active scrub — dedupes onChanged spam.
    @State private var scrubIndex: Int?

    /// Row geometry shared by layout and the scrub math (20-pt row + 2-pt spacing).
    private let rowHeight: CGFloat = 20
    private let rowSpacing: CGFloat = 2
    private let verticalPadding: CGFloat = 8

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(entries, id: \.display) { entry in
                Button {
                    onPick(entry)
                } label: {
                    Text(entry.display)
                        .font(.caption2.weight(.semibold))
                        .monospaced()
                        .frame(width: 26, height: rowHeight)
                }
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8, style: .continuous))
                .hoverEffect(.highlight)
                .accessibilityLabel("Jump to \(entry.display)")
            }
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: Capsule())
        #if os(iOS)
        // Section-index scrub: the 20-pt rows are precise enough for a pointer or
        // gaze but not a fingertip, so a drag anywhere on the capsule sweeps through
        // buckets UITableView-style. simultaneousGesture keeps plain taps on the
        // per-letter buttons working.
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    let pitch = rowHeight + rowSpacing
                    let raw = Int((value.location.y - verticalPadding) / pitch)
                    let index = min(max(raw, 0), entries.count - 1)
                    guard index != scrubIndex else { return }
                    scrubIndex = index
                    onPick(entries[index])
                }
                .onEnded { _ in scrubIndex = nil }
        )
        #endif
    }
}
