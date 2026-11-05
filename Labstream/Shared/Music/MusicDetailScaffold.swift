#if os(iOS)
import PMSKit
import SwiftUI

/// Which header composition a music detail page should draw.
enum MusicDetailHeaderMode {
    /// Above the track list, centred in the content region.
    case stacked
    /// Alone in the leading column of the two-column reflow (adds the description).
    case column
}

/// iPhone/iPad album and playlist page frame (iPhone Duo design spec, Music).
///
/// Stacks the header above the tracks until `MusicDetailLayoutPolicy` reflows the content
/// region into two columns (unfolded sideways): header leading, tracks trailing, with the
/// column gap on the hinge in book. The decorative backdrop stays the caller's full-bleed
/// background layer. The tracks' scroll anchor (`trackAnchor`, fed by the tracks' own
/// `.scrollTargetLayout()`) is shared by both compositions so the reading position survives
/// the stack-to-columns reflow.
struct MusicDetailScaffold<AnchorID: Hashable, Header: View, Tracks: View>: View {
    @Binding var trackAnchor: AnchorID?
    @ViewBuilder var header: (MusicDetailHeaderMode) -> Header
    @ViewBuilder var tracks: () -> Tracks

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.labstreamCompactWidth) private var compactWidth
    @Environment(\.duoPose) private var duoPose

    /// The scaffold's own frame in global space: the content region (safe area excluded).
    @State private var region: CGRect = .zero

    /// Readable cap for the stacked page on wide regular-width screens.
    private static var readableWidth: CGFloat { 680 }

    private var layout: MusicDetailLayoutPolicy.Layout {
        var hinge: (minX: Double, maxX: Double)?
        if case .book(let rect) = duoPose {
            hinge = (Double(rect.minX - region.minX), Double(rect.maxX - region.minX))
        }
        return MusicDetailLayoutPolicy.layout(width: Double(region.width),
                                              height: Double(region.height),
                                              regularWidth: horizontalSizeClass == .regular,
                                              hinge: hinge)
    }

    var body: some View {
        Group {
            switch layout {
            case .stacked:
                stacked
            case .columns(let leadingWidth, let trailingStart):
                columns(leadingWidth: CGFloat(leadingWidth), trailingStart: CGFloat(trailingStart))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { newRegion in
            if region != newRegion { region = newRegion }
        }
    }

    private var padding: CGFloat { DS.pagePadding(compact: compactWidth) }

    private var stacked: some View {
        ScrollView {
            VStack(spacing: DS.Space.xxl) {
                header(.stacked)
                tracks()
            }
            .padding(.horizontal, padding)
            .padding(.vertical, DS.Space.xl)
            .frame(maxWidth: compactWidth ? .infinity : Self.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $trackAnchor, anchor: .top)
    }

    private func columns(leadingWidth: CGFloat, trailingStart: CGFloat) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                header(.column)
                    .padding(.horizontal, padding)
                    .padding(.vertical, DS.Space.xl)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: max(leadingWidth, 0))

            Color.clear
                .frame(width: max(trailingStart - leadingWidth, 0))
                .accessibilityHidden(true)

            ScrollView {
                tracks()
                    .padding(.horizontal, padding)
                    .padding(.vertical, DS.Space.xl)
            }
            .scrollPosition(id: $trackAnchor, anchor: .top)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Centred header pieces shared by the iOS album and playlist pages.
struct MusicDetailCenteredHeader<Subtitle: View, Actions: View>: View {
    let mode: MusicDetailHeaderMode
    let art: String?
    let title: String
    let caption: String?
    let description: String?
    @ViewBuilder var subtitle: () -> Subtitle
    @ViewBuilder var actions: () -> Actions

    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var coverSize: CGFloat {
        switch mode {
        case .stacked: compactWidth ? 220 : 280
        case .column: 240
        }
    }

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            PosterImage(path: art, width: coverSize, height: coverSize,
                        cornerRadius: DS.Radius.poster)
                .background(DS.posterShadow(RoundedRectangle(cornerRadius: DS.Radius.poster,
                                                             style: .continuous)))
                .padding(.bottom, DS.Space.md)

            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            subtitle()
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: DS.Space.md) {
                actions()
            }
            .padding(.top, DS.Space.md)

            if mode == .column, let description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.top, DS.Space.md)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
#endif
