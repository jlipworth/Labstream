import Foundation
import Testing
@testable import PMSKit

@Suite("SharePlay media identity and resolver (#198)")
struct SharePlayMediaIdentityTests {
    private let resolver = SharePlayMediaResolver()

    private func movie(_ ratingKey: String,
                       title: String = "Dune",
                       year: Int? = 2021,
                       duration: Int? = 9_300_000,
                       providerIds: [String: String]? = ["Tmdb": "438631"]) -> MediaItem {
        MediaItem(ratingKey: ratingKey, title: title, type: "movie", duration: duration, year: year, providerIds: providerIds)
    }

    private func episode(_ ratingKey: String,
                         title: String = "The Beginning",
                         show: String = "Example Show",
                         season: Int? = 1,
                         episode: Int? = 2,
                         duration: Int? = 2_700_000,
                         providerIds: [String: String]? = ["Tvdb": "12345"]) -> MediaItem {
        MediaItem(ratingKey: ratingKey,
                  title: title,
                  type: "episode",
                  duration: duration,
                  grandparentTitle: show,
                  parentIndex: season,
                  index: episode,
                  providerIds: providerIds)
    }

    @Test func activityPayloadContainsOnlyAllowlistedCatalogIdentity() throws {
        let item = movie("server-rating-key-123", title: "Dune", providerIds: ["Tmdb": "438631", "Imdb": "tt1160419"])
        let payload = try #require(SharePlayMediaActivityPayload(mediaItem: item, activityID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!))
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)

