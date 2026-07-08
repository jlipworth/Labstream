import SwiftUI

/// Shared backend-auth form primitives used by `LoginView`.
///
/// These are deliberately presentation-only: callers own validation, auth-manager actions,
/// cancellation, and credential storage semantics.

/// Uniform footprint for every primary sign-in CTA: a 52-pt-tall block capped at the
/// method-chooser's 340-pt width, so the Plex, Jellyfin, and Emby entry buttons read as
/// the same control instead of a mix of text-hugging pills and full-width blocks. The
/// 340-pt cap fits a compact iPhone column (390 − page padding) and matches the width
/// used by the cross-platform chooser.
private struct BackendPrimaryCTALabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
    }
}

private extension View {
    func backendPrimaryCTALabel() -> some View { modifier(BackendPrimaryCTALabel()) }
}

enum JellyfinSignInMethod: Equatable {
    case quickConnect
    case credentials
}

enum EmbySignInMethod: Equatable {
    case connectPin
    case credentials
}

struct BackendSelectionPicker: View {
    let selection: MediaBackendKind
    let onSelect: (MediaBackendKind) -> Void

    var body: some View {
        Picker("Media Server", selection: Binding(
            get: { selection },
            set: { backend in onSelect(backend) })) {
                ForEach(MediaBackendKind.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
    }
}

struct BackendAuthErrorBanner: View {
    let message: String

    var body: some View {
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
}

struct PlexLinkCodeView: View {
    let code: String
    let onOpenOnDevice: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("Enter this code at \(Text("plex.tv/link").fontWeight(.semibold).foregroundStyle(DS.Brand.amber))")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Text("on your phone, tablet, or computer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            PairingCodeCells(code: code, width: 76, height: 96, fontSize: 54)

            HStack(spacing: DS.Space.sm) {
                ProgressView()
                Text("Waiting for authorization…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Open Plex sign-in on this device instead", action: onOpenOnDevice)
                .labstreamGlassButtonStyle()
        }
    }
}

struct PlexSignInStartView: View {
    let isWorking: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.md) {
            Button(action: onStart) {
                Label("Sign in with Plex", systemImage: "person.crop.circle")
                    .backendPrimaryCTALabel()
            }
            .labstreamGlassProminentButtonStyle()
            .disabled(isWorking)
            .frame(maxWidth: 340)

            Text("Uses a code at plex.tv/link.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

struct PlexRestoreFailureView: View {
    let isWorking: Bool
    let onRetry: () -> Void
    let onSignInAgain: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.md) {
            Text("Plex session saved")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Labstream still has your Plex token, but server discovery did not finish. Try reconnecting before signing in again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(action: onRetry) {
                Label("Reconnect to Plex", systemImage: "arrow.clockwise")
                    .backendPrimaryCTALabel()
            }
            .labstreamGlassProminentButtonStyle()
            .disabled(isWorking)
            .frame(maxWidth: 340)

            Button("Sign in again", action: onSignInAgain)
                .labstreamGlassButtonStyle()
                .disabled(isWorking)
        }
    }
}


struct JellyfinQuickConnectCodeView: View {
    let code: String
    let onUseCredentials: () -> Void

    var body: some View {
        PairingCodeView(
            code: code,
            fallbackTitle: "Use username and password instead",
            onFallback: onUseCredentials) {
                VStack(spacing: DS.Space.xs) {
                    Text("Enter this code in Jellyfin")
                        .font(.title3.weight(.semibold))
                    Text("In an already signed-in Jellyfin app or web UI, open Quick Connect and enter the code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
    }
}

struct EmbyConnectPinCodeView: View {
    let code: String
    let onUseServerURL: () -> Void

    var body: some View {
        PairingCodeView(
            code: code,
            fallbackTitle: "Use a server URL instead",
            onFallback: onUseServerURL) {
                VStack(spacing: DS.Space.xs) {
                    Text("Enter this code at \(Text("emby.media/pin.html").fontWeight(.semibold).foregroundStyle(DS.Brand.amber))")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    Text("on your phone, tablet, or computer — sign in to Emby Connect there")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
    }
}

struct JellyfinSignInFlow: View {
    let state: AuthManager.State
    @Binding var server: String
    @Binding var username: String
    @Binding var password: String
    @Binding var signInMethod: JellyfinSignInMethod?
    let isWorking: Bool
    let onUseCredentialsFallback: () -> Void
    let onChooseQuickConnect: () -> Void
    let onChooseCredentials: () -> Void
    let onStartQuickConnect: () -> Void
    let onSignInWithCredentials: () -> Void
    let onChooseDifferentFromQuickConnect: () -> Void
    let onChooseDifferentFromCredentials: () -> Void

    var body: some View {
        switch state {
        case .awaitingJellyfinQuickConnect(let code):
            JellyfinQuickConnectCodeView(code: code, onUseCredentials: onUseCredentialsFallback)
        default:
            credentialsForm
        }
    }

    private var hasServerInput: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasCredentialInput: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var credentialsForm: some View {
        VStack(spacing: DS.Space.md) {
            BackendServerURLField(placeholder: "https://jellyfin.example.com", text: $server)

            switch signInMethod {
            case nil:
                methodChooser
            case .quickConnect:
                quickConnectStart
            case .credentials:
                usernamePasswordForm
            }
        }
    }

    private var methodChooser: some View {
        BackendSignInMethodChooser(
            primaryTitle: "Quick Connect",
            primarySystemImage: "link.badge.plus",
            secondaryTitle: "Username / Password",
            secondarySystemImage: "person.crop.circle.badge.checkmark",
            primaryDisabled: isWorking || !hasServerInput,
            secondaryDisabled: isWorking || !hasServerInput,
            disabledHint: hasServerInput ? nil : "Enter your Jellyfin server URL first.",
            onPrimary: onChooseQuickConnect,
            onSecondary: onChooseCredentials)
    }

    private var quickConnectStart: some View {
        BackendAuthStartView(
            isWorking: isWorking,
            workingTitle: "Starting Quick Connect…",
            startTitle: "Start Quick Connect",
            systemImage: "link.badge.plus",
            isStartDisabled: !hasServerInput,
            chooseDifferentTitle: "Choose a different sign-in method",
            onStart: onStartQuickConnect,
            onChooseDifferent: onChooseDifferentFromQuickConnect)
    }

    private var usernamePasswordForm: some View {
        BackendCredentialsSignInForm(
            username: $username,
            password: $password,
            isWorking: isWorking,
            signInTitle: "Sign in with Jellyfin",
            isSignInDisabled: isWorking || !hasServerInput || !hasCredentialInput,
            onSignIn: onSignInWithCredentials,
            onChooseDifferent: onChooseDifferentFromCredentials)
    }
}

struct EmbySignInFlow: View {
    let state: AuthManager.State
    @Binding var server: String
    @Binding var username: String
    @Binding var password: String
    @Binding var signInMethod: EmbySignInMethod?
    let isWorking: Bool
    @Binding var selectingServerID: String?
    let onUseServerURLFallback: () -> Void
    let onChooseConnectPin: () -> Void
    let onChooseServerCredentials: () -> Void
    let onStartConnectPin: () -> Void
    let onSelectServer: (AuthManager.EmbyConnectServerChoice) -> Void
    let onCancelServerSelection: () -> Void
    let onSignInWithCredentials: () -> Void
    let onChooseDifferentFromConnect: () -> Void
    let onChooseDifferentFromCredentials: () -> Void

    var body: some View {
        switch state {
        case .awaitingEmbyConnectPin(let code):
            EmbyConnectPinCodeView(code: code, onUseServerURL: onUseServerURLFallback)
        case .awaitingEmbyServerSelection(let servers):
            EmbyConnectServerPicker(
                servers: servers,
                isWorking: isWorking,
                selectingServerID: $selectingServerID,
                onSelect: onSelectServer,
                onCancel: onCancelServerSelection)
        default:
            methodForm
        }
    }

    private var hasServerInput: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasCredentialInput: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var methodForm: some View {
        switch signInMethod {
        case nil:
            methodChooser
        case .connectPin:
            connectStart
        case .credentials:
            credentialsForm
        }
    }

    /// Emby Connect PIN is the device-friendly primary path (needs no server address);
    /// the server-URL + username/password form is the secondary option.
    private var methodChooser: some View {
        BackendSignInMethodChooser(
            primaryTitle: "Sign in with Emby Connect",
            primarySystemImage: "link.badge.plus",
            secondaryTitle: "Sign in with server URL",
            secondarySystemImage: "server.rack",
            primaryDisabled: isWorking,
            secondaryDisabled: isWorking,
            footer: "Emby Connect uses a code at emby.media/pin.html — no server address needed.",
            onPrimary: onChooseConnectPin,
            onSecondary: onChooseServerCredentials)
    }

    private var connectStart: some View {
        BackendAuthStartView(
            isWorking: isWorking,
            workingTitle: "Starting Emby Connect…",
            startTitle: "Start Emby Connect",
            systemImage: "link.badge.plus",
            isStartDisabled: false,
            chooseDifferentTitle: "Choose a different sign-in method",
            onStart: onStartConnectPin,
            onChooseDifferent: onChooseDifferentFromConnect)
    }

    private var credentialsForm: some View {
        BackendCredentialsSignInForm(
            serverURLPlaceholder: "https://emby.example.com",
            serverURLText: $server,
            username: $username,
            password: $password,
            isWorking: isWorking,
            signInTitle: "Sign in with Emby",
            isSignInDisabled: isWorking || !hasServerInput || !hasCredentialInput,
            onSignIn: onSignInWithCredentials,
            onChooseDifferent: onChooseDifferentFromCredentials)
    }
}

struct BackendServerURLField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.URL)
            .keyboardType(.URL)
            .submitLabel(.next)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 420)
    }
}

struct BackendSignInMethodChooser: View {
    let prompt: String
    let primaryTitle: String
    let primarySystemImage: String
    let secondaryTitle: String
    let secondarySystemImage: String
    let primaryDisabled: Bool
    let secondaryDisabled: Bool
    let disabledHint: String?
    let footer: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    init(prompt: String = "Choose how to sign in.",
         primaryTitle: String,
         primarySystemImage: String,
         secondaryTitle: String,
         secondarySystemImage: String,
         primaryDisabled: Bool,
         secondaryDisabled: Bool,
         disabledHint: String? = nil,
         footer: String? = nil,
         onPrimary: @escaping () -> Void,
         onSecondary: @escaping () -> Void) {
        self.prompt = prompt
        self.primaryTitle = primaryTitle
        self.primarySystemImage = primarySystemImage
        self.secondaryTitle = secondaryTitle
        self.secondarySystemImage = secondarySystemImage
        self.primaryDisabled = primaryDisabled
        self.secondaryDisabled = secondaryDisabled
        self.disabledHint = disabledHint
        self.footer = footer
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            Text(prompt)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: DS.Space.sm) {
                Button(action: onPrimary) {
                    Label(primaryTitle, systemImage: primarySystemImage)
                        .backendPrimaryCTALabel()
                }
                .labstreamGlassProminentButtonStyle()
                .disabled(primaryDisabled)

                Button(action: onSecondary) {
                    Label(secondaryTitle, systemImage: secondarySystemImage)
                        .backendPrimaryCTALabel()
                }
                .labstreamGlassButtonStyle()
                .disabled(secondaryDisabled)
            }
            .frame(maxWidth: 340)

            if let disabledHint, !disabledHint.isEmpty {
                Text(disabledHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
    }
}

struct BackendAuthStartView: View {
    let isWorking: Bool
    let workingTitle: String
    let startTitle: String
    let systemImage: String
    let isStartDisabled: Bool
    let chooseDifferentTitle: String
    let onStart: () -> Void
    let onChooseDifferent: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            if isWorking {
                HStack(spacing: DS.Space.sm) {
                    ProgressView()
                    Text(workingTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(action: onStart) {
                    Label(startTitle, systemImage: systemImage)
                        .backendPrimaryCTALabel()
                }
                .labstreamGlassProminentButtonStyle()
                .disabled(isStartDisabled)
                .frame(maxWidth: 340)
            }

            Button(chooseDifferentTitle, action: onChooseDifferent)
                .labstreamGlassButtonStyle()
        }
    }
}

struct BackendCredentialsSignInForm: View {
    let serverURLPlaceholder: String?
    let serverURLText: Binding<String>?
    let username: Binding<String>
    let password: Binding<String>
    let isWorking: Bool
    let signInTitle: String
    let systemImage: String
    let isSignInDisabled: Bool
    let chooseDifferentTitle: String
    let onSignIn: () -> Void
    let onChooseDifferent: () -> Void

    init(serverURLPlaceholder: String? = nil,
         serverURLText: Binding<String>? = nil,
         username: Binding<String>,
         password: Binding<String>,
         isWorking: Bool,
         signInTitle: String,
         systemImage: String = "person.crop.circle.badge.checkmark",
         isSignInDisabled: Bool,
         chooseDifferentTitle: String = "Choose a different sign-in method",
         onSignIn: @escaping () -> Void,
         onChooseDifferent: @escaping () -> Void) {
        self.serverURLPlaceholder = serverURLPlaceholder
        self.serverURLText = serverURLText
        self.username = username
        self.password = password
        self.isWorking = isWorking
        self.signInTitle = signInTitle
        self.systemImage = systemImage
        self.isSignInDisabled = isSignInDisabled
        self.chooseDifferentTitle = chooseDifferentTitle
        self.onSignIn = onSignIn
        self.onChooseDifferent = onChooseDifferent
    }

    var body: some View {
        VStack(spacing: DS.Space.md) {
            if let serverURLPlaceholder, let serverURLText {
                BackendServerURLField(placeholder: serverURLPlaceholder, text: serverURLText)
            }

            TextField("Username", text: username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .submitLabel(.next)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            SecureField("Password", text: password)
                .textContentType(.password)
                .submitLabel(.go)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            Button(action: submitIfAllowed) {
                Group {
                    if isWorking {
                        Label {
                            Text("Signing in…")
                        } icon: {
                            ProgressView()
                        }
                    } else {
                        Label(signInTitle, systemImage: systemImage)
                    }
                }
                .backendPrimaryCTALabel()
            }
            .labstreamGlassProminentButtonStyle()
            .disabled(!canSubmit)
            .frame(maxWidth: 340)

            Button(chooseDifferentTitle, action: onChooseDifferent)
                .labstreamGlassButtonStyle()
        }
        .onSubmit(submitIfAllowed)
    }

    private var hasRequiredFields: Bool {
        let hasServer: Bool
        if let serverURLText {
            hasServer = !serverURLText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            hasServer = true
        }
        let hasUsername = !username.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasServer && hasUsername && hasPassword
    }

    private var canSubmit: Bool {
        !isWorking && !isSignInDisabled && hasRequiredFields
    }

    private func submitIfAllowed() {
        guard canSubmit else { return }
        onSignIn()
    }
}


struct EmbyConnectServerPicker: View {
    let servers: [AuthManager.EmbyConnectServerChoice]
    let isWorking: Bool
    @Binding var selectingServerID: String?
    let onSelect: (AuthManager.EmbyConnectServerChoice) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("Choose a server")
                    .font(.title3.weight(.semibold))
                Text("Your Emby Connect account is linked to more than one server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: DS.Space.sm) {
                ForEach(servers) { server in
                    Button {
                        onSelect(server)
                    } label: {
                        HStack(spacing: DS.Space.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.headline)
                                if !server.addressLabel.isEmpty {
                                    Text(server.addressLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: DS.Space.sm)
                            if selectingServerID == server.id {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.xs)
                    }
                    .labstreamGlassButtonStyle()
                    .disabled(isWorking || selectingServerID != nil)
                }
            }
            .frame(maxWidth: 420)

            Button("Cancel", action: onCancel)
                .labstreamGlassButtonStyle()
                .disabled(isWorking || selectingServerID != nil)
        }
    }
}
