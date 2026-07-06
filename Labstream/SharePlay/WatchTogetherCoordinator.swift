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
    struct PresentationContext: Equatable, Sendable {
        let title: String
        let coordinatorIdentifier: String?

        static func available(title: String, coordinatorIdentifier: String) -> PresentationContext {
            PresentationContext(title: title, coordinatorIdentifier: coordinatorIdentifier)
        }

        static func unavailable(title: String) -> PresentationContext {
            PresentationContext(title: title, coordinatorIdentifier: nil)
        }
    }

    enum State: Equatable, Sendable {
        case inactive
        case resolving(PresentationContext)
        case unavailable(PresentationContext, reason: UnavailableReason)
        case active(PresentationContext)

        var title: String? {
            switch self {
            case .inactive: return nil
            case .resolving(let context), .unavailable(let context, _), .active(let context): return context.title
            }
        }

        var coordinatorIdentifier: String? {
            switch self {
            case .inactive: return nil
            case .resolving(let context), .unavailable(let context, _), .active(let context):
                return context.coordinatorIdentifier
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
    @ObservationIgnored private var activeSessionStateTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: GroupSession<WatchTogetherActivity>?
    @ObservationIgnored private var activeCoordinatorIdentifier: String?
    @ObservationIgnored private var pendingLocalShare: PendingLocalShare?
    @ObservationIgnored private var playbackCoordinatorDelegate: WatchTogetherPlaybackCoordinatorDelegate?

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
            state = .unavailable(.unavailable(title: item.title), reason: .unsupportedItem)
            return
        }
        guard let identity = item.sharePlayMediaIdentity,
              let coordinatorIdentifier = identity.coordinatorIdentifier else {
            state = .unavailable(.unavailable(title: payload.displayTitle), reason: .coordinatorIdentifierUnavailable)
            return
        }
        let context = PresentationContext.available(title: payload.displayTitle,
                                                    coordinatorIdentifier: coordinatorIdentifier)

        let activity = WatchTogetherActivity(payload: payload)
        state = .resolving(context)
        do {
            switch await activity.prepareForActivation() {
            case .activationPreferred:
                pendingLocalShare = PendingLocalShare(activityID: payload.activityID,
                                                      title: payload.displayTitle,
                                                      coordinatorIdentifier: coordinatorIdentifier)
                _ = try await activity.activate()
            case .activationDisabled:
                pendingLocalShare = nil
                state = .unavailable(context, reason: .activationDisabled)
            case .cancelled:
                pendingLocalShare = nil
                state = .unavailable(context, reason: .activationCancelled)
            @unknown default:
                pendingLocalShare = nil
                state = .unavailable(context, reason: .activationFailed)
            }
        } catch {
            pendingLocalShare = nil
            state = .unavailable(context, reason: .activationFailed)
        }
    }

    /// Boundary for the incoming-session current-library resolver. The first scaffolding milestone
    /// deliberately fails closed because no current-library snapshot is wired into this coordinator
    /// yet. The next implementation should pass the currently displayed library items here and use
    /// `SharePlayMediaResolver` to require one exact, timeline-safe match before joining.
    func resolveIncomingAgainstCurrentLibrary(_ activity: WatchTogetherActivity,
                                              currentLibraryItems: [MediaItem]) -> MediaItem? {
        _ = currentLibraryItems
        state = .unavailable(.unavailable(title: activity.payload.displayTitle),
                             reason: .currentLibraryResolutionUnavailable)
        return nil
    }

    /// Attach the active SharePlay session to a local AVPlayer after local resolution succeeded.
    /// Returns false rather than joining/syncing when the item cannot produce the same opaque
    /// coordinator id that was accepted for the session. The AVPlayerPlaybackCoordinator delegate
    /// is installed before coordination so AVFoundation never falls back to URL/asset-derived item
    /// identifiers, which may contain tokens or backend-local stream URLs.
    @discardableResult
    func attachPlaybackCoordinatorIfReady(player: AVPlayer, item: MediaItem) -> Bool {
        guard let session = activeSession else {
            return false
        }
        guard let coordinatorIdentifier = item.sharePlayMediaIdentity?.coordinatorIdentifier,
              coordinatorIdentifier == activeCoordinatorIdentifier else {
            state = .unavailable(.unavailable(title: item.title), reason: .coordinatorIdentifierUnavailable)
            playbackCoordinatorDelegate = nil
            player.playbackCoordinator.delegate = nil
            return false
        }
        guard let currentItem = player.currentItem else {
            state = .unavailable(.available(title: item.title, coordinatorIdentifier: coordinatorIdentifier),
                                 reason: .coordinatorIdentifierUnavailable)
            playbackCoordinatorDelegate = nil
            player.playbackCoordinator.delegate = nil
            return false
        }

        let delegate = WatchTogetherPlaybackCoordinatorDelegate(playerItem: currentItem,
                                                               coordinatorIdentifier: coordinatorIdentifier)
        playbackCoordinatorDelegate = delegate
        player.playbackCoordinator.delegate = delegate
        player.playbackCoordinator.coordinateWithSession(session)
        return true
    }

    /// Whether the current status belongs to this detail item. Prefer the opaque accepted
    /// AVPlayerPlaybackCoordinator id over display title so sanitized/truncated titles and
    /// same-title media do not show misleading status.
    func stateApplies(to item: MediaItem) -> Bool {
        guard let stateIdentifier = state.coordinatorIdentifier,
              let itemIdentifier = item.sharePlayMediaIdentity?.coordinatorIdentifier else {
            return false
        }
        return stateIdentifier == itemIdentifier
    }

    func leave() {
        activeSession?.leave()
        clearActiveSession()
    }

    private func handle(_ session: GroupSession<WatchTogetherActivity>) {
        let activity = session.activity
        state = .resolving(.unavailable(title: activity.payload.displayTitle))

        if let pending = pendingLocalShare,
           pending.activityID == activity.payload.activityID {
            activeSession = session
            activeCoordinatorIdentifier = pending.coordinatorIdentifier
            pendingLocalShare = nil
            observeInvalidation(of: session)
            session.join()
            state = .active(.available(title: pending.title,
                                       coordinatorIdentifier: pending.coordinatorIdentifier))
            return
        }

        // Incoming shares need current-library resolution before joining. Until the current
        // library snapshot is wired in, fail closed and do not attach AVPlayer coordination.
        _ = resolveIncomingAgainstCurrentLibrary(activity, currentLibraryItems: [])
    }

    private func observeInvalidation(of session: GroupSession<WatchTogetherActivity>) {
        activeSessionStateTask?.cancel()
        if case .invalidated = session.state {
            clearActiveSession()
            return
        }
        activeSessionStateTask = Task { [weak self, weak session] in
            guard let session else { return }
            for await sessionState in session.$state.values {
                guard case .invalidated = sessionState else { continue }
                await MainActor.run {
                    guard self?.activeSession?.id == session.id else { return }
                    self?.clearActiveSession()
                }
                return
            }
        }
    }

    private func clearActiveSession() {
        activeSessionStateTask?.cancel()
        activeSessionStateTask = nil
        activeSession = nil
        activeCoordinatorIdentifier = nil
        pendingLocalShare = nil
        playbackCoordinatorDelegate = nil
        state = .inactive
    }
}

private final class WatchTogetherPlaybackCoordinatorDelegate: NSObject, AVPlayerPlaybackCoordinatorDelegate {
    private let playerItemIdentity: ObjectIdentifier
    private let coordinatorIdentifier: String
    private let unmatchedItemIdentifier = "visionplay:coordinator:v1:unmatched:\(UUID().uuidString)"

    init(playerItem: AVPlayerItem, coordinatorIdentifier: String) {
        self.playerItemIdentity = ObjectIdentifier(playerItem)
        self.coordinatorIdentifier = coordinatorIdentifier
    }

    func playbackCoordinator(_ coordinator: AVPlayerPlaybackCoordinator,
                             identifierFor playerItem: AVPlayerItem) -> String {
        guard ObjectIdentifier(playerItem) == playerItemIdentity else {
            return unmatchedItemIdentifier
        }
        return coordinatorIdentifier
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