        #expect(payload.displayTitle == "Dune")
        #expect(payload.identity.kind == .movie)
        #expect(payload.identity.providerIDs.count == 2)
        #expect(payload.identity.durationMilliseconds == 9_300_000)
        #expect(json.contains("activityID"))
        #expect(json.contains("displayTitle"))
        #expect(!json.contains("server-rating-key-123"))
        #expect(!json.localizedCaseInsensitiveContains("ratingKey"))
        #expect(json.localizedCaseInsensitiveContains("tmdb"))
        #expect(json.localizedCaseInsensitiveContains("duration"))
        #expect(!json.localizedCaseInsensitiveContains("token"))
        #expect(!json.localizedCaseInsensitiveContains("http"))
    }

    @Test func activityPayloadRedactsDangerousDisplayText() throws {
        let item = movie("1", title: "https://plex.example.internal/library/metadata/1?X-Plex-Token=secret")
        #expect(SharePlayMediaActivityPayload(mediaItem: item) == nil)
    }

    @Test func activityPayloadRedactsHostnamesPathsFilenamesAndBackendLabels() throws {
        let suspiciousTitles = [
            "plex.example.internal movie",
            "nasbox:32400 movie",
            "192.0.2.10 movie",
            "[2001:db8::1] movie",
            "2001:db8::1 movie",
            "/library/metadata/123",
            "/path/to/user/Movies/Movie.mkv",
            #"C:\Media\Movie.mp4"#,
            "Movie.Name.2021.mkv",
            "ratingKey=12345",
            "backend item id abc",
            "api key: secret",
            "password=hunter2",
            "client id = abc123"
        ]

        for title in suspiciousTitles {
            #expect(SharePlayMediaActivityPayload(mediaItem: movie("1", title: title)) == nil,
                    "expected rejection for suspicious title: \(title)")
        }
    }

    @Test func activityPayloadAllowsOrdinaryMediaTitle() throws {
        let payload = try #require(SharePlayMediaActivityPayload(mediaItem: movie("1", title: "Dune: Part Two")))
        #expect(payload.displayTitle == "Dune: Part Two")
    }

    /// The display heuristics (TLD-like tokens, timestamp-shaped text, filename shapes) must
    /// NOT null the local comparable title: it never leaves the device unhashed, and nulling
    /// it disables Watch Together entirely for provider-ID-less (Plex) items whose legitimate
    /// titles merely look suspicious.
    @Test func heuristicLookingTitlesKeepLocalIdentityAndCoordinatorIdentifier() throws {
        for title in ["Startup.com", "11:14", "Movie.Name.2021.mkv"] {
            let item = movie("1", title: title, providerIds: nil)
            let identity = try #require(item.sharePlayMediaIdentity, "expected identity for: \(title)")
            #expect(identity.normalizedTitle == title.lowercased(), "expected comparable title for: \(title)")
            #expect(identity.coordinatorIdentifier != nil, "expected coordinator id for: \(title)")
        }
    }

    @Test func hardSecretMarkersStillNullComparableTitle() throws {
        let item = movie("1", title: "Movie X-Plex-Token=secret", providerIds: nil)
        let identity = try #require(item.sharePlayMediaIdentity)
        #expect(identity.normalizedTitle == nil)
        #expect(identity.coordinatorIdentifier == nil)
    }

    @Test func localIdentityNormalizesWhitelistedProviderIdsOnly() throws {
        let item = movie("rk", providerIds: [
            "Tmdb": " 438631 ",
            "IMDB": "TT1160419",
            "PlexGuid": "plex://movie/secret",
            "Tvdb": "https://example.invalid/123"
        ])
        let identity = try #require(item.sharePlayMediaIdentity)
        #expect(identity.providerIDs == [
            SharePlayProviderID(provider: .imdb, value: "tt1160419")!,
            SharePlayProviderID(provider: .tmdb, value: "438631")!
        ])
        let coordinatorIdentifier = try #require(identity.coordinatorIdentifier)
        #expect(coordinatorIdentifier.hasPrefix("visionplay:coordinator:v1:"))
        #expect(coordinatorIdentifier.count == "visionplay:coordinator:v1:".count + 64)
        #expect(!coordinatorIdentifier.contains("imdb"))
        #expect(!coordinatorIdentifier.contains("tmdb"))
        #expect(!coordinatorIdentifier.contains("tt1160419"))
        #expect(!coordinatorIdentifier.contains("438631"))
        #expect(!coordinatorIdentifier.contains("9300000"))
    }

    @Test func coordinatorIdentifierIncludesTimelineDiscriminator() throws {
        let shorter = try #require(movie("short", duration: 9_300_000).sharePlayMediaIdentity)
        let longer = try #require(movie("long", duration: 9_360_000).sharePlayMediaIdentity)

        let shorterID = try #require(shorter.coordinatorIdentifier)
        let longerID = try #require(longer.coordinatorIdentifier)
        #expect(shorterID.hasPrefix("visionplay:coordinator:v1:"))
        #expect(longerID.hasPrefix("visionplay:coordinator:v1:"))
        #expect(shorterID != longerID)
        #expect(!shorterID.contains("tmdb"))
        #expect(!shorterID.contains("438631"))
        #expect(!shorterID.contains("9300000"))
        #expect(!longerID.contains("9360000"))
    }

    @Test func duplicateProviderNamespaceCannotCreateCoordinatorIdentifier() {
        let identity = SharePlayMediaIdentity(
            kind: .movie,
            providerIDs: [
                SharePlayProviderID(provider: .tmdb, value: "438631")!,
                SharePlayProviderID(provider: .tmdb, value: "other")!
            ],
            normalizedTitle: "Dune",
            year: 2021,
            durationMilliseconds: 9_300_000)

        #expect(identity.coordinatorIdentifier == nil)
        guard case let .failed(reason) = resolver.resolve(identity, in: [movie("local")]) else {
            Issue.record("expected duplicate provider namespace to fail closed")
            return
        }
        #expect(reason == .unsupportedIdentity)
    }

    @Test func unsupportedContainersDoNotProduceSharePlayIdentity() {
        let show = MediaItem(ratingKey: "show-rk", title: "Show", type: "show")
        #expect(show.sharePlayMediaIdentity == nil)
        #expect(show.sharePlayActivityPayload == nil)
    }

    @Test func resolvesMovieByProviderIdAndExactDuration() throws {
        let requested = try #require(movie("remote", duration: 9_300_000).sharePlayMediaIdentity)
        let local = movie("local", title: "Dune: Different Edition Label", year: 2024, duration: 9_300_000)

        guard case let .resolved(match) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected resolved movie")
            return
        }
        #expect(match.ratingKey == "local")
    }

    @Test func rejectsProviderMatchWhenDurationImpliesDifferentTimeline() throws {
        let requested = try #require(movie("remote", duration: 9_300_000).sharePlayMediaIdentity)
        let local = movie("local", duration: 9_360_000)

        guard case let .failed(reason) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected timeline mismatch")
            return
        }
        #expect(reason == .timelineMismatch)
    }

    @Test func failsClosedOnAmbiguousMovieCandidates() throws {
        let requested = try #require(movie("remote").sharePlayMediaIdentity)
        let a = movie("local-a", providerIds: ["Tmdb": "438631"])
        let b = movie("local-b", providerIds: ["Tmdb": "438631"])

        guard case let .selectionRequired(candidates) = resolver.resolve(requested, in: [a, b]) else {
            Issue.record("expected ambiguity")
            return
        }
        #expect(candidates.map(\.ratingKey) == ["local-a", "local-b"])
    }

    @Test func durationIdentityRoundsToFiveSecondBuckets() throws {
        let a = try #require(movie("a", duration: 9_301_000).sharePlayMediaIdentity)
        let b = try #require(movie("b", duration: 9_302_000).sharePlayMediaIdentity)
        #expect(a.durationMilliseconds == 9_300_000)
        #expect(a.coordinatorIdentifier == b.coordinatorIdentifier)
    }

    @Test func conflictingProviderNamespaceRejectsEvenWhenAnotherProviderMatches() throws {
        let requested = try #require(movie("remote", providerIds: ["Tmdb": "A", "Imdb": "X"]).sharePlayMediaIdentity)
        let local = movie("local", providerIds: ["Tmdb": "B", "Imdb": "X"])

        guard case let .failed(reason) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected conflicting provider namespace to reject match")
            return
        }
        #expect(reason == .notFound)
    }

    @Test func manualSelectionOffersOnlySameKindAndRoundedTimeline() throws {
        let requested = try #require(movie("remote", duration: 9_301_000).sharePlayMediaIdentity)
        let sameTimeline = movie("candidate", title: "Localized", duration: 9_302_000,
                                 providerIds: ["Tmdb": "different"])
        let otherCut = movie("other-cut", duration: 9_360_000)
        let wrongKind = episode("episode", duration: 9_302_000)
        let candidates = resolver.selectableCandidates(for: requested,
                                                        in: [sameTimeline, otherCut, wrongKind])
        #expect(candidates.map(\.ratingKey) == ["candidate"])
    }

    @Test func matchingProviderNamespaceCanResolveWhenOtherNamespaceAbsent() throws {
        let requested = try #require(movie("remote", providerIds: ["Tmdb": "A", "Imdb": "X"]).sharePlayMediaIdentity)
        let local = movie("local", providerIds: ["Imdb": "X"])

        guard case let .resolved(match) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected compatible overlapping provider namespace to resolve")
            return
        }
        #expect(match.ratingKey == "local")
    }

    @Test func movieFallbackRequiresTitleYearAndDuration() throws {
        let requested = try #require(movie("remote", title: "Arrival", year: 2016, duration: 6_960_000, providerIds: nil).sharePlayMediaIdentity)
        let local = movie("local", title: " arrival ", year: 2016, duration: 6_960_000, providerIds: nil)

        guard case let .resolved(match) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected fallback movie match")
            return
        }
        #expect(match.ratingKey == "local")
    }

    @Test func movieFallbackDoesNotMatchWithoutYear() throws {
        let requested = try #require(movie("remote", title: "Untitled", year: nil, duration: 5_000, providerIds: nil).sharePlayMediaIdentity)
        let local = movie("local", title: "Untitled", year: nil, duration: 5_000, providerIds: nil)

        guard case let .failed(reason) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected no match")
            return
        }
        #expect(reason == .unsupportedIdentity)
    }

    @Test func resolvesEpisodeByProviderSeasonEpisodeAndExactTimeline() throws {
        let requested = try #require(episode("remote", season: 1, episode: 2, duration: 2_700_000).sharePlayMediaIdentity)
        let local = episode("local", title: "Localized Title", show: "Different Display Name", season: 1, episode: 2, duration: 2_700_000)

        guard case let .resolved(match) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected episode match")
            return
        }
        #expect(match.ratingKey == "local")
    }

    @Test func episodeFallbackRequiresSeriesTitleEpisodeTitleSeasonEpisodeAndTimeline() throws {
        let requested = try #require(episode("remote", title: "Pilot", show: "Example Show", providerIds: nil).sharePlayMediaIdentity)
        let local = episode("local", title: " pilot ", show: "example show", providerIds: nil)

        guard case let .resolved(match) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected fallback episode match")
            return
        }
        #expect(match.ratingKey == "local")
    }

    @Test func episodeFallbackFailsWhenEpisodeNumberDiffers() throws {
        let requested = try #require(episode("remote", providerIds: nil).sharePlayMediaIdentity)
        let local = episode("local", episode: 3, providerIds: nil)

        guard case let .failed(reason) = resolver.resolve(requested, in: [local]) else {
            Issue.record("expected no match")
            return
        }
        #expect(reason == .notFound)
    }

    @Test func missingDurationCannotResolveCoordinatorIdentity() throws {
        let requested = try #require(movie("remote", duration: nil).sharePlayMediaIdentity)
        #expect(requested.coordinatorIdentifier == nil)

        guard case let .failed(reason) = resolver.resolve(requested, in: [movie("local")]) else {
            Issue.record("expected missing timeline")
            return
        }
        #expect(reason == .missingTimeline)
    }

    @Test func readinessRequiresAcknowledgementOnlyForResolvingParticipants() {
        let waiting = SharePlayReadinessSummary(statuses: [.ready, .resolving, .unable])
        #expect(!waiting.canStart(acknowledgingUnresolved: false))
        #expect(waiting.canStart(acknowledgingUnresolved: true))

        let settled = SharePlayReadinessSummary(statuses: [.ready, .unable])
        #expect(settled.canStart(acknowledgingUnresolved: false))
    }

    @Test func lateJoinerLaunchesOnlyAfterLocalResolution() {
        #expect(!SharePlayReadinessSummary.shouldLaunchLocally(sessionStarted: true, localResolved: false))
        #expect(SharePlayReadinessSummary.shouldLaunchLocally(sessionStarted: true, localResolved: true))
        #expect(!SharePlayReadinessSummary.shouldLaunchLocally(sessionStarted: false, localResolved: true))
    }
}
