import SwiftUI
import PMSKit

/// Sign-in screen. Drives the Plex PIN-OAuth flow via `AuthManager`:
///   1. "Sign in with Plex" creates a PIN and shows the linking code as the
///      primary state (#16): the user enters it at plex.tv/link from any device
///      while `AuthManager` polls in the background. The in-headset web sheet
///      (`WebAuthSession` → `app.plex.tv/auth`) is NOT auto-opened — it would
///      steal focus from the code ~0.5s after it appears — and is instead
///      offered as an explicit button.
///   2. We observe `authManager.state` and, once it reaches `.authenticated`,
///      close the web sheet if one is open (`webAuth.cancel()`). ContentView
///      then switches to `RootView` when `appModel.isAuthenticated` flips.
struct LoginView: View {
    let authManager: AuthManager

    @State private var webAuth = WebAuthSession()

    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            // The real VisionPlex artwork as an app-icon-style tile in a soft glow (#18) —
            // replaces the placeholder play.tv.fill SF Symbol.
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.18))
                    .frame(width: 156, height: 156)
                    .blur(radius: 24)
                Image("VisionPlexLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card + 8,
                                                style: .continuous))
            }

            VStack(spacing: DS.Space.md) {
                Text("VisionPlex")
                    .font(.extraLargeTitle.bold())

                Text("Sign in to your Plex account to browse and play your libraries in the headset.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            content
                .padding(.top, DS.Space.sm)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.md)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            }
        }
        .padding(DS.Space.xxxl + DS.Space.md)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: authManager.state) { _, newValue in
            switch newValue {
            case .failed(let message):
                errorMessage = message
                working = false
                webAuth.cancel()
            case .authenticated:
                // Token arrived via polling — close the web sheet so it doesn't
                // linger over the now-authenticated app.
                webAuth.cancel()
            default:
                break
            }
        }
        .onDisappear {
            webAuth.cancel()
            authManager.cancelPendingLogin()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .awaitingAuthorization(let code, let url):
            // Linking-code-first (#16): the code is the primary state so the user
            // can finish auth from a phone/laptop at plex.tv/link. Polling runs in
            // the background the whole time; the in-headset browser is opt-in.
            VStack(spacing: DS.Space.lg) {
                VStack(spacing: DS.Space.xs) {
                    Text("Enter this code at plex.tv/link")
                        .font(.headline)
                    Text("on your phone, tablet, or computer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(code)
                    .font(.extraLargeTitle.monospaced().weight(.semibold))
                    .tracking(6)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.md)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                HStack(spacing: DS.Space.sm) {
                    ProgressView()
                    Text("Waiting for authorization…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Open Plex sign-in in this headset instead") {
                    webAuth.start(url) { }
                }
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
            // Create the PIN and stop: the linking code becomes the primary UI and
            // polling is already running (#16). The web sheet only opens if the
            // user explicitly asks for the in-headset path.
            _ = try await authManager.createPin()
            working = false
        } catch {
            errorMessage = friendlyMessage(error)
            working = false
        }
    }
}
