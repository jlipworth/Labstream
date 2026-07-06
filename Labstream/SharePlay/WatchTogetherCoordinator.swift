import AVFoundation
import Foundation
import GroupActivities
import Observation
import PMSKit

/// App-lifetime coordinator for the conservative first SharePlay / Watch Together slice.
///
/// This owns the GroupActivities session lifecycle and exposes a tiny state machine to SwiftUI.
/// Actual transport synchronization is intentionally delegated to AVPlayerPlaybackCoordinator;
/// this type never sends custom play/pause/seek messages.
@MainActor
@Observable
final class WatchTogetherCoordinator {
    enum State: Equatable, Sendable {
        case inactive
        case resolving(title: String)
        case unavailable(title: String, reason: UnavailableReason)
        case active(title: String)

        var title: String? {
            switch self {
            case .inactive: return nil
            case .resolving(let title), .unavailable(let title, _), .active(let title): return title
            }
        }
    }

    enum UnavailableReason: String, Equatable, Sendable {
        case unsupportedItem
        case activationDisabled
        case activationCancelled
        case activationFailed
        case currentLibraryResolutionUnavailable
        case coordinatorIdentifierUnavailable
        case noActiveSession
    }

    struct PendingLocalShare: Sendable, Equatable {
        let activityID: UUID
        let title: String
        let coordinatorIdentifier: String
    }

    private(set) var state: State = .inactive

    var hasActiveSession: Bool { activeSession != nil }

    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: GroupSession<WatchTogetherActivity>?
    @ObservationIgnored private var activeCoordinatorIdentifier: String?
    @ObservationIgnored private var pendingLocalShare: PendingLocalShare?

    func startObservingSessionsIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            for await session in WatchTogetherActivity.sessions() {
                self?.handle(session)
            }
        }
    }

    /// User-facing entry point from an item detail page. It activates a minimal activity whose
    /// payload contains the exact sanitized title only. The richer identity remains local, and the
    /// resulting opaque coordinator id is stored only for later AVPlayerPlaybackCoordinator setup.
    func requestWatchTogether(for item: MediaItem) async {
        guard let payload = SharePlayMediaActivityPayload(mediaItem: item) else {
            state = .unavailable(title: item.title, reason: .unsupportedItem)
            return
        }
        guard let identity = item.sharePlayMediaIdentity,
              let coordinatorIdentifier = identity.coordinatorIdentifier else {
            state = .unavailable(title: payload.displayTitle, reason: .coordinatorIdentifierUnavailable)
            return
        }

        let activity = WatchTogetherActivity(payload: payload)
        state = .resolving(title: payload.displayTitle)
        do {
            switch await activity.prepareForActivation() {
            case .activationPreferred:
                pendingLocalShare = PendingLocalShare(activityID: payload.activityID,
                                                      title: payload.displayTitle,
                                                      coordinatorIdentifier: coordinatorIdentifier)
                _ = try await activity.activate()
            case .activationDisabled:
                pendingLocalShare = nil
                state = .unavailable(title: payload.displayTitle, reason: .activationDisabled)
            case .cancelled:
                pendingLocalShare = nil
                state = .unavailable(title: payload.displayTitle, reason: .activationCancelled)
            @unknown default:
                pendingLocalShare = nil
                state = .unavailable(title: payload.displayTitle, reason: .activationFailed)
            }
        } catch {
            pendingLocalShare = nil
            state = .unavailable(title: payload.displayTitle, reason: .activationFailed)
        }
    }

    /// Boundary for the incoming-session current-library resolver. The first scaffolding milestone
    /// deliberately fails closed because no current-library snapshot is wired into this coordinator
    /// yet. The next implementation should pass the currently displayed library items here and use
    /// `SharePlayMediaResolver` to require one exact, timeline-safe match before joining.
    func resolveIncomingAgainstCurrentLibrary(_ activity: WatchTogetherActivity,
                                              currentLibraryItems: [MediaItem]) -> MediaItem? {
        _ = currentLibraryItems
        state = .unavailable(title: activity.payload.displayTitle,
                             reason: .currentLibraryResolutionUnavailable)
        return nil
    }

    /// Attach the active SharePlay session to a local AVPlayer after local resolution succeeded.
    /// Returns false rather than joining/syncing when the item cannot produce the same opaque
    /// coordinator id that was accepted for the session.
    @discardableResult
    func attachPlaybackCoordinatorIfReady(player: AVPlayer, item: MediaItem) -> Bool {
        guard let session = activeSession else {
            return false
        }
        guard let coordinatorIdentifier = item.sharePlayMediaIdentity?.coordinatorIdentifier,
              coordinatorIdentifier == activeCoordinatorIdentifier else {
            state = .unavailable(title: item.title, reason: .coordinatorIdentifierUnavailable)
            return false
        }

        player.playbackCoordinator.coordinateWithSession(session)
        return true
    }

    func leave() {
        activeSession?.leave()
        activeSession = nil
        activeCoordinatorIdentifier = nil
        pendingLocalShare = nil
        state = .inactive
    }

    private func handle(_ session: GroupSession<WatchTogetherActivity>) {
        let activity = session.activity
        state = .resolving(title: activity.payload.displayTitle)

        if let pending = pendingLocalShare,
           pending.activityID == activity.payload.activityID {
            activeSession = session
            activeCoordinatorIdentifier = pending.coordinatorIdentifier
            pendingLocalShare = nil
            session.join()
            state = .active(title: pending.title)
            return
        }

        // Incoming shares need current-library resolution before joining. Until the current
        // library snapshot is wired in, fail closed and do not attach AVPlayer coordination.
        _ = resolveIncomingAgainstCurrentLibrary(activity, currentLibraryItems: [])
    }
}

extension WatchTogetherCoordinator.UnavailableReason {
    var userMessage: String {
        switch self {
        case .unsupportedItem:
            return "Watch Together supports movies and episodes only."
        case .activationDisabled:
            return "SharePlay isn’t available for this session."
        case .activationCancelled:
            return "Watch Together was cancelled."
        case .activationFailed:
            return "Couldn’t start Watch Together."
        case .currentLibraryResolutionUnavailable:
            return "This shared title isn’t available from the current library yet."
        case .coordinatorIdentifierUnavailable:
            return "This item can’t be matched safely for Watch Together."
        case .noActiveSession:
            return "No active Watch Together session is ready."
        }
    }
}
