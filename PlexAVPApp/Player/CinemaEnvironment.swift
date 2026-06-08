import AVKit

/// Configures the visionOS system "Cinema Environment" / docking behavior on an
/// `AVPlayerViewController`.
///
/// Per research/02: for flat 2D HLS the stock player IS the cinema experience.
/// When the player view controller is the exclusive content of its window scene
/// and is in the **Expanded** experience, the system presents the giant virtual
/// screen and automatically **docks** it into whichever immersive environment the
/// user opens (Apple's Mount Hood / Cinema / IMAX spaces, etc.). We do not author a
/// custom environment here; we simply make sure the controller is configured to
/// allow the expanded/docked experiences so the system docking kicks in.
///
/// `AVExperienceController` / `allowedExperiences` are visionOS-2+/26 APIs, so the
/// configuration is guarded behind availability checks; on older runtimes the
/// fullscreen player still docks via the default behavior.
enum CinemaEnvironment {

    /// Apply the recommended cinema configuration to a player view controller.
    @MainActor
    static func configure(_ controller: AVPlayerViewController) {
        // Recommended on visionOS: let the system manage the inline -> expanded ->
        // docked transitions. Keeping default controls visible gives the floating,
        // detached transport bar in the docked cinema state.
        #if os(visionOS)
        if #available(visionOS 2.0, *) {
            // Allow the full recommended experience set, which includes Expanded
            // (the full-screen cinema state that participates in system docking).
            // We do NOT exclude .expanded — that's the one we want for theater mode.
            controller.experienceController.allowedExperiences = .recommended()
        }
        #endif
    }
}
