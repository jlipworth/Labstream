import Foundation
import SwiftUI

/// Shared app-lifetime runtime used by every shipping entrypoint.
///
/// Keep this intentionally narrow: tvOS receives only its streaming services, while the
/// platforms that ship Offline also receive a download manager. Platform-specific
/// capabilities, scenes, and lifecycle hooks remain in their app entrypoint files.
@MainActor
struct AppRuntime {
    let appModel: AppModel
    let authManager: AuthManager
    #if !os(tvOS)
    let downloadManager: DownloadManager
    let sceneActivity: AppSceneActivity
    #endif
    let musicPlayer: MusicPlayerController
    /// One exact-authority catalog repository shared across all windows and browse surfaces.
    let libraryCatalogRepository = LibraryCatalogRepository()
    /// One exact-authority item metadata repository shared by system entry and detail display.
    let metadataRepository = MetadataRepository()
    /// One credential-safe artwork execution facade shared by every artwork consumer: views,
    /// system Now Playing, player metadata, and local Offline thumbnails.
    let artworkPipeline: ArtworkPipeline
    /// One reference-counted shimmer ticker shared by all visible artwork placeholders.
    let artworkShimmerClock = ArtworkShimmerClock()
    /// One launch bootstrap shared by every window/scene that presents this runtime. In
    /// particular, dismissing and reopening the visionOS main window for Cinema must never
    /// re-run session restore or flash the sign-in UI over an already-restored session.
    let bootstrap: SessionBootstrap

    static func make(keychain providedKeychain: KeychainStore? = nil,
                     bootstrap: SessionBootstrap = SessionBootstrap()) -> AppRuntime? {
        #if os(tvOS)
        let downloadsCapable = 0
        #else
        let downloadsCapable = 1
        #endif
        let compositionSpan = PerformanceInstrumentation.begin(.runtimeComposition,
                                                                backend: "App")
        defer {
            compositionSpan.end(fields: ["downloads_capable": downloadsCapable])
        }

        let keychain = providedKeychain ?? AppKeychainService.makeStore()
        // The client identifier is routing metadata, not a credential. If secure storage is
        // temporarily unavailable, use a process-local identity so the app can still finish
        // launching (most importantly on download-capable platforms, so background URLSession
        // events can be drained). A later launch retries the durable identifier; credentials
        // themselves remain fail-closed.
        let clientIdentifier = keychain.clientIdentifier() ?? UUID().uuidString
        let identity = PlatformClientIdentity.make(clientIdentifier: clientIdentifier)
        let model = AppModel(identity: identity, activeBackend: keychain.selectedBackend)
        let authManager = AuthManager(appModel: model, keychain: keychain)
        let artworkPipeline = ArtworkPipeline()

        #if os(tvOS)
        // Downloads are not a TV product. Keep the capability absent from the tvOS service
        // graph: do not create a manager, store, migration/recovery coordinator, or background
        // URLSession merely to satisfy a shared initializer.
        return AppRuntime(
            appModel: model,
            authManager: authManager,
            musicPlayer: MusicPlayerController(appModel: model,
                                               artworkPipeline: artworkPipeline),
            artworkPipeline: artworkPipeline,
            bootstrap: bootstrap
        )
        #else
        let downloadManager = DownloadManager(
            appModel: model,
            registerForBackgroundEvents: true)
        // Sign-out is the one lifecycle edge where an already-open URLSession request can retain
        // a just-revoked authorization header. Pause that backend's work before AuthManager
        // clears its runtime session; weak capture keeps the service graph acyclic.
        authManager.onBackendWillSignOut = { [weak downloadManager] backend in
            downloadManager?.pauseDownloadsForBackendSignOut(backend)
        }
        let lifecycleCoordinator = RuntimeLifecycleCoordinator(
            requestDownloadRecovery: { [weak downloadManager] reason in
                guard PlatformFeaturePolicy.supportsDownloads else { return }
                downloadManager?.noteAppSceneRecovery(reason)
            },
            flushBestEffortState: {
                AppDiagnostics.flush(durability: .bestEffort)
            }
        )
        // The activity reporter retains the coordinator through this closure for the runtime's
        // lifetime. The coordinator does not retain the reporter, so no cycle is formed.
        let sceneActivity = AppSceneActivity { isActive in
            lifecycleCoordinator.aggregateSceneActivityChanged(isActive: isActive)
        }
        return AppRuntime(
            appModel: model,
            authManager: authManager,
            downloadManager: downloadManager,
            sceneActivity: sceneActivity,
            musicPlayer: MusicPlayerController(appModel: model,
                                               artworkPipeline: artworkPipeline),
            artworkPipeline: artworkPipeline,
            bootstrap: bootstrap
        )
        #endif
    }
}

/// App-lifetime launch bootstrap state. It lives in `AppRuntime`, above any window, so
/// entering/leaving Cinema or opening Mac Settings never retriggers the one-time restore.
@MainActor
@Observable
final class SessionBootstrap {
    /// True until the launch-time `restoreSession()` finishes.
    var isRestoring = true
    /// Set once the restore has been kicked off, so a recreated window skips it.
    var didStartRestore = false
    /// True once browse UI has mounted in this process. This keeps an already-ready UI mounted
    /// through a backend switch instead of bouncing through the restore splash.
    var hasEverBeenBrowseReady = false
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
                                 usesDevelopmentFileStorage: DevelopmentCredentialStoragePolicy
                                    .allowsFileStorage(isCanonicalService: isCanonicalService))
        }
        #endif
        return KeychainStore()
    }
}

enum DevelopmentCredentialStoragePolicy {
    static func allowsFileStorage(isCanonicalService: Bool) -> Bool {
        #if DEBUG && os(macOS)
        !isCanonicalService
        #else
        false
        #endif
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
        #if !os(tvOS)
        LabstreamShortcuts.updateAppShortcutParameters()
        MetricKitDiagnostics.shared.register()
        #endif
        AppDiagnostics.record(.downloads, "app.process_launch", fields: [
            "launch_source": .label("process_start"),
        ])
    }

}
