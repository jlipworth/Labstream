import SwiftUI
import PMSKit

/// The trailing A–Z jump rail shared by the movies/TV `LibraryGridView` and the music
/// `MusicPagedGrid` (#96, #111). Each entry scrolls the grid to the first item under that
/// character; the offset math lives in `AlphabetBucket`, so every backend's rail jumps to
/// the same place. Extracted from `LibraryGridView` so the music grids reuse it verbatim.
///
/// SwiftUI 26's native `.sectionIndexLabel` / `.listSectionIndexVisibility` is the
/// long-term ideal for `List`/`Section` content, but these browse surfaces are paged
/// `LazyVGrid`s. Until the grids move to a native sectioned container, keep this custom
/// control visually close to UIKit's section index on iOS/iPadOS: a lightweight trailing
/// stack of tinted glyphs, not a glass capsule full of mini buttons. visionOS keeps a
/// material backing because gaze needs a stronger acquisition target in space.
///
/// A full A–Z+# rail is taller than iPhone landscape or a short iPad Split View pane,
/// so the rail thins itself (every 2nd/3rd/4th bucket) until it fits the height it's
/// offered instead of clipping the ends off-screen unreachably.
struct LibraryAlphabetRail: View {
    let entries: [AlphabetBucket]
    let onPick: (AlphabetBucket) -> Void

    /// Extra trailing room compact grids should reserve when the rail is visible.
    /// The iOS rail is intentionally narrow like a native table section index; visionOS
    /// keeps the older, roomier target because it is acquired by gaze rather than touch.
    static var compactGridTrailingReservation: CGFloat {
        #if os(visionOS)
        34
        #else
        24
        #endif
    }

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

    /// Row geometry shared by layout and the scrub math. iOS mirrors the compact native
    /// table index; visionOS keeps the larger pre-existing gaze-friendly rows.
    #if os(visionOS)
    private let rowHeight: CGFloat = 20
    private let rowSpacing: CGFloat = 2
    private let verticalPadding: CGFloat = 8
    private let horizontalPadding: CGFloat = 4
    private let labelWidth: CGFloat = 26
    #else
    private let rowHeight: CGFloat = 14
    private let rowSpacing: CGFloat = 0
    private let verticalPadding: CGFloat = 4
    private let horizontalPadding: CGFloat = 2
    private let labelWidth: CGFloat = 18
    #endif

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(entries, id: \.display) { entry in
                Button {
                    onPick(entry)
                } label: {
                    Text(entry.display)
                        .font(labelFont)
                        .monospaced()
                        .foregroundStyle(labelForeground)
                        .frame(width: labelWidth, height: rowHeight)
                }
                .buttonStyle(.plain)
                #if os(visionOS)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8, style: .continuous))
                .hoverEffect(.highlight)
                #endif
                .accessibilityLabel("Jump to \(entry.display)")
            }
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .railBackdrop()
        #if os(iOS)
        // Section-index scrub: the rows are precise enough for a pointer but not a
        // fingertip, so a drag anywhere on the strip sweeps through buckets
        // UITableView-style. simultaneousGesture keeps plain taps on the
        // per-letter buttons working.
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
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

    private var labelFont: Font {
        #if os(visionOS)
        .caption2.weight(.semibold)
        #else
        .system(size: 11, weight: .semibold, design: .rounded)
        #endif
    }

    private var labelForeground: AnyShapeStyle {
        #if os(visionOS)
        AnyShapeStyle(.secondary)
        #else
        AnyShapeStyle(.tint)
        #endif
    }
}

private extension View {
    @ViewBuilder
    func railBackdrop() -> some View {
        #if os(visionOS)
        background(.ultraThinMaterial, in: Capsule())
        #else
        // Native iOS section indexes float over table/list content without a persistent
        // material pill. The whole strip remains the drag/scrub hit region.
        contentShape(Rectangle())
        #endif
    }
}
