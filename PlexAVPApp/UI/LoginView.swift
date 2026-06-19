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
/// Visual language (#18/#19): the welcome card now uses the same mark-only
/// foreground that ships as the visionOS app-icon Front layer. The full wordmark
/// stays out of the circular icon crop, while the sign-in screen pairs the mark
/// with a native SwiftUI VisionPlay title treatment.
private enum JellyfinSignInMethod: Equatable {
    case quickConnect
    case credentials
}

struct LoginView: View {
    let authManager: AuthManager

    @Environment(AppModel.self) private var appModel

    @State private var webAuth = WebAuthSession()

    @State private var working = false
    @State private var errorMessage: String?
    @State private var jellyfinServer = ""
    @State private var jellyfinUsername = ""
    @State private var jellyfinPassword = ""
    @State private var jellyfinSignInMethod: JellyfinSignInMethod?

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            header

            backendPicker

            content

            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .padding(.horizontal, DS.Space.xxxl)
        .padding(.vertical, DS.Space.xxl)
        .frame(maxWidth: 560)
        .background(loginPanelBackground)
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
                working = false
                webAuth.cancel()
            case .awaitingJellyfinQuickConnect:
                working = false
            default:
                break
            }
        }
        .onDisappear {
            webAuth.cancel()
            authManager.cancelPendingLogin()
        }
    }

    // MARK: - Header (logo tile + title)

    /// App-icon-style brand lockup. The mark is the same transparent logo-only
    /// artwork used by the icon foreground, deliberately avoiding the wordmark in
    /// the cropped app icon while still presenting the VisionPlay name on screen.
    private var header: some View {
        VStack(spacing: DS.Space.md) {
            brandMark

            HStack(spacing: 0) {
                Text("Vision")
                Text("Play")
                    .foregroundStyle(DS.Brand.amber)
            }
            .font(.largeTitle.bold())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("VisionPlay")
        }
    }

    private var loginPanelBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .fill(Color.black.opacity(0.58))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
    }

    private var brandMark: some View {
        ZStack {
            logoTileShape
                .fill(DS.Brand.iconPlateGradient)
            logoTileShape
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)

            Image("VisionPlayGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 78)
        }
        .frame(width: 112, height: 112)
        .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 8)
    }

    private var logoTileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.card + 14, style: .continuous)
    }

    private var backendPicker: some View {
        Picker("Media Server", selection: Binding(
            get: { appModel.activeBackend },
            set: { backend in
                errorMessage = nil
                working = false
                webAuth.cancel()
                jellyfinSignInMethod = nil
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
                    Text("Enter this code at \(Text("plex.tv/link").fontWeight(.semibold).foregroundStyle(DS.Brand.amber))")
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
            VStack(spacing: DS.Space.md) {
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

                Text("Uses a code at plex.tv/link.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var jellyfinLoginForm: some View {
        switch authManager.state {
        case .awaitingJellyfinQuickConnect(let code):
            jellyfinQuickConnectWaiting(code: code)
        default:
            jellyfinCredentialsForm
        }
    }

    @ViewBuilder
    private var jellyfinCredentialsForm: some View {
        VStack(spacing: DS.Space.md) {
            TextField("https://jellyfin.example.com", text: $jellyfinServer)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            switch jellyfinSignInMethod {
            case nil:
                jellyfinMethodChooser
            case .quickConnect:
                jellyfinQuickConnectStart
            case .credentials:
                jellyfinUsernamePasswordForm
            }
        }
    }

    private var jellyfinMethodChooser: some View {
        VStack(spacing: DS.Space.sm) {
            Text("Choose how to sign in.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: DS.Space.sm) {
                Button {
                    jellyfinSignInMethod = .quickConnect
                    Task { await startJellyfinQuickConnect() }
                } label: {
                    Label("Quick Connect", systemImage: "link.badge.plus")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || !hasJellyfinServerInput)

                Button {
                    errorMessage = nil
                    jellyfinSignInMethod = .credentials
                } label: {
                    Label("Username / Password", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .disabled(working || !hasJellyfinServerInput)
            }
            .frame(maxWidth: 340)

            if !hasJellyfinServerInput {
                Text("Enter your Jellyfin server URL first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var jellyfinQuickConnectStart: some View {
        VStack(spacing: DS.Space.sm) {
            if working {
                HStack(spacing: DS.Space.sm) {
                    ProgressView()
                    Text("Starting Quick Connect…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await startJellyfinQuickConnect() }
                } label: {
                    Label("Start Quick Connect", systemImage: "link.badge.plus")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.xs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasJellyfinServerInput)
            }

            Button("Choose a different sign-in method") {
                errorMessage = nil
                working = false
                authManager.cancelCurrentAuthorization()
                jellyfinSignInMethod = nil
            }
            .buttonStyle(.bordered)
        }
    }

    private var jellyfinUsernamePasswordForm: some View {
        VStack(spacing: DS.Space.md) {
            TextField("Username", text: $jellyfinUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            SecureField("Password", text: $jellyfinPassword)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
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

            Button("Choose a different sign-in method") {
                errorMessage = nil
                working = false
                jellyfinSignInMethod = nil
            }
            .buttonStyle(.bordered)
        }
    }

    private func jellyfinQuickConnectWaiting(code: String) -> some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("Enter this code in Jellyfin")
                    .font(.title3.weight(.semibold))
                Text("In an already signed-in Jellyfin app or web UI, open Quick Connect and enter the code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: DS.Space.md) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                    Text(String(character))
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .frame(width: 64, height: 82)
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

            Button("Use username and password instead") {
                authManager.cancelCurrentAuthorization()
                jellyfinSignInMethod = .credentials
                working = false
            }
            .buttonStyle(.bordered)
        }
    }

    private var hasJellyfinServerInput: Bool {
        !jellyfinServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private func startJellyfinQuickConnect() async {
        errorMessage = nil
        let server: URL
        do {
            server = try JellyfinServerURL.normalized(jellyfinServer)
        } catch {
            errorMessage = "Enter a valid Jellyfin server URL."
            return
        }
        working = true
        await authManager.startJellyfinQuickConnect(server: server)
        working = false
    }
}
