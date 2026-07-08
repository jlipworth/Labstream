import AuthenticationServices
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Presents the Plex sign-in page in an `ASWebAuthenticationSession` — a managed,
/// in-app web sheet — instead of kicking the user out to a standalone Safari
/// window that the app can't close.
///
/// The Plex PIN flow completes via background *polling*, not a redirect callback,
/// so no `callbackURLScheme` ever fires. Instead the sheet is dismissed
/// programmatically by calling `cancel()` once the app becomes authenticated —
/// that's what makes the web sheet auto-close after a successful sign-in.
@MainActor
final class WebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// Open `url` in a managed web sheet. `onCancel` fires only if the user
    /// dismisses the sheet themselves (so the UI can reset); success is handled
    /// by the caller observing auth state and calling `cancel()`.
    func start(_ url: URL, onCancel: @escaping () -> Void) {
        cancel()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "visionplay") { _, error in
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                onCancel()
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    /// Dismiss the web sheet. Call on auth success (or teardown).
    func cancel() {
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        if let key = NSApplication.shared.keyWindow { return key }
        if let main = NSApplication.shared.mainWindow { return main }
        if let visible = NSApplication.shared.windows.first(where: { $0.isVisible }) { return visible }
        if let any = NSApplication.shared.windows.first { return any }
        preconditionFailure("ASWebAuthenticationSession requires an active NSWindow")
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        if let window { return window }
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        preconditionFailure("ASWebAuthenticationSession requires an active window scene")
        #endif
    }
}
