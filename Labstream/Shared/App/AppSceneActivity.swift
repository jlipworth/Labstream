#if !os(tvOS)
import SwiftUI

/// App-lifetime foreground truth composed from every mounted SwiftUI scene.
///
/// A raw `scenePhase` belongs to one scene. Treating the latest raw event as the
/// whole process state is incorrect on visionOS (the main window and Cinema can
/// overlap) and on macOS (Settings can remain active while the main window is
/// hidden). This aggregate publishes only active/not-active edges to lifecycle
/// consumers, so secondary-scene churn cannot repeatedly restart or cancel
/// foreground-only download work.
@MainActor
final class AppSceneActivity {
    /// A cancellable, deferred transition supplied by the production handoff
    /// scheduler or a deterministic test scheduler.
    @MainActor
    final class ScheduledTransition {
        private var cancellation: (@MainActor () -> Void)?

        init(cancellation: @escaping @MainActor () -> Void) {
            self.cancellation = cancellation
        }

        func cancel() {
            cancellation?()
            cancellation = nil
        }
    }

    typealias InactivityScheduler =
        (@escaping @MainActor () -> Void) -> ScheduledTransition

    enum Role: String, Sendable {
        case mainWindow
        case cinemaImmersive
        case settings
    }

    private struct Source {
        let role: Role
        var phase: ScenePhase
    }

    private var sources: [UUID: Source] = [:]
    private let scheduleInactivity: InactivityScheduler
    private let onActiveChange: @MainActor (Bool) -> Void
    private var pendingInactivity: ScheduledTransition?

    private(set) var isActive = false

    convenience init(onActiveChange: @escaping @MainActor (Bool) -> Void) {
        self.init(scheduleInactivity: Self.scheduleAfterHandoffGrace,
                  onActiveChange: onActiveChange)
    }

    init(scheduleInactivity: @escaping InactivityScheduler,
         onActiveChange: @escaping @MainActor (Bool) -> Void) {
        self.scheduleInactivity = scheduleInactivity
        self.onActiveChange = onActiveChange
    }

    func report(sourceID: UUID, role: Role, phase: ScenePhase) {
        sources[sourceID] = Source(role: role, phase: phase)
        publishAggregateIfNeeded()
    }

    func remove(sourceID: UUID) {
        guard sources.removeValue(forKey: sourceID) != nil else { return }
        publishAggregateIfNeeded()
    }

    private func publishAggregateIfNeeded() {
        let nextIsActive = sources.values.contains { $0.phase == .active }
        if nextIsActive {
            pendingInactivity?.cancel()
            pendingInactivity = nil
            guard !isActive else { return }
            isActive = true
            onActiveChange(true)
            return
        }

        // Scene replacement is not atomically ordered: the outgoing main scene can
        // report inactive/background or disappear before Cinema/Settings reports
        // active. Hold the negative edge briefly so an arriving active source can
        // cancel it, while still guaranteeing that a true no-successor transition
        // eventually publishes inactive.
        guard isActive, pendingInactivity == nil else { return }
        pendingInactivity = scheduleInactivity { [weak self] in
            guard let self else { return }
            self.pendingInactivity = nil
            guard self.isActive,
                  !self.sources.values.contains(where: { $0.phase == .active }) else {
                return
            }
            self.isActive = false
            self.onActiveChange(false)
        }
    }

    private static func scheduleAfterHandoffGrace(
        _ operation: @escaping @MainActor () -> Void
    ) -> ScheduledTransition {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            operation()
        }
        return ScheduledTransition(cancellation: { task.cancel() })
    }
}

/// Reads `scenePhase` inside one scene's view tree and gives that mounted
/// instance a unique identity in the app-level aggregate.
private struct AppSceneActivityReporter: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sourceID = UUID()

    let activity: AppSceneActivity
    let role: AppSceneActivity.Role

    func body(content: Content) -> some View {
        content
            .onAppear {
                activity.report(sourceID: sourceID, role: role, phase: scenePhase)
            }
            .onChange(of: scenePhase) { _, newPhase in
                activity.report(sourceID: sourceID, role: role, phase: newPhase)
            }
            .onDisappear {
                activity.remove(sourceID: sourceID)
            }
    }
}

extension View {
    func reportsAppSceneActivity(_ activity: AppSceneActivity,
                                 role: AppSceneActivity.Role) -> some View {
        modifier(AppSceneActivityReporter(activity: activity, role: role))
    }
}
#endif
