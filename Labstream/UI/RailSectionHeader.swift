import SwiftUI

struct RailSectionHeader: View {
    let title: String
    let destination: RailViewAllDestination?
    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(title)
                .font(compactWidth ? .title3.bold() : .title2.bold())
            Spacer()
            if let destination {
                NavigationLink("View All", value: destination)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("View all \(title)")
            }
        }
        .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))
    }
}
