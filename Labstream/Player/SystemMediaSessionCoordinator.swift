import Foundation
import MediaPlayer

/// Serializes ownership of the process-wide Now Playing and remote-command surfaces.
///
/// A lease remains registered while another owner temporarily takes the foreground. Releasing
/// the foreground lease restores the most-recent surviving owner atomically; releasing a
/// background lease (for example music stopping while video is open) cannot disturb the current
/// owner. All mutations are identity-guarded, so delayed artwork and teardown from an old player
/// are harmless.
@MainActor
final class SystemMediaSessionCoordinator {
    enum Owner: Equatable {
        case music
        case video
    }

    enum Command: CaseIterable, Hashable {
        case play, pause, togglePlayPause, nextTrack, previousTrack, changePlaybackPosition
        case skipForward, skipBackward
    }

    struct CommandEvent {
        let positionTime: Double?
        let skipInterval: Double?

        init(positionTime: Double? = nil, skipInterval: Double? = nil) {
            self.positionTime = positionTime
            self.skipInterval = skipInterval
        }
    }

    enum CommandStatus {
        case success
        case noActionableItem
        case failed
    }

    struct CommandConfiguration {
        typealias Handler = @MainActor (CommandEvent) -> CommandStatus

        var handlers: [Command: Handler]
        var skipForwardIntervals: [NSNumber]
        var skipBackwardIntervals: [NSNumber]
        var didBecomeCurrent: (@MainActor (Lease) -> Void)?

        init(handlers: [Command: Handler],
             skipForwardIntervals: [NSNumber] = [],
             skipBackwardIntervals: [NSNumber] = [],
             didBecomeCurrent: (@MainActor (Lease) -> Void)? = nil) {
            self.handlers = handlers
            self.skipForwardIntervals = skipForwardIntervals
            self.skipBackwardIntervals = skipBackwardIntervals
            self.didBecomeCurrent = didBecomeCurrent
        }
    }

    @MainActor
    final class Lease {
        fileprivate let id = UUID()
        fileprivate let owner: Owner
        fileprivate weak var coordinator: SystemMediaSessionCoordinator?

        fileprivate init(owner: Owner, coordinator: SystemMediaSessionCoordinator) {
            self.owner = owner
            self.coordinator = coordinator
        }

        var isCurrent: Bool { coordinator?.isCurrent(self) == true }

        func publish(nowPlayingInfo: [String: Any], playbackState: MPNowPlayingPlaybackState) {
            coordinator?.publish(nowPlayingInfo: nowPlayingInfo, playbackState: playbackState,
                                 for: self)
        }

        func clearNowPlaying() { coordinator?.clearNowPlaying(for: self) }

        func release() { coordinator?.release(self) }
    }

    private struct Registration {
        let lease: Lease
        let configuration: CommandConfiguration
        var targets: [Command: Any] = [:]
        var previousState: SystemMediaCommandState?
    }

    private let backend: any SystemMediaSessionBackend
    private var registrations: [Registration] = []

    convenience init() {
        self.init(backend: MediaPlayerSystemMediaSessionBackend())
    }

    init(backend: any SystemMediaSessionBackend) {
        self.backend = backend
    }

    /// Claims the global surfaces. If registration fails, the attempted lease is discarded and
    /// the previous owner is restored. `nil` therefore means remote commands failed closed.
    func acquire(owner: Owner, commands: CommandConfiguration) -> Lease? {
        let previousIndex = registrations.indices.last
        if let previousIndex { deactivate(at: previousIndex) }

        let lease = Lease(owner: owner, coordinator: self)
        registrations.append(Registration(lease: lease, configuration: commands))
        do {
            try activate(at: registrations.index(before: registrations.endIndex))
            return lease
        } catch {
            deactivate(at: registrations.index(before: registrations.endIndex))
            registrations.removeLast()
            if let previousIndex {
                do { try activate(at: previousIndex) }
                catch {
                    // Failure recovery must fail closed: no partially-installed targets survive.
                    deactivate(at: previousIndex)
                }
            }
            return nil
        }
    }

    func isCurrent(_ lease: Lease) -> Bool {
        registrations.last?.lease === lease
    }

    func release(_ lease: Lease) {
        guard let index = registrations.firstIndex(where: { $0.lease === lease }) else { return }
        let wasCurrent = index == registrations.index(before: registrations.endIndex)
        if wasCurrent { deactivate(at: index) }
        registrations.remove(at: index)
        lease.coordinator = nil

        guard wasCurrent, !registrations.isEmpty else { return }
        let restoredIndex = registrations.index(before: registrations.endIndex)
        do { try activate(at: restoredIndex) }
        catch { deactivate(at: restoredIndex) }
    }

    func publish(nowPlayingInfo: [String: Any], playbackState: MPNowPlayingPlaybackState,
                 for lease: Lease) {
        guard isCurrent(lease) else { return }
        var info = nowPlayingInfo
        info[Self.ownerInfoKey] = lease.id.uuidString
        backend.nowPlayingInfo = info
        backend.playbackState = playbackState
    }

    func clearNowPlaying(for lease: Lease) {
        guard isCurrent(lease),
              backend.nowPlayingInfo?[Self.ownerInfoKey] as? String == lease.id.uuidString else {
            return
        }
        backend.nowPlayingInfo = nil
        backend.playbackState = .stopped
    }

