import SwiftUI
import PlexKit

/// Sign-in screen. Drives the Plex PIN-OAuth flow via `AuthManager`:
///   1. "Sign in with Plex" creates a PIN and opens `app.plex.tv/auth` in a
///      managed `ASWebAuthenticationSession` web sheet (`WebAuthSession`).
///   2. `AuthManager` polls in the background; we observe `authManager.state`
///      and, once it reaches `.authenticated`, close the web sheet ourselves
///      (`webAuth.cancel()`). ContentView then switches to `RootView` when
///      `appModel.isAuthenticated` flips.
struct LoginView: View {
    let authManager: AuthManager

    @State private var webAuth = WebAuthSession()

    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            // Tinted, layered app glyph in a soft glow — a warmer welcome than a flat icon.
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.18))
                    .frame(width: 156, height: 156)
                    .blur(radius: 24)
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(spacing: DS.Space.md) {
                Text("Plex for Vision Pro")
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
        .onDisappear { webAuth.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .awaitingAuthorization(let code, let url):
            VStack(spacing: DS.Space.lg) {
                ProgressView()
                    .controlSize(.large)
                Text("Waiting for authorization…")
                    .font(.headline)
                VStack(spacing: DS.Space.xs) {
                    Text("Linking code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.largeTitle.monospaced().weight(.semibold))
                        .tracking(4)
                        .padding(.horizontal, DS.Space.xl)
                        .padding(.vertical, DS.Space.md)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                }
                Button("Open Plex sign-in again") {
                    webAuth.start(url) { working = false }
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
            let url = try await authManager.createPin()
            webAuth.start(url) { working = false }
        } catch {
            errorMessage = friendlyMessage(error)
            working = false
        }
    }
}
