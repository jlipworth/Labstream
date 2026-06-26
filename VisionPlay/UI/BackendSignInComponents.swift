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
