import SwiftUI
import PlexKit

/// Sign-in screen. Drives the Plex PIN-OAuth flow via `AuthManager`:
///   1. "Sign in with Plex" creates a PIN and opens `app.plex.tv/auth` in the
///      system browser (`openURL`).
///   2. `AuthManager` polls in the background; we observe `authManager.state`
///      and dismiss automatically once it reaches `.authenticated` (ContentView
///      switches to `RootView` when `appModel.isAuthenticated` flips).
struct LoginView: View {
    let authManager: AuthManager

    @Environment(\.openURL) private var openURL

    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("plex-avp-app")
                .font(.extraLargeTitle.bold())

            Text("Sign in to your Plex account to browse and play your libraries in the headset.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            content

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: authManager.state) { _, newValue in
            if case .failed(let message) = newValue {
                errorMessage = message
                working = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .awaitingAuthorization(let code, let url):
            VStack(spacing: 12) {
                ProgressView()
                Text("Waiting for authorization…")
                    .font(.headline)
                Text("Linking code: \(code)")
                    .font(.title2.monospaced())
                Button("Open Plex sign-in again") { openURL(url) }
                    .buttonStyle(.bordered)
            }
        default:
            Button {
                Task { await startLogin() }
            } label: {
                Label("Sign in with Plex", systemImage: "person.crop.circle")
                    .font(.title2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
        }
    }

    private func startLogin() async {
        working = true
        errorMessage = nil
        do {
            let url = try await authManager.createPin()
            openURL(url)
        } catch {
            errorMessage = friendlyMessage(error)
            working = false
        }
    }
}
