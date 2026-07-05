import AVFoundation

/// Session boundary for the future RealityKit theater (#12).
///
/// This intentionally does not replace `CustomCinemaSessionStore`, which powers the shipping
/// custom-player Cinema mode. This store gives #12 a clean place to hang playback, screen, and
/// seating state for the separately gated RealityKit theater prototype.
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
        logCurrentConfiguration(reason: "tuned")
    }

    func applyPreset(_ preset: RealityTheaterBaselinePreset) {
        configuration = preset.configuration
        logCurrentConfiguration(reason: "preset \(preset.displayName)")
    }

    func resetConfigurationToDefaults() {
        configuration = .default
        logCurrentConfiguration(reason: "reset defaults")
    }

    func markOpening() {
        phase = .opening
        logCurrentConfiguration(reason: "opening")
    }

    func markOpen() {
        phase = .open
        logCurrentConfiguration(reason: "opened")
    }

    func markClosed() {
        phase = hasPreparedPlayback ? .prepared : .inactive
        logCurrentConfiguration(reason: "closed")
    }

    func dismissWithoutClearingPlayback() {
        phase = .opening
    }

    func clear() {
        title = nil
        controller = nil
        configuration = .default
        phase = .inactive
    }

    func logCurrentConfiguration(reason: String) {
        // Intentionally quiet: theater/cinema diagnostics must not print media titles or other
        // user-library details. Add privacy-reviewed structured diagnostics if this needs tracing.
    }
}
