import SwiftUI
import PlexKit

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("plex-avp-app")
                .font(.extraLargeTitle)
            Text("PlexKit \(PlexKit.version) linked")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(60)
    }
}

#Preview(windowStyle: .plain) {
    ContentView()
}
