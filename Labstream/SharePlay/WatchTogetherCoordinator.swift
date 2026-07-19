import AVFoundation
import Foundation
import GroupActivities
import Observation
import PMSKit

@MainActor
@Observable
final class WatchTogetherCoordinator {
    struct PresentationContext: Equatable, Sendable {
        let title: String
        let coordinatorIdentifier: String?
        static func available(title: String, coordinatorIdentifier: String) -> Self { .init(title: title, coordinatorIdentifier: coordinatorIdentifier) }
        static func unavailable(title: String) -> Self { .init(title: title, coordinatorIdentifier: nil) }
    }

    enum State: Equatable, Sendable {
        case inactive
        case resolving(PresentationContext)
        case selectionRequired(PresentationContext)
        case ready(PresentationContext)
        case active(PresentationContext)
        case unavailable(PresentationContext, reason: UnavailableReason)
        var context: PresentationContext? {
            switch self {
            case .inactive: nil
            case .resolving(let value), .selectionRequired(let value), .ready(let value),
                 .active(let value), .unavailable(let value, _): value
            }
        }
    }

    enum UnavailableReason: String, Equatable, Sendable {
        case unsupportedItem, activationDisabled, activationCancelled, activationFailed
        case currentLibraryResolutionUnavailable, coordinatorIdentifierUnavailable, noActiveSession
    }

    struct JoinPrompt: Identifiable, Equatable {
        let id: UUID
        let title: String
        let subtitle: String?
        let identity: SharePlayMediaIdentity
        var candidates: [MediaItem]
        var isSearching: Bool
        var isReady: Bool
        var searchQuery: String
    }

    private struct PendingLocalShare: Sendable, Equatable {
        let activityID: UUID
        let item: MediaItem
    }

    private struct ReadinessMessage: Codable {
        let activityID: UUID
        let status: SharePlayParticipantReadiness
    }

    private(set) var state: State = .inactive
    private(set) var joinPrompt: JoinPrompt?
    private(set) var readyParticipantCount = 0
    private(set) var resolvingParticipantCount = 0
    private(set) var sessionStarted = false
    private(set) var isLocalInitiator = false
    var hasActiveSession: Bool { activeSession != nil }
    /// A SharePlay activation is single-flight. Repeated taps while the system activation sheet is
    /// resolving (or while an existing activity is ready/active) would otherwise replace the live
    /// GroupSession and briefly tear playback coordination down before the replacement arrives.
    var canRequestWatchTogether: Bool {
        switch state {
        case .inactive, .unavailable:
            true
        case .resolving, .selectionRequired, .ready, .active:
            false
        }
    }
    /// Advances whenever a newly delivered GroupSession becomes the active coordination target.
    /// A replacement session can be installed synchronously without the attachment-maintenance
    /// loop observing an intermediate inactive state, so player-item identity alone is insufficient
    /// to decide whether `coordinateWithSession` must run again.
    private(set) var playbackSessionGeneration: UInt64 = 0
    var requiresStartAcknowledgement: Bool { resolvingParticipantCount > 0 }

    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var activeSessionStateTask: Task<Void, Never>?
    @ObservationIgnored private var participantTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: GroupSession<WatchTogetherActivity>?
    @ObservationIgnored private var messenger: GroupSessionMessenger?
    @ObservationIgnored private var activePayload: SharePlayMediaActivityPayload?
    @ObservationIgnored private var resolvedItem: MediaItem?
    @ObservationIgnored private var pendingLocalShare: PendingLocalShare?
    @ObservationIgnored private var participantStatuses: [UUID: SharePlayParticipantReadiness] = [:]
    @ObservationIgnored private var knownParticipantIDs: Set<UUID> = []
    /// True once this participant has actually launched the resolved item (initiator started, or a
    /// participant received `.started` while resolved). Serves as the launch idempotency guard AND
    /// the consent boundary for coordinating a local player with the group session.
    @ObservationIgnored private var didLaunchResolvedItem = false
    @ObservationIgnored private var playbackCoordinatorDelegate: WatchTogetherPlaybackCoordinatorDelegate?
    @ObservationIgnored private var candidateLookup: (@MainActor (String) async -> [MediaItem])?

    func configure(appModel: AppModel) {
        let lookup = WatchTogetherMediaLookup(appModel: appModel)
        candidateLookup = { query in await lookup.candidates(matching: query) }
    }

