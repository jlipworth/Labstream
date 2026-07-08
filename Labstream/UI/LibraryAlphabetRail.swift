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
/// control visually close to UIKit's section index on iOS/iPadOS: a compact trailing
/// stack of tinted glyphs with just enough backing/outline to read over posters. visionOS
/// keeps a material backing because gaze needs a stronger acquisition target in space.
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
        30
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
    /// Visual feedback for the current tap/scrub target. The rail is otherwise too
    /// easy to lose against poster art, and drag scrubbing should show what will jump.
    @State private var activeDisplay: String?
    @State private var clearActiveTask: Task<Void, Never>?

    /// Row geometry shared by layout and the scrub math. iOS mirrors the compact native
    /// table index; visionOS keeps the larger pre-existing gaze-friendly rows.
    #if os(visionOS)
    private let rowHeight: CGFloat = 20
    private let rowSpacing: CGFloat = 2
    private let verticalPadding: CGFloat = 8
    private let horizontalPadding: CGFloat = 4
    private let labelWidth: CGFloat = 26
    #else
    private let rowHeight: CGFloat = 18
    private let rowSpacing: CGFloat = 1
    private let verticalPadding: CGFloat = 5
    private let horizontalPadding: CGFloat = 3
    private let labelWidth: CGFloat = 24
    #endif

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(entries, id: \.display) { entry in
                Button {
                    pick(entry, clearsAfterDelay: true)
                } label: {
                    Text(entry.display)
                        .font(labelFont)
                        .monospaced()
                        .foregroundStyle(labelForeground)
                        .frame(width: labelWidth, height: rowHeight)
                        .background {
                            if activeDisplay == entry.display {
                                RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous)
                                    .fill(.tint.opacity(activeFillOpacity))
                            }
                        }
                        .overlay {
                            if activeDisplay == entry.display {
                                RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous)
                                    .strokeBorder(.tint.opacity(activeStrokeOpacity), lineWidth: 1)
                            }
                        }
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
        .overlay(alignment: .leading) {
            if let activeDisplay {
                selectedLetterCallout(activeDisplay)
                    .offset(x: calloutOffsetX)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.16), value: activeDisplay)
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
                    pick(entries[index], clearsAfterDelay: false)
                }
                .onEnded { _ in
                    scrubIndex = nil
                    clearActiveSoon()
                }
        )
        #endif
        .onDisappear {
            clearActiveTask?.cancel()
            clearActiveTask = nil
        }
    }

    private var labelFont: Font {
        #if os(visionOS)
        .caption2.weight(.semibold)
        #else
        .system(size: 12.5, weight: .semibold, design: .rounded)
        #endif
    }

    private var labelForeground: AnyShapeStyle {
        #if os(visionOS)
        AnyShapeStyle(.secondary)
        #else
        AnyShapeStyle(.tint)
        #endif
    }

    private var activeCornerRadius: CGFloat {
        #if os(visionOS)
        8
        #else
        6
        #endif
    }

    private var activeFillOpacity: Double {
        #if os(visionOS)
        0.20
        #else
        0.16
        #endif
    }

    private var activeStrokeOpacity: Double {
        #if os(visionOS)
        0.42
        #else
        0.36
        #endif
    }

    private var calloutSize: CGFloat {
        #if os(visionOS)
        56
        #else
        48
        #endif
    }

    private var calloutOffsetX: CGFloat {
        #if os(visionOS)
        -68
        #else
        -56
        #endif
    }

    private var calloutFont: Font {
        #if os(visionOS)
        .title2.weight(.bold)
        #else
        .title3.weight(.bold)
        #endif
    }

    private func selectedLetterCallout(_ display: String) -> some View {
        Text(display)
            .font(calloutFont)
            .monospaced()
            .foregroundStyle(.primary)
            .frame(width: calloutSize, height: calloutSize)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: calloutSize / 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: calloutSize / 3, style: .continuous)
                    .strokeBorder(.tint.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func pick(_ entry: AlphabetBucket, clearsAfterDelay: Bool) {
        clearActiveTask?.cancel()
        activeDisplay = entry.display
        onPick(entry)
        if clearsAfterDelay {
            clearActiveSoon()
        }
    }

    private func clearActiveSoon() {
        clearActiveTask?.cancel()
        clearActiveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            activeDisplay = nil
            clearActiveTask = nil
        }
    }
}

private extension View {
    @ViewBuilder
    func railBackdrop() -> some View {
        #if os(visionOS)
        background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.secondary.opacity(0.20), lineWidth: 1)
            }
        #else
        // Native iOS section indexes float lightly over table/list content, but this
        // grid sits on busy poster art; a faint material + outline keeps the index
        // discoverable without going back to the old heavy glass-button rail.
        background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.tint.opacity(0.24), lineWidth: 0.75)
            }
            .contentShape(Rectangle())
        #endif
    }
}
