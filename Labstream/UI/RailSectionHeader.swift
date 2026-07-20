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
            if let destination {
                NavigationLink("View All", value: destination)
                    .font(viewAllFont)
                    .accessibilityLabel("View all \(title)")
            }
        }
        .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))
    }

    private var sectionTitleFont: Font {
        #if os(tvOS)
        .title3.bold()
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
