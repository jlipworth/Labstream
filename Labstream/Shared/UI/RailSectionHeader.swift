import SwiftUI

struct RailSectionHeader: View {
    let title: String
    let destination: RailViewAllDestination?
    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(title)
                .font(sectionTitleFont)
            Spacer()
            // tvOS renders View All as the rail's trailing card (`RailViewAllCard`)
            // instead of a header link: a lone focusable in the header row is a detour
            // for the focus engine, and it reads better in the row it pages.
            #if !os(tvOS)
            if let destination {
                NavigationLink("View All", value: destination)
                    .font(viewAllFont)
                    .accessibilityLabel("View all \(title)")
            }
            #endif
        }
        .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))
    }

    private var sectionTitleFont: Font {
        #if os(tvOS)
        // TV type sizes run big: title3 (48pt) dwarfs the cards beneath it.
        .headline
        #else
        compactWidth ? .title3.bold() : .title2.bold()
        #endif
    }

    private var viewAllFont: Font {
        #if os(tvOS)
        .body.weight(.semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }
}

#if os(tvOS)
/// tvOS "View All" affordance: the last card of a rail rather than a header link.
/// Sized by the caller to match the rail's artwork frame so the row stays aligned.
struct RailViewAllCard: View {
    let title: String
    let destination: RailViewAllDestination
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        NavigationLink(value: destination) {
            RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: width, height: height)
                .overlay {
                    VStack(spacing: DS.Space.md) {
                        Image(systemName: "arrow.right.circle")
                            .font(.title2)
                        Text("View All")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .tvFocusHighlight()
        }
        .cardLink()
        .accessibilityLabel("View all \(title)")
    }
}
#endif
