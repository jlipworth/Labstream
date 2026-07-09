import SwiftUI
#if os(macOS)
import AppKit
#endif
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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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

    /// Compact width (iPhone, narrow iPad split view) drops the floating glass card:
    /// phone sign-in should read as one full-screen surface, not a window-in-a-window.
    private var isCompactWidth: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var formControlsStack: some View {
        VStack(spacing: DS.Space.xl) {
            backendPicker

            content

            if let errorMessage {
                BackendAuthErrorBanner(message: errorMessage)
            }
        }
    }

    private var formStack: some View {
        VStack(spacing: DS.Space.xl) {
            LoginBrandHeader()

            formControlsStack
        }
    }

    /// The floating glass sign-in card used at regular width (iPad, visionOS).
    private var loginCard: some View {
        formStack
            .padding(.horizontal, DS.Space.xxxl)
            .padding(.vertical, DS.Space.xxl)
            .frame(maxWidth: 560)
            .background(LoginPanelBackground())
    }

    /// A phone sign-in is an onboarding screen, not an iPad card squeezed into a
    /// narrow window. Keep the brand surface continuous from edge to edge and let
    /// its controls float directly on that surface.
    private var compactLoginSurface: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxxl) {
            CompactLoginHeader()

            VStack(alignment: .leading, spacing: DS.Space.xl) {
                backendPicker

                content

                if let errorMessage {
                    BackendAuthErrorBanner(message: errorMessage)
                }
            }
        }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.xxl)
            .padding(.bottom, DS.Space.xxxl)
            .frame(maxWidth: .infinity)
    }

    var body: some View {
        #if os(macOS)
        macLoginLayout
        #else
        Group {
            if isCompactWidth {
                // Full-screen phone layout: brand gradient owns the display, and the
                // content flows in a scroll view so the keyboard can push it around.
                ScrollView {
                    compactLoginSurface
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            } else {
                #if os(iOS)
                // iPad regular width: the fixed 560-pt card overflows once the
                // software keyboard shrinks the safe area (Jellyfin/Emby credential
                // fields, especially landscape) or the Emby Connect server list grows.
                // Wrap it in a ScrollView so it can scroll instead of clipping; the
                // GeometryReader-backed minHeight keeps the card vertically centered
                // whenever the content fits, and .basedOnSize keeps it inert until then.
                GeometryReader { proxy in
                    ScrollView {
                        loginCard
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                #else
                loginCard
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        // Keep the mobile brand backdrop without forcing the entire login hierarchy
        // into dark mode; the panel backgrounds adapt to the user's appearance.
        .background(LoginBrandBackdrop())
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
        #endif
    }

    #if os(macOS)
    /// Native Mac sign-in shell: a compact setup-style panel integrated with the
    /// window surface. Keep the mobile/vision glass login untouched, but avoid the
    /// oversized marketing/split-card treatment that feels detached in a Mac window.
    private var macLoginLayout: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    MacLoginHeader()

                    formControlsStack
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(maxWidth: 430)
                .background(MacLoginCardBackground())
                .frame(maxWidth: .infinity,
                       minHeight: proxy.size.height,
                       alignment: .center)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacLoginWindowBackground())
        .onChange(of: authManager.state) { _, newValue in
            switch newValue {
            case .failed(let message):
                errorMessage = message
                working = false
                selectingEmbyConnectServerID = nil
                webAuth.cancel()
            case .authenticated:
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
    #endif

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
        case .failed where appModel.token != nil:
            PlexRestoreFailureView(isWorking: working,
                                   onRetry: { Task { await retryPlexRestore() } },
                                   onSignInAgain: { Task { await startLogin() } })
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

    private func retryPlexRestore() async {
        working = true
        errorMessage = nil
        _ = await authManager.restoreSession()
        working = false
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

#if os(macOS)
private struct MacLoginHeader: View {
    var body: some View {
        VStack(spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DS.Brand.iconPlateGradient)

                    Image("LabstreamGlyph")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 31, height: 31)
                }
                .frame(width: 46, height: 46)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 4)

                HStack(spacing: 0) {
                    Text("Lab")
                    Text("stream")
                        .foregroundStyle(DS.Brand.amber)
                }
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Labstream")
            }

            Text("Sign in to connect your media library.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MacLoginCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
    }
}

private struct MacLoginWindowBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(alignment: .top) {
                LinearGradient(colors: [
                    DS.Brand.deepTeal.opacity(0.08),
                    Color.clear
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
            }
            .ignoresSafeArea()
    }
}
#endif
