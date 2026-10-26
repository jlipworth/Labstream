import SwiftUI

/// A segmented choice whose selected segment is amber (= selected, like the selected tab) on
/// iPhone/iPad. The system segmented control can only be tinted through
/// `UISegmentedControl.appearance()`, which also turned the iOS 26 tab bar's selection blue, so iOS
/// draws its own segments; visionOS, tvOS and macOS keep the system segmented picker.
struct LabstreamSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    #if os(iOS)
    @Namespace private var thumb
    #endif

    var body: some View {
        #if os(iOS)
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        // Dark on amber for contrast; amber itself carries "selected".
                        .foregroundStyle(isSelected ? Color.black : Color.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color("AccentColor"))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                // Borderless: each segment stays its own tap target inside a Form row.
                .buttonStyle(.borderless)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .animation(.snappy(duration: 0.2), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        #else
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        #endif
    }
}
