import AppIntents
import PMSKit

// MARK: - App Intents (issue #24)
//
// Three minimal intents: Play (foreground + autoplay), Open (foreground + detail
// page), and Resume Continue Watching (no parameter — the top On Deck item).
// All of them run IN the app process (`openAppWhenRun`) because playback lives in
// the single window's `.fullScreenCover`; navigation goes through `SystemEntryRouter`.

/// User-facing intent failures. Every case reads as a complete sentence — this is
/// the text Siri speaks / Shortcuts shows when the intent can't proceed.
enum LabstreamIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case nothingToResume

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn:
            return "Labstream isn't signed in to a media server. Open the app and sign in first."
        case .nothingToResume:
            return "There's nothing in Continue Watching right now."
        }
    }
}

struct PlayMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Media"
    static let description = IntentDescription(
        "Plays a movie, show, or episode from your media library in Labstream.")
    static let openAppWhenRun = true

    @Parameter(title: "Title", description: "What to play")
    var item: MediaItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let router = SystemEntryRouter.shared
        guard await router.ensureBrowseReady() else { throw LabstreamIntentError.notSignedIn }
        // Route by backend-scoped id, not the snapshot: RootView re-fetches authoritative
        // metadata from the active backend (and resolves a show/season container down to
        // an episode leaf).
        router.open(routeKey: MediaSearchIdentifier.routeKey(from: item.id), autoPlay: true)
        return .result(dialog: "Playing \(item.title) in Labstream.")
    }
}

struct OpenMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Media"
    static let description = IntentDescription(
        "Opens a movie, show, or episode's detail page in Labstream.")
    static let openAppWhenRun = true

    @Parameter(title: "Title", description: "What to open")
    var item: MediaItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let router = SystemEntryRouter.shared
        guard await router.ensureBrowseReady() else { throw LabstreamIntentError.notSignedIn }
        router.open(routeKey: MediaSearchIdentifier.routeKey(from: item.id), autoPlay: false)
        return .result(dialog: "Opening \(item.title) in Labstream.")
    }
}

struct ResumeContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription(
        "Resumes the most recent item in your active backend's Continue Watching list.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let router = SystemEntryRouter.shared
        guard await router.ensureBrowseReady(),
              let ctx = router.browseContext,
              let appModel = router.appModel else { throw LabstreamIntentError.notSignedIn }
        let items: [MediaItem]
        switch ctx.backend {
        case .plex:
            let service = try? PlexBrowseService(
                session: BackendSession(kind: .plex, baseURL: ctx.server, token: ctx.token),
                identity: ctx.identity,
                client: ctx.client
            )
            items = (try? await service?.onDeck()) ?? []
        case .jellyfin:
            let service = JellyfinBrowseService(appModel: appModel)
            let resume = (try? await service.resumeItems(limit: 10)) ?? []
            items = resume.isEmpty ? ((try? await service.nextUp(limit: 10)) ?? []) : resume
        case .emby:
            let service = EmbyBrowseService(appModel: appModel)
            let resume = (try? await service.resumeItems(limit: 10)) ?? []
            items = resume.isEmpty ? ((try? await service.nextUp(limit: 10)) ?? []) : resume
        }
        guard let next = items.first(where: { !$0.isMusic }) else {
            throw LabstreamIntentError.nothingToResume
        }
        // On Deck items are leaves (movies/episodes) carrying a viewOffset, so
        // autoplay lands directly in the player at the resume point.
        router.open(item: next, autoPlay: true)
        return .result(dialog: "Resuming \(next.displaySubtitleLine).")
    }
}

/// Siri/Shortcuts phrases. Parameterized phrases ("Play <X> on Labstream") draw
/// their vocabulary from the query's `suggestedEntities()`; HomeView refreshes them
/// via `updateAppShortcutParameters()` whenever the hubs load.
struct LabstreamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMediaIntent(),
            phrases: [
                "Play \(\.$item) on \(.applicationName)",
                "Watch \(\.$item) on \(.applicationName)",
            ],
            shortTitle: "Play",
            systemImageName: "play.fill")
        AppShortcut(
            intent: OpenMediaIntent(),
            phrases: [
                "Open \(\.$item) in \(.applicationName)",
                "Show \(\.$item) in \(.applicationName)",
            ],
            shortTitle: "Open",
            systemImageName: "info.circle")
        AppShortcut(
            intent: ResumeContinueWatchingIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Continue watching on \(.applicationName)",
                "Resume my show on \(.applicationName)",
            ],
            shortTitle: "Continue Watching",
            systemImageName: "play.circle")
    }
}
