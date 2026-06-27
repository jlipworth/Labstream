import SwiftUI

/// Shared backend-auth form primitives used by `LoginView`.
///
/// These are deliberately presentation-only: callers own validation, auth-manager actions,
/// cancellation, and credential storage semantics.
struct BackendServerURLField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.URL)
            .keyboardType(.URL)
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
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)

                Button(action: onSecondary) {
                    Label(secondaryTitle, systemImage: secondarySystemImage)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
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
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.xs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStartDisabled)
            }

            Button(chooseDifferentTitle, action: onChooseDifferent)
                .buttonStyle(.bordered)
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
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            SecureField("Password", text: password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            Button(action: onSignIn) {
                if isWorking {
                    ProgressView()
                } else {
                    Label(signInTitle, systemImage: systemImage)
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.xs)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSignInDisabled)

            Button(chooseDifferentTitle, action: onChooseDifferent)
                .buttonStyle(.bordered)
        }
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
                    .buttonStyle(.bordered)
                    .disabled(isWorking || selectingServerID != nil)
                }
            }
            .frame(maxWidth: 420)

            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .disabled(isWorking || selectingServerID != nil)
        }
    }
}
