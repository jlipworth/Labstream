import SwiftUI
import PMSKit

/// Sign-in screen. Drives the Plex PIN-OAuth flow via `AuthManager`:
///   1. "Sign in with Plex" creates a PIN and shows the linking code as the
///      primary state (#16): the user enters it at plex.tv/link from any device
///      while `AuthManager` polls in the background. The on-device web sheet
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
/// with a native SwiftUI Labstream title treatment.
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
    @State private var embyServer = ""
    @State private var embyUsername = ""
    @State private var embyPassword = ""
    @State private var embySignInMethod: EmbySignInMethod?
    @State private var selectingEmbyConnectServerID: String?

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            LoginBrandHeader()

            backendPicker

            content

            if let errorMessage {
                BackendAuthErrorBanner(message: errorMessage)
            }
        }
        .padding(.horizontal, DS.Space.xxxl)
        .padding(.vertical, DS.Space.xxl)
        .frame(maxWidth: 560)
        .background(LoginPanelBackground())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        // The dark login panel was authored against the visionOS glass window. A bare
        // iOS window is white, which reads as a gray slab floating in a void — give
        // mobile a full-bleed brand backdrop and render the panel's materials and
        // secondary text in dark mode to match.
        .background(DS.Brand.iconPlateGradient.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        #endif
        .onChange(of: authManager.state) { _, newValue in
            switch newValue {
            case .failed(let message):
                errorMessage = message
                working = false
                selectingEmbyConnectServerID = nil
                webAuth.cancel()
            case .authenticated:
                // Token arrived via polling — close the web sheet so it doesn't
                // linger over the now-authenticated app.
                working = false
                selectingEmbyConnectServerID = nil
                webAuth.cancel()
            case .awaitingJellyfinQuickConnect, .awaitingEmbyConnectPin, .awaitingEmbyServerSelection:
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

    private var backendPicker: some View {
        BackendSelectionPicker(selection: appModel.activeBackend,
                               onSelect: selectBackend)
    }

    // MARK: - Flow states

    @ViewBuilder
    private var content: some View {
        switch appModel.activeBackend {
        case .jellyfin:
            jellyfinLoginForm
        case .emby:
            embyLoginForm
        case .plex:
            plexLoginFlow
        }
    }

    @ViewBuilder
    private var plexLoginFlow: some View {
        switch authManager.state {
        case .awaitingAuthorization(let code, let url):
            // Linking-code-first (#16): the code is the primary state so the user
            // can finish auth from a phone/laptop at plex.tv/link. Polling runs in
            // the background the whole time; opening the browser on this device is opt-in.
            PlexLinkCodeView(code: code) {
                webAuth.start(url) { }
            }
        default:
            PlexSignInStartView(isWorking: working) {
                Task { await startLogin() }
            }
        }
    }

    @ViewBuilder
    private var jellyfinLoginForm: some View {
        JellyfinSignInFlow(
            state: authManager.state,
            server: $jellyfinServer,
            username: $jellyfinUsername,
            password: $jellyfinPassword,
            signInMethod: $jellyfinSignInMethod,
            isWorking: working,
            onUseCredentialsFallback: useJellyfinCredentialsFallback,
            onChooseQuickConnect: chooseJellyfinQuickConnect,
            onChooseCredentials: chooseJellyfinCredentials,
            onStartQuickConnect: { Task { await startJellyfinQuickConnect() } },
            onSignInWithCredentials: { Task { await startJellyfinLogin() } },
            onChooseDifferentFromQuickConnect: cancelJellyfinAuthorizationAndResetMethod,
            onChooseDifferentFromCredentials: resetJellyfinCredentialsMethod)
    }

    // MARK: - Emby (Emby Connect PIN — primary — or server URL + username/password)

    @ViewBuilder
    private var embyLoginForm: some View {
        EmbySignInFlow(
            state: authManager.state,
            server: $embyServer,
            username: $embyUsername,
            password: $embyPassword,
            signInMethod: $embySignInMethod,
            isWorking: working,
            selectingServerID: $selectingEmbyConnectServerID,
            onUseServerURLFallback: useEmbyServerURLFallback,
            onChooseConnectPin: chooseEmbyConnectPin,
            onChooseServerCredentials: chooseEmbyServerCredentials,
            onStartConnectPin: { Task { await startEmbyConnect() } },
            onSelectServer: selectEmbyConnectServer,
            onCancelServerSelection: cancelEmbyServerSelection,
            onSignInWithCredentials: { Task { await startEmbyLogin() } },
            onChooseDifferentFromConnect: cancelEmbyAuthorizationAndResetMethod,
            onChooseDifferentFromCredentials: resetEmbyCredentialsMethod)
    }

    private func useJellyfinCredentialsFallback() {
        authManager.cancelCurrentAuthorization()
        jellyfinSignInMethod = .credentials
        working = false
    }

    private func chooseJellyfinQuickConnect() {
        jellyfinSignInMethod = .quickConnect
        Task { await startJellyfinQuickConnect() }
    }

    private func chooseJellyfinCredentials() {
        errorMessage = nil
        jellyfinSignInMethod = .credentials
    }

    private func cancelJellyfinAuthorizationAndResetMethod() {
        errorMessage = nil
        working = false
        authManager.cancelCurrentAuthorization()
        jellyfinSignInMethod = nil
    }

    private func resetJellyfinCredentialsMethod() {
        errorMessage = nil
        working = false
        jellyfinSignInMethod = nil
    }

    private func useEmbyServerURLFallback() {
        authManager.cancelCurrentAuthorization()
        embySignInMethod = .credentials
        working = false
    }

    private func chooseEmbyConnectPin() {
        embySignInMethod = .connectPin
        Task { await startEmbyConnect() }
    }

    private func chooseEmbyServerCredentials() {
        errorMessage = nil
        embySignInMethod = .credentials
    }

    private func cancelEmbyAuthorizationAndResetMethod() {
        errorMessage = nil
        working = false
        authManager.cancelCurrentAuthorization()
        embySignInMethod = nil
    }

    private func resetEmbyCredentialsMethod() {
        errorMessage = nil
        working = false
        embySignInMethod = nil
    }

    private func selectEmbyConnectServer(_ server: AuthManager.EmbyConnectServerChoice) {
        Task {
            guard selectingEmbyConnectServerID == nil else { return }
            selectingEmbyConnectServerID = server.id
            working = true
            await authManager.selectEmbyConnectServer(id: server.id)
            if case .authenticated = authManager.state {
                return
            }
            selectingEmbyConnectServerID = nil
            working = false
        }
    }

    private func cancelEmbyServerSelection() {
        authManager.cancelCurrentAuthorization()
        embySignInMethod = nil
        working = false
        selectingEmbyConnectServerID = nil
    }

    private func selectBackend(_ backend: MediaBackendKind) {
        errorMessage = nil
        working = false
        webAuth.cancel()
        jellyfinSignInMethod = nil
        embySignInMethod = nil
        authManager.selectBackend(backend)
    }

    private func startLogin() async {
        working = true
        errorMessage = nil
        do {
            // Create the PIN and stop: the linking code becomes the primary UI and
            // polling is already running (#16). The web sheet only opens if the
            // user explicitly asks for the on-device path.
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

    private func startEmbyConnect() async {
        errorMessage = nil
        working = true
        await authManager.startEmbyConnect()
        working = false
    }

    private func startEmbyLogin() async {
        errorMessage = nil
        let server: URL
        do {
            // DIVERGENCE: EmbyServerURL preserves any user-entered base path (e.g. /emby).
            server = try EmbyServerURL.normalized(embyServer)
        } catch {
            errorMessage = "Enter a valid Emby server URL."
            return
        }
        let username = embyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !embyPassword.isEmpty else {
            errorMessage = "Enter your Emby username and password."
            return
        }
        working = true
        await authManager.loginToEmby(server: server,
                                      username: username,
                                      password: embyPassword)
        working = false
    }
}
