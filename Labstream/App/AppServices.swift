import Foundation
import SwiftUI

/// Shared app-lifetime service bundle used by every shipping entrypoint.
///
/// Keep this intentionally narrow: it owns only the bootstrap chain that is common to
/// visionOS, iOS/iPadOS, and native macOS. Platform-specific scenes/lifecycle hooks remain
/// in their app entrypoint files.
@MainActor
struct AppServices {
    let appModel: AppModel
    let authManager: AuthManager
    let downloadManager: DownloadManager
    let musicPlayer: MusicPlayerController

    static func make(keychain providedKeychain: KeychainStore? = nil) -> AppServices? {
        let keychain = providedKeychain ?? AppKeychainService.makeStore()
        guard let clientIdentifier = keychain.clientIdentifier() else {
            return nil
        }
        let identity = PlatformClientIdentity.make(clientIdentifier: clientIdentifier)
        let model = AppModel(identity: identity, activeBackend: keychain.selectedBackend)
        return AppServices(
            appModel: model,
            authManager: AuthManager(appModel: model, keychain: keychain),
            downloadManager: DownloadManager(appModel: model),
            musicPlayer: MusicPlayerController(appModel: model)
        )
    }
}

struct SecureStorageUnavailableView: View {
    var body: some View {
        ContentUnavailableView("Secure Storage Unavailable",
                               systemImage: "lock.trianglebadge.exclamationmark",
                               description: Text("Labstream couldn’t access secure storage. Quit and reopen the app, then try again."))
    }
}

private enum AppKeychainService {
    static func makeStore() -> KeychainStore {
        #if os(macOS)
        if let service = Bundle.main.object(forInfoDictionaryKey: "LabstreamKeychainService") as? String,
           !service.isEmpty,
           !service.contains("$(") {
            // Per-worktree macOS dev identities intentionally isolate credentials. Do not
            // attempt iCloud-synchronizable Plex-token writes for those ad-hoc/sandboxed
            // host apps; they can fail with missing app-identifier/keychain entitlements
            // and they would also defeat worktree isolation. The canonical service keeps
            // the existing cross-device sync policy for production/App Store-style builds.
            let isCanonicalService = service == "com.visionplay.app"
            return KeychainStore(service: service,
                                 synchronizesPlexToken: isCanonicalService,
                                 usesDevelopmentFileStorage: !isCanonicalService)
        }
        #endif
        return KeychainStore()
    }
}

enum AppLaunchMode {
    static var isUnitTestHost: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LABSTREAM_UNIT_TEST_HOST"] == "1"
        #else
        false
        #endif
    }
}

@MainActor
enum AppStartup {
    /// One process-start hook shared by the app entrypoints. Registration is safe to call
    /// exactly once per process and deliberately avoids logging credentials or server details.
    static func prepareForLaunch() {
        LabstreamShortcuts.updateAppShortcutParameters()
        MetricKitDiagnostics.shared.register()
        AppDiagnostics.record(.downloads, "app.process_launch", fields: [
            "launch_source": .label("process_start"),
        ])
    }

    static func recordScenePhase(_ phase: ScenePhase, downloadManager: DownloadManager) {
        let label: String
        switch phase {
        case .active: label = "active"
        case .inactive: label = "inactive"
        case .background: label = "background"
        @unknown default: label = "unknown"
        }
        AppDiagnostics.record(.downloads, "app.scene_phase", fields: [
            "phase": .label(label),
        ])
        downloadManager.noteAppScenePhase(label)
    }
}