    func startObservingSessionsIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            for await session in WatchTogetherActivity.sessions() { self?.handle(session) }
        }
    }

    func requestWatchTogether(for item: MediaItem) async {
        guard canRequestWatchTogether else { return }
        guard let payload = SharePlayMediaActivityPayload(mediaItem: item),
              payload.identity.coordinatorIdentifier != nil else {
            state = .unavailable(.unavailable(title: item.title), reason: .unsupportedItem)
            return
        }
        let context = context(for: payload)
        let previousState = state
        state = .resolving(context)
        let activity = WatchTogetherActivity(payload: payload)
        do {
            switch await activity.prepareForActivation() {
            case .activationPreferred:
                pendingLocalShare = PendingLocalShare(activityID: payload.activityID, item: item)
                if try await activity.activate() == false {
                    failActivation(context, reason: .activationCancelled, restoring: previousState)
                }
            case .activationDisabled: failActivation(context, reason: .activationDisabled, restoring: previousState)
            case .cancelled: failActivation(context, reason: .activationCancelled, restoring: previousState)
            @unknown default: failActivation(context, reason: .activationFailed, restoring: previousState)
            }
        } catch { failActivation(context, reason: .activationFailed, restoring: previousState) }
    }

    private func failActivation(_ context: PresentationContext, reason: UnavailableReason, restoring previousState: State) {
        pendingLocalShare = nil
        state = activeSession != nil ? previousState : .unavailable(context, reason: reason)
    }

    private func handle(_ session: GroupSession<WatchTogetherActivity>) {
        // A newly delivered activity replaces any previous one. Explicitly leave the old session
        // before adopting the new payload so it cannot retain this device as a ghost participant.
        clearActiveSession(leaving: activeSession != nil)
        let payload = session.activity.payload
        activeSession = session
        playbackSessionGeneration &+= 1
        isLocalInitiator = session.isLocallyInitiated
        activePayload = payload
        messenger = GroupSessionMessenger(session: session)
        session.join()
        observe(session)

        if let pending = pendingLocalShare, pending.activityID == payload.activityID {
            pendingLocalShare = nil
            acceptResolvedItem(pending.item)
        } else {
            joinPrompt = JoinPrompt(id: payload.activityID, title: payload.displayTitle,
                                    subtitle: payload.displaySubtitle, identity: payload.identity,
                                    candidates: [], isSearching: true, isReady: false,
                                    searchQuery: payload.displayTitle)
            state = .resolving(context(for: payload))
            sendStatus(.resolving)
            searchCandidates(query: payload.displayTitle)
        }
    }

    func searchCandidates(query: String) {
        guard var prompt = joinPrompt, prompt.id == activePayload?.activityID else { return }
        prompt.searchQuery = query
        prompt.isSearching = true
        joinPrompt = prompt
        lookupTask?.cancel()
        lookupTask = Task { [weak self] in
            guard let self, let candidateLookup else { return }
            let candidates = await candidateLookup(query)
            guard !Task.isCancelled else { return }
            self.applyCandidates(candidates)
        }
    }

    private func applyCandidates(_ candidates: [MediaItem]) {
        guard let payload = activePayload, var prompt = joinPrompt else { return }
        let resolver = SharePlayMediaResolver()
        switch resolver.resolve(payload.identity, in: candidates) {
        case .resolved(let item):
            acceptResolvedItem(item)
        case .selectionRequired(let matches):
            prompt.candidates = matches
            prompt.isSearching = false
            joinPrompt = prompt
            state = .selectionRequired(context(for: payload))
        case .failed:
            prompt.candidates = resolver.selectableCandidates(for: payload.identity, in: candidates)
            prompt.isSearching = false
            joinPrompt = prompt
            state = .selectionRequired(context(for: payload))
        }
    }

    func selectCandidate(_ item: MediaItem) {
        guard let payload = activePayload,
              SharePlayMediaResolver().selectableCandidates(for: payload.identity, in: [item]).count == 1 else {
            if let payload = activePayload {
                state = .unavailable(context(for: payload), reason: .coordinatorIdentifierUnavailable)
            }
            return
        }
        acceptResolvedItem(item)
    }

    private func acceptResolvedItem(_ item: MediaItem) {
        guard let payload = activePayload else { return }
        resolvedItem = item
        if var prompt = joinPrompt { prompt.isReady = true; prompt.isSearching = false; joinPrompt = prompt }
        state = .ready(context(for: payload))
        setLocalStatus(.ready)
        sendStatus(.ready)
        // Late joiner: the session may already have started before we resolved. The initiator's
        // one-shot `.started` is not replayed by GroupSessionMessenger, but `sessionStarted` is
        // already true here if we received a fresh re-broadcast (see handleActiveParticipants).
        if SharePlayReadinessSummary.shouldLaunchLocally(sessionStarted: sessionStarted, localResolved: true) {
            launchResolvedItem()
        }
    }

    func startWithReadyParticipants(acknowledgeUnresolved: Bool) {
        guard resolvedItem != nil, let payload = activePayload else { return }
        guard acknowledgeUnresolved || !requiresStartAcknowledgement else { return }
        sessionStarted = true
        state = .active(context(for: payload))
        sendStatus(.started)
        launchResolvedItem()
    }

    private func launchResolvedItem() {
        guard let item = resolvedItem, !didLaunchResolvedItem else { return }
        didLaunchResolvedItem = true
        joinPrompt = nil
        SystemEntryRouter.shared.open(item: item, autoPlay: true)
    }

    func declineIncoming() {
        sendStatus(.unable)
        clearActiveSession(leaving: true)
    }

    @discardableResult
    func attachPlaybackCoordinatorIfReady(player: AVPlayer, item: MediaItem) -> Bool {
        // Consent boundary. `session.join()` runs early (in `handle`) so we can receive messages and
        // present the join prompt, but binding a local AVPlayer to the group session is the real
        // opt-in and must not happen until THIS coordinator has launched the resolved item (initiator
        // started, or a participant received .started). Gating on `selectableCandidates` — kind plus
        // 5s-bucketed duration — would group-coordinate a user's private, unrelated playback that
        // merely shares a duration bucket, so we require the player to be showing the exact resolved
        // item instead of the coarse pool.
        guard didLaunchResolvedItem,
              let session = activeSession, let payload = activePayload,
              let resolved = resolvedItem, resolved.ratingKey == item.ratingKey,
              let identifier = payload.identity.coordinatorIdentifier,
              let currentItem = player.currentItem else { return false }
        let delegate = WatchTogetherPlaybackCoordinatorDelegate(playerItem: currentItem, coordinatorIdentifier: identifier)
        playbackCoordinatorDelegate = delegate
        player.playbackCoordinator.delegate = delegate
        player.playbackCoordinator.coordinateWithSession(session)
        return true
    }

    func stateApplies(to item: MediaItem) -> Bool {
        guard let context = state.context else { return false }
        // Once this participant has resolved the activity, only its exact backend-local item may
        // display/consume active session state. `selectableCandidates` is deliberately coarse
        // (kind plus timeline bucket) for an explicit user-confirmation list; using it here made an
        // unrelated same-length item look SharePlay-active and risked attaching after navigation.
        if let resolvedItem {
            return resolvedItem.ratingKey == item.ratingKey
        }
        if let active = activePayload?.identity {
            if case .resolved = SharePlayMediaResolver().resolve(active, in: [item]) {
                return true
            }
            return false
        }
        return context.title == item.title
    }

    func leave() {
        // Explicit cancellation also revokes an activation that has prepared but whose session
        // has not been delivered yet. Internal session replacement intentionally preserves this
        // value long enough to match the newly activated activity in `handle`.
        pendingLocalShare = nil
        clearActiveSession(leaving: true)
    }

    /// End coordination when the exact locally resolved item leaves the player. This is kept
    /// separate from generic view dismissal because the window disappears during the Cinema
    /// handoff while the same controller and SharePlay session intentionally continue there.
    func leaveIfPlaying(_ item: MediaItem) {
        guard resolvedItem?.ratingKey == item.ratingKey else { return }
        leave()
    }

    private func context(for payload: SharePlayMediaActivityPayload) -> PresentationContext {
        if let identifier = payload.identity.coordinatorIdentifier {
            return .available(title: payload.displayTitle, coordinatorIdentifier: identifier)
        }
        return .unavailable(title: payload.displayTitle)
    }

    private func observe(_ session: GroupSession<WatchTogetherActivity>) {
        activeSessionStateTask = Task { [weak self, weak session] in
            guard let session else { return }
            for await value in session.$state.values {
                if case .invalidated = value { self?.clearActiveSession(leaving: false); return }
            }
        }
        participantTask = Task { [weak self, weak session] in
            guard let session else { return }
            for await participants in session.$activeParticipants.values {
                self?.handleActiveParticipants(participants.map(\.id), localID: session.localParticipant.id)
            }
        }
        if let messenger {
            messageTask = Task { [weak self] in
                for await (message, context) in messenger.messages(of: ReadinessMessage.self) {
                    self?.receive(message, from: context.source.id)
                }
            }
        }
    }

    private func receive(_ message: ReadinessMessage, from participantID: UUID) {
        guard message.activityID == activePayload?.activityID else { return }
        participantStatuses[participantID] = message.status
        if message.status == .started {
            sessionStarted = true
            if let payload = activePayload { state = resolvedItem == nil ? .resolving(context(for: payload)) : .active(context(for: payload)) }
            if SharePlayReadinessSummary.shouldLaunchLocally(sessionStarted: true, localResolved: resolvedItem != nil) {
                launchResolvedItem()
            }
        }
        refreshCounts()
    }

    /// Prune departed participants and, as the initiator, re-announce `.started` to any newcomer.
    /// GroupSessionMessenger never replays past messages, so a participant who joins the FaceTime
    /// call after playback started would otherwise wait forever on "Waiting for the initiator…".
    /// Restricting the re-broadcast to the initiator keeps it a single message per newcomer.
    private func handleActiveParticipants(_ activeIDs: [UUID], localID: UUID) {
        let newcomers = Set(activeIDs).subtracting(knownParticipantIDs).subtracting([localID])
        knownParticipantIDs = Set(activeIDs)
        pruneStatuses(to: activeIDs, localID: localID)
        if isLocalInitiator, sessionStarted, !newcomers.isEmpty {
            sendStatus(.started)
        }
    }

    private func sendStatus(_ status: SharePlayParticipantReadiness) {
        guard let payload = activePayload, let messenger else { return }
        setLocalStatus(status)
        let message = ReadinessMessage(activityID: payload.activityID, status: status)
        Task { try? await messenger.send(message) }
    }

    private func setLocalStatus(_ status: SharePlayParticipantReadiness) {
        guard let id = activeSession?.localParticipant.id else { return }
        participantStatuses[id] = status
        refreshCounts()
    }

    private func pruneStatuses(to activeIDs: [UUID], localID: UUID) {
        participantStatuses = SharePlayReadinessRoster.reconcile(
            statuses: participantStatuses,
            activeParticipantIDs: Set(activeIDs),
            localParticipantID: localID)
        refreshCounts()
    }

    private func refreshCounts() {
        let summary = SharePlayReadinessSummary(statuses: Array(participantStatuses.values))
        readyParticipantCount = summary.readyCount
        resolvingParticipantCount = summary.resolvingCount
    }

    private func clearActiveSession(leaving: Bool) {
        if leaving { activeSession?.leave() }
        activeSessionStateTask?.cancel(); participantTask?.cancel(); messageTask?.cancel(); lookupTask?.cancel()
        activeSessionStateTask = nil; participantTask = nil; messageTask = nil; lookupTask = nil
        activeSession = nil; messenger = nil; activePayload = nil; resolvedItem = nil; joinPrompt = nil
        participantStatuses = [:]; knownParticipantIDs = []; readyParticipantCount = 0; resolvingParticipantCount = 0
        sessionStarted = false; isLocalInitiator = false; didLaunchResolvedItem = false
        playbackCoordinatorDelegate = nil
        state = .inactive
    }
}

