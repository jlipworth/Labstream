import Foundation
import AVFoundation
import AVFAudio
import UIKit

/// Owns the shared `AVAudioSession` and the interruption / route-change /
/// app-lifecycle handling for one playback session (#17, P5).
///
/// Extracted from `PlaybackController`: activation + observer registration happen
/// once per controller lifetime (both are idempotent, so a Quality reload — which
/// re-enters the controller's `load` — never double-registers), and teardown
/// releases the session, notifying other audio apps so they can resume.
///
/// Shared by video (`PlaybackController`, the defaults: `.moviePlayback` mode,
/// pause on background) and music (`MusicPlayerController`: `.default` mode,
/// `pausesOnBackground: false` so audio keeps playing when the app loses the
/// foreground / the headset chrome changes). The interruption and route-change
/// handling is identical for both.
@MainActor
final class AudioSessionCoordinator {

    private let player: AVPlayer

    /// `AVAudioSession` mode applied in `activate()`. `.moviePlayback` for video
    /// (the default, matching the original extraction), `.default` for music.
    private let mode: AVAudioSession.Mode

    /// Whether losing the foreground should pause playback. True for video (it can't
    /// decode/render in the background); false for music, which should keep playing.
    private let pausesOnBackground: Bool

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?

    /// True when an audio interruption paused playback while the user had it playing.
    /// Gates auto-resume after `.ended/.shouldResume`: background pauses deliberately
    /// never set this flag, so returning foreground or a coincident interruption-ended
    /// event cannot restart video behind the user's back.
    private var wasPlayingBeforeInterruption = false

    init(player: AVPlayer,
         mode: AVAudioSession.Mode = .moviePlayback,
         pausesOnBackground: Bool = true) {
        self.player = player
        self.mode = mode
        self.pausesOnBackground = pausesOnBackground
    }

    /// Configure and activate the shared `AVAudioSession` for playback.
    ///
    /// Category `.playback` with the stored `mode` — `.moviePlayback` for video (routes
    /// audio to the cinema/system output, plays through the silent switch, and is what
    /// AVKit expects for the docked/expanded screen), `.default` for music. Activate once
    /// before the first item loads; subsequent (re)loads (e.g. a Quality reload) reuse
    /// the already-active session.
    ///
    /// Conservative by design: audio already worked without explicit config, so `.playback`
    /// must not regress that — it's the documented category for exactly this use and does not
    /// mute. Failures are logged (never fatal) so a session-config hiccup can't black-hole
    /// playback.
    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: mode)
            try session.setActive(true)
        } catch {
            NSLog("AudioSessionCoordinator: AVAudioSession configuration failed (%@)",
                  String(describing: error))
        }
    }

    /// Deactivate the shared audio session on teardown, notifying other audio apps so they
    /// can resume. Best-effort: a failure here is logged, never fatal. Notifying on
    /// deactivation is the recommended behavior so we don't leave the session pinned for a
    /// subsequent player or another app.
    func deactivate() {
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            NSLog("AudioSessionCoordinator: AVAudioSession deactivation failed (%@)",
                  String(describing: error))
        }
    }

    /// Register the audio-session (interruption / route-change) observers — and, when
    /// `pausesOnBackground` is set, the app-lifecycle (background) observers — exactly once
    /// for this coordinator's lifetime. Idempotent: a second call is a no-op, so we never
    /// double-register. All closures hop to the `@MainActor` before touching player state,
    /// satisfying Swift 6 strict concurrency.
    func installObservers() {
        guard interruptionObserver == nil else { return }
        let center = NotificationCenter.default

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            // Extract the Sendable scalars (raw UInts) from the non-Sendable userInfo BEFORE
            // hopping actors, so nothing risks a data race crossing into the @MainActor task.
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }

        // Background-aware playback (P5): on visionOS the immersive player loses the active
        // scene when the user leaves; video can't decode/render in the background and a live
        // transcode session would keep churning. Pause on resign-active / background. We do
        // NOT auto-resume on return — that's the user's choice. Music sessions opt out
        // (`pausesOnBackground: false`): audio-only playback keeps going in the background.
        if pausesOnBackground {
            resignActiveObserver = center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.pauseForBackground()
                }
            }

            didEnterBackgroundObserver = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.pauseForBackground()
                }
            }
        }
    }

    /// Tear down the session/lifecycle observers. Called from the controller's `stop()`
    /// (and is safe to call more than once).
    func removeObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver {
            center.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            center.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        if let resignActiveObserver {
            center.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let didEnterBackgroundObserver {
            center.removeObserver(didEnterBackgroundObserver)
            self.didEnterBackgroundObserver = nil
        }
    }

    /// Handle an `AVAudioSession.interruptionNotification`.
    ///
    /// `.began`: remember whether we were actively playing (so we don't later resume a
    /// user-paused stream) and pause. `.ended`: if the system says `.shouldResume` AND we
    /// were the ones who paused (the user hadn't manually paused before the interruption),
    /// resume — otherwise leave it paused and respect the user's intent.
    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            // Only flag for resume if playback was actually running; a paused player should
            // stay paused.
            wasPlayingBeforeInterruption = player.timeControlStatus != .paused
            if wasPlayingBeforeInterruption {
                player.pause()
            }
        case .ended:
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            let options: AVAudioSession.InterruptionOptions =
                optionsRaw.map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume) {
                // Re-activate the session (the interruption may have deactivated it) and
                // resume only because WE paused while the user had it playing.
                activate()
                player.play()
            }
        @unknown default:
            break
        }
    }

    /// Handle an `AVAudioSession.routeChangeNotification`. On `.oldDeviceUnavailable`
    /// (headphones / AirPods unplugged or disconnected) pause, so audio doesn't suddenly
    /// blast out of the speakers — the standard system behavior. Other reasons are ignored.
    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable {
            player.pause()
        }
    }

    /// Pause video when the app is backgrounded / loses the foreground (P5). Video can't
    /// decode/render in the background and a live transcode would keep running, so we always
    /// pause. We deliberately do NOT auto-resume on foreground: resume is the user's choice
    /// on return. Do not set the interruption-resume flag here, or a later
    /// interruption-ended notification with `.shouldResume` can restart playback.
    private func pauseForBackground() {
        if player.timeControlStatus != .paused {
            player.pause()
        }
    }
}
