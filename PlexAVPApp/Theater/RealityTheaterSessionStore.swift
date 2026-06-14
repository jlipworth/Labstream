import AVFoundation

/// Session boundary for the future RealityKit theater (#12).
///
/// This intentionally does not replace `CustomCinemaSessionStore` yet. The old store powers the
/// hidden Wave-2/Wave-3 scaffold; this store gives #12 a clean place to hang playback, screen, and
/// seating state once a developer-only entry point is added for device iteration.
@Observable
@MainActor
final class RealityTheaterSessionStore {
    enum Phase: Equatable {
        case inactive
        case prepared
        case opening
        case open
    }

    private(set) var title: String?
    private(set) var controller: PlaybackController?
    var configuration: RealityTheaterConfiguration
    var phase: Phase = .inactive

    init(configuration: RealityTheaterConfiguration = .default) {
        self.configuration = configuration
    }

    var player: AVPlayer? { controller?.player }
    var hasPreparedPlayback: Bool { controller != nil }

    func prepare(title: String,
                 controller: PlaybackController,
                 configuration: RealityTheaterConfiguration = .default) {
        self.title = title
        self.controller = controller
        self.configuration = configuration
        phase = .prepared
    }

    func updateConfiguration(_ update: (inout RealityTheaterConfiguration) -> Void) {
        var next = configuration
        update(&next)
        configuration = next
    }

    func markOpening() {
        phase = .opening
    }

    func markOpen() {
        phase = .open
    }

    func markClosed() {
        phase = hasPreparedPlayback ? .prepared : .inactive
    }

    func clear() {
        title = nil
        controller = nil
        configuration = .default
        phase = .inactive
    }
}