    private func activate(at index: Int) throws {
        guard registrations.indices.contains(index), registrations[index].targets.isEmpty else { return }
        let configuration = registrations[index].configuration
        registrations[index].previousState = backend.captureCommandState()
        do {
            backend.apply(configuration: configuration)
            for command in configuration.handlers.keys {
                let handler = configuration.handlers[command]!
                let lease = registrations[index].lease
                let guardedHandler: CommandConfiguration.Handler = { [weak self, weak lease] event in
                    guard let self, let lease, self.isCurrent(lease) else {
                        return .noActionableItem
                    }
                    return handler(event)
                }
                let target = try backend.addTarget(for: command, handler: guardedHandler)
                registrations[index].targets[command] = target
            }
            configuration.didBecomeCurrent?(registrations[index].lease)
        } catch {
            deactivate(at: index)
            throw error
        }
    }

    private func deactivate(at index: Int) {
        guard registrations.indices.contains(index) else { return }
        for (command, target) in registrations[index].targets {
            backend.removeTarget(target, for: command)
        }
        registrations[index].targets.removeAll()
        if let previousState = registrations[index].previousState {
            backend.restoreCommandState(previousState)
            registrations[index].previousState = nil
        }
    }

    private static let ownerInfoKey = "LabstreamNowPlayingOwner"
}

@MainActor
struct SystemMediaCommandState {
    var enabled: [SystemMediaSessionCoordinator.Command: Bool]
    var skipForwardIntervals: [NSNumber]
    var skipBackwardIntervals: [NSNumber]
}

@MainActor
protocol SystemMediaSessionBackend: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
    func captureCommandState() -> SystemMediaCommandState
    func apply(configuration: SystemMediaSessionCoordinator.CommandConfiguration)
    func restoreCommandState(_ state: SystemMediaCommandState)
    func addTarget(for command: SystemMediaSessionCoordinator.Command,
                   handler: @escaping SystemMediaSessionCoordinator.CommandConfiguration.Handler) throws -> Any
    func removeTarget(_ target: Any, for command: SystemMediaSessionCoordinator.Command)
}

@MainActor
private final class MediaPlayerSystemMediaSessionBackend: SystemMediaSessionBackend {
    var nowPlayingInfo: [String: Any]? {
        get { MPNowPlayingInfoCenter.default().nowPlayingInfo }
        set { MPNowPlayingInfoCenter.default().nowPlayingInfo = newValue }
    }

    var playbackState: MPNowPlayingPlaybackState {
        get { MPNowPlayingInfoCenter.default().playbackState }
        set { MPNowPlayingInfoCenter.default().playbackState = newValue }
    }

    func captureCommandState() -> SystemMediaCommandState {
        var enabled: [SystemMediaSessionCoordinator.Command: Bool] = [:]
        for command in SystemMediaSessionCoordinator.Command.allCases {
            enabled[command] = remoteCommand(for: command).isEnabled
        }
        let center = MPRemoteCommandCenter.shared()
        return SystemMediaCommandState(enabled: enabled,
                                       skipForwardIntervals: center.skipForwardCommand.preferredIntervals,
                                       skipBackwardIntervals: center.skipBackwardCommand.preferredIntervals)
    }

    func apply(configuration: SystemMediaSessionCoordinator.CommandConfiguration) {
        for command in SystemMediaSessionCoordinator.Command.allCases {
            remoteCommand(for: command).isEnabled = configuration.handlers[command] != nil
        }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = configuration.skipForwardIntervals
        center.skipBackwardCommand.preferredIntervals = configuration.skipBackwardIntervals
    }

    func restoreCommandState(_ state: SystemMediaCommandState) {
        for command in SystemMediaSessionCoordinator.Command.allCases {
            remoteCommand(for: command).isEnabled = state.enabled[command] ?? false
        }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = state.skipForwardIntervals
        center.skipBackwardCommand.preferredIntervals = state.skipBackwardIntervals
    }

    func addTarget(for command: SystemMediaSessionCoordinator.Command,
                   handler: @escaping SystemMediaSessionCoordinator.CommandConfiguration.Handler) throws -> Any {
        remoteCommand(for: command).addTarget { event in
            let commandEvent = SystemMediaSessionCoordinator.CommandEvent(
                positionTime: (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
                skipInterval: (event as? MPSkipIntervalCommandEvent)?.interval
            )
            if Thread.isMainThread {
                return MainActor.assumeIsolated { Self.map(handler(commandEvent)) }
            }
            Task { @MainActor in _ = handler(commandEvent) }
            return .success
        }
    }

    func removeTarget(_ target: Any, for command: SystemMediaSessionCoordinator.Command) {
        remoteCommand(for: command).removeTarget(target)
    }

    private func remoteCommand(for command: SystemMediaSessionCoordinator.Command) -> MPRemoteCommand {
        let center = MPRemoteCommandCenter.shared()
        switch command {
        case .play: return center.playCommand
        case .pause: return center.pauseCommand
        case .togglePlayPause: return center.togglePlayPauseCommand
        case .nextTrack: return center.nextTrackCommand
        case .previousTrack: return center.previousTrackCommand
        case .changePlaybackPosition: return center.changePlaybackPositionCommand
        case .skipForward: return center.skipForwardCommand
        case .skipBackward: return center.skipBackwardCommand
        }
    }

    private static func map(_ status: SystemMediaSessionCoordinator.CommandStatus) -> MPRemoteCommandHandlerStatus {
        switch status {
        case .success: .success
        case .noActionableItem: .noActionableNowPlayingItem
        case .failed: .commandFailed
        }
    }
}