private final class WatchTogetherPlaybackCoordinatorDelegate: NSObject, AVPlayerPlaybackCoordinatorDelegate {
    private let playerItemIdentity: ObjectIdentifier
    private let coordinatorIdentifier: String
    private let unmatchedItemIdentifier = "visionplay:coordinator:v1:unmatched:\(UUID().uuidString)"
    init(playerItem: AVPlayerItem, coordinatorIdentifier: String) {
        playerItemIdentity = ObjectIdentifier(playerItem); self.coordinatorIdentifier = coordinatorIdentifier
    }
    func playbackCoordinator(_ coordinator: AVPlayerPlaybackCoordinator, identifierFor playerItem: AVPlayerItem) -> String {
        ObjectIdentifier(playerItem) == playerItemIdentity ? coordinatorIdentifier : unmatchedItemIdentifier
    }
}

extension WatchTogetherCoordinator.UnavailableReason {
    var userMessage: String {
        switch self {
        case .unsupportedItem: "Watch Together supports online movies and episodes only."
        case .activationDisabled: "SharePlay isn’t available for this session."
        case .activationCancelled: "Watch Together was cancelled."
        case .activationFailed: "Couldn’t start Watch Together."
        case .currentLibraryResolutionUnavailable: "Choose the matching title from this server."
        case .coordinatorIdentifierUnavailable: "This item can’t be matched safely for Watch Together."
        case .noActiveSession: "No active Watch Together session is ready."
        }
    }
}
