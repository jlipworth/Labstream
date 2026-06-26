import SwiftUI
import PMSKit

/// The trailing A–Z jump rail shared by the movies/TV `LibraryGridView` and the music
/// `MusicPagedGrid` (#96, #111). Each entry scrolls the grid to the first item under that
/// character; the offset math lives in `AlphabetBucket`, so every backend's rail jumps to
/// the same place. Extracted from `LibraryGridView` so the music grids reuse it verbatim.
struct LibraryAlphabetRail: View {
    let entries: [AlphabetBucket]
    let onPick: (AlphabetBucket) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(entries, id: \.display) { entry in
                Button {
                    onPick(entry)
                } label: {
                    Text(entry.display)
                        .font(.caption2.weight(.semibold))
                        .monospaced()
                        .frame(width: 26, height: 20)
                }
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8, style: .continuous))
                .hoverEffect(.highlight)
                .accessibilityLabel("Jump to \(entry.display)")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
