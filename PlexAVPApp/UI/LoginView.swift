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
///
/// Visual language (#18): the welcome card follows the branding brainstorm's
/// "blue cinema glow" direction — the logo tile sits in a cool-blue/warm-amber
/// ambience that echoes the stripe colors of the mark, and "Plex" in the title
/// picks up the wordmark's amber. Brand colors are local constants on purpose:
/// no new catalog assets while #19's transparent glyph is in flight.
struct LoginView: View {
    let authManager: AuthManager

    @Environment(AppModel.self) private var appModel

    @State private var webAuth = WebAuthSession()

    @State private var working = false
    @State private var errorMessage: String?
    @State private var jellyfinServer = ""
    @State private var jellyfinUsername = ""
    @State private var jellyfinPassword = ""

    /// Brand accents sampled from the VisionPlex artwork (mark stripe blue
    /// ≈ #00A3FF, wordmark amber ≈ #FFB833).
    private static let brandBlue = Color(red: 0.00, green: 0.64, blue: 1.00)
    private static let brandAmber = Color(red: 1.00, green: 0.72, blue: 0.20)

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            header

            backendPicker

            content
                .padding(.top, DS.Space.sm)

            if let errorMessage {
                errorBanner(errorMessage)
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

    // MARK: - Header (logo tile + title + tagline)

    /// App-icon-style logo tile in a two-tone brand ambience. The old flat tint
    /// circle read as placeholder; this echoes the artwork's own palette — a cool
    /// glow up-leading, a warm one down-trailing — kept subtle under the glass.
    private var header: some View {
        VStack(spacing: DS.Space.xl) {
            ZStack {
                Circle()
                    .fill(Self.brandBlue.opacity(0.20))
                    .frame(width: 150, height: 150)
                    .blur(radius: 36)
                    .offset(x: -36, y: -26)
                Circle()
                    .fill(Self.brandAmber.opacity(0.16))
                    .frame(width: 150, height: 150)
                    .blur(radius: 36)
                    .offset(x: 36, y: 30)
                // Single swap point for #19's transparent `VisionPlexGlyph` asset.
                Image("VisionPlexLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .clipShape(logoTileShape)
                    .overlay(logoTileShape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 10)
            }

            VStack(spacing: DS.Space.md) {
                Text("Vision\(Text("Plex").foregroundStyle(Self.brandAmber))")
                    .font(.extraLargeTitle.bold())

                Text(appModel.activeBackend == .plex
                     ? "Your whole Plex library, in your space."
                     : "Your Jellyfin library, in your space.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
    }

    private var logoTileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.card + 8, style: .continuous)
    }

    private var backendPicker: some View {
        Picker("Media Server", selection: Binding(
            get: { appModel.activeBackend },
            set: { backend in
                errorMessage = nil
                working = false
                webAuth.cancel()
                authManager.selectBackend(backend)
            })) {
                ForEach(MediaBackendKind.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
    }

    // MARK: - Flow states

    @ViewBuilder
    private var content: some View {
        if appModel.activeBackend == .jellyfin {
            jellyfinLoginForm
        } else {
            plexLoginFlow
        }
    }

    @ViewBuilder
    private var plexLoginFlow: some View {
        switch authManager.state {
        case .awaitingAuthorization(let code, let url):
            // Linking-code-first (#16): the code is the primary state so the user
            // can finish auth from a phone/laptop at plex.tv/link. Polling runs in
            // the background the whole time; the in-headset browser is opt-in.
            VStack(spacing: DS.Space.lg) {
                VStack(spacing: DS.Space.xs) {
                    Text("Enter this code at \(Text("plex.tv/link").fontWeight(.semibold).foregroundStyle(Self.brandAmber))")
                        .font(.title3)
                    Text("on your phone, tablet, or computer")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // The hero moment of sign-in: one glass cell per character (the
                // link PIN is always 4 chars), Apple-pairing-code style, instead
                // of a single cramped chip.
                HStack(spacing: DS.Space.md) {
                    ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                        Text(String(character))
                            .font(.system(size: 54, weight: .semibold, design: .monospaced))
                            .frame(width: 76, height: 96)
                            .background(.thinMaterial, in: codeCellShape)
                            .overlay(codeCellShape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                    }
                }
                .padding(.vertical, DS.Space.xs)

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
            VStack(spacing: DS.Space.lg) {
                Button {
                    Task { await startLogin() }
                } label: {
                    Label("Sign in with Plex", systemImage: "person.crop.circle")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.xs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)

                Text("Signing in shows a short code you can enter from any device — no typing in the headset.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }

    private var jellyfinLoginForm: some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("Sign in to Jellyfin")
                    .font(.title3.weight(.semibold))
                Text("Enter your server URL and Jellyfin account credentials.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("https://jellyfin.example.com", text: $jellyfinServer)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .keyboardType(.URL)
                .frame(maxWidth: 420)

            TextField("Username", text: $jellyfinUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .frame(maxWidth: 420)

            SecureField("Password", text: $jellyfinPassword)
                .textContentType(.password)
                .frame(maxWidth: 420)

            Button {
                Task { await startJellyfinLogin() }
            } label: {
                if working {
                    ProgressView()
                } else {
                    Label("Sign in with Jellyfin", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.xs)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
        }
    }

    private var codeCellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
    }

    // MARK: - Error presentation

    /// Glass banner consistent with the DS chip family: material background with
    /// a red hairline + icon, primary-colored text (legible on glass, unlike the
    /// old all-red label on a red wash).
    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(message)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .font(.callout)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(.red.opacity(0.35), lineWidth: 0.5))
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

    private func startJellyfinLogin() async {
        errorMessage = nil
        let server: URL
        do {
            server = try JellyfinServerURL.normalized(jellyfinServer)
        } catch {
            errorMessage = "Enter a valid Jellyfin server URL."
            return
        }
        let username = jellyfinUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !jellyfinPassword.isEmpty else {
            errorMessage = "Enter your Jellyfin username and password."
            return
        }
        working = true
        await authManager.loginToJellyfin(server: server,
                                          username: username,
                                          password: jellyfinPassword)
        working = false
    }
}
