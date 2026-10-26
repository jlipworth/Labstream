import PMSKit
import SwiftUI

/// Regular-width Settings (iPhone Duo unfolded, iPad): categories on the left, the selected
/// category's form on the right, like iPad Settings. Amber marks the selected category only.
/// In book pose the split sits on the hinge, so the list is the first page and the detail the
/// second; the vertical bar (when present) belongs to the detail column only.
struct MobileSettingsSplitView<Detail: View>: View {
  @Binding var selection: SettingsCategory?
  @Binding var path: [SettingsRoute]
  let includesDownloads: Bool
  @ViewBuilder let detail: (SettingsCategory) -> Detail

  @Environment(\.duoPose) private var duoPose
  @State private var frame: CGRect = .zero

  var body: some View {
    // Two stacks side by side, not `NavigationSplitView`: inside the tab view the system ignores
    // `navigationSplitViewColumnWidth` and keeps its own ~250–320 pt sidebar, so the split could
    // not sit on the hinge in book pose.
    HStack(spacing: 0) {
      NavigationStack {
        sidebar
          .navigationTitle("Settings")
          .navigationBarTitleDisplayMode(.large)
      }
      .frame(width: sidebarWidth)
      Divider()
        .ignoresSafeArea()
      NavigationStack(path: $path) {
        detail(selection ?? SettingsCategoryPolicy.defaultCategory)
      }
      .frame(maxWidth: .infinity)
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    .onAppear {
      if selection == nil { selection = SettingsCategoryPolicy.defaultCategory }
    }
    .onChange(of: selection) { old, new in
      // A different category starts its detail at the root, unless the pushed screen is its own
      // (the fold/unfold hand-off selects the category that owns the path).
      guard old != nil, let new, path.contains(where: { $0.category != new }) else { return }
      path = []
    }
  }

  /// Rows draw their own selection so it looks the same with the phone and pad idioms: a soft
  /// amber tint with an amber symbol, the only amber in the list.
  private var sidebar: some View {
    List(SettingsCategoryPolicy.sidebar(includesDownloads: includesDownloads)) { category in
      let isSelected = selection == category
      Button {
        selection = category
      } label: {
        Label {
          Text(category.title)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(Color.primary)
        } icon: {
          Image(systemName: category.systemImage)
            .foregroundStyle(isSelected ? Color("AccentColor") : Color.primary)
        }
      }
      .listRowBackground(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(isSelected ? Color("AccentColor").opacity(0.18) : Color.clear)
          .padding(.horizontal, 8))
      .listRowSeparator(.hidden)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier("labstream.settings.category.\(category.rawValue)")
    }
    .listStyle(.sidebar)
  }

  private var sidebarWidth: CGFloat {
    let layout = DuoPoseLayout(input: duoPose, contentRegion: frame)
    let bookFirstPage = layout.kind == .book ? Double(layout.firstHalf.width) : nil
    return CGFloat(SettingsCategoryPolicy.sidebarWidth(
      containerWidth: Double(frame.width), bookFirstHalfWidth: bookFirstPage))
  }
}
