import Foundation

/// Typed reasons for asking download-capable runtime services to reconsider recovery work.
enum DownloadRecoveryReason: String, Equatable, Sendable {
    case aggregateSceneBecameActive
    case aggregateSceneBecameInactive

    var scenePhaseLabel: String {
        switch self {
        case .aggregateSceneBecameActive: "active"
        case .aggregateSceneBecameInactive: "inactive"
        }
    }
}

/// One process-level lifecycle authority above the individual SwiftUI scenes.
///
/// `AppSceneActivity` retains its 500 ms scene-handoff grace. This coordinator deduplicates the
/// resulting aggregate edge, flushes best-effort diagnostics before genuine inactivity, and gives
/// recovery consumers a typed reason rather than a free-form phase string.
@MainActor
final class RuntimeLifecycleCoordinator {
    private let requestDownloadRecovery: @MainActor (DownloadRecoveryReason) -> Void
    private let flushBestEffortState: @MainActor () -> Void
    private var lastPublishedActivity: Bool?

    init(requestDownloadRecovery: @escaping @MainActor (DownloadRecoveryReason) -> Void,
         flushBestEffortState: @escaping @MainActor () -> Void = {}) {
        self.requestDownloadRecovery = requestDownloadRecovery
        self.flushBestEffortState = flushBestEffortState
    }

    func aggregateSceneActivityChanged(isActive: Bool) {
        guard lastPublishedActivity != isActive else { return }
        lastPublishedActivity = isActive

        let reason: DownloadRecoveryReason = isActive
            ? .aggregateSceneBecameActive
            : .aggregateSceneBecameInactive
        AppDiagnostics.record(.downloads, "app.scene_phase", fields: [
            "phase": .label(reason.scenePhaseLabel),
            "recovery_reason": .label(reason.rawValue),
        ])
        if !isActive { flushBestEffortState() }
        requestDownloadRecovery(reason)
    }
}
