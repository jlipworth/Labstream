import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite(.serialized)
@MainActor
struct PlaybackTrackSelectionTests {
    @Test func snapshotRejectsASelectionThatIsNotInItsRows() {
        let off = PlaybackSubtitleTrack(displayName: "Off", mechanism: .offlineOff)
        let valid = PlaybackTrackSnapshot(tracks: [off], selectedID: off.id)
        let invalid = PlaybackTrackSnapshot<PlaybackSubtitleTrack>(
            tracks: [off],
            selectedID: .offlineSidecar(42))

        #expect(valid?.selectedID == .offlineOff)
        #expect(invalid == nil)
    }

    @Test func backendOffSentinelsStayInsideTheWireAdapter() {
        let off = BackendSubtitleSelection.mediaBrowserWireValue(
            MediaBrowserPlaybackPreferencePolicy.subtitleOffStreamIndex)
        let stream = BackendSubtitleSelection.mediaBrowserWireValue(7)

        #expect(off == .off)
        #expect(off?.mediaBrowserWireValue
                == MediaBrowserPlaybackPreferencePolicy.subtitleOffStreamIndex)
        #expect(off?.plexWireValue == 0)
        #expect(stream == .stream(7))
        #expect(stream?.mediaBrowserWireValue == 7)
        #expect(stream?.plexWireValue == 7)
        #expect(BackendSubtitleSelection.plexWireValue(0) == .off)
        #expect(BackendSubtitleSelection.plexWireValue(7) == .stream(7))
        #expect(BackendSubtitleSelection.mediaBrowserWireValue(-2) == nil)
    }

    @Test func offlineMenuListsMetadataWithoutParsingAndParsesOnlyTheSelectedTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = OfflineTextSubtitleTrack(id: 1,
                                             displayName: "English",
                                             language: "en",
                                             codec: "srt",
                                             relativePath: "valid.srt")
        let missing = OfflineTextSubtitleTrack(id: 2,
                                               displayName: "Missing",
                                               language: "fr",
                                               codec: "srt",
                                               relativePath: "missing.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
            .write(to: directory.appendingPathComponent(valid.relativePath),
                   atomically: true,
                   encoding: .utf8)

        let identity = ClientIdentity(clientIdentifier: "device-1",
                                      product: "Labstream",
                                      version: "1",
                                      deviceName: "Test Device")
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "item-1", title: "Offline", type: "movie"),
            sessionSource: .offline(OfflinePlaybackSession(
                fileURL: directory.appendingPathComponent("video.mkv"),
                textSubtitles: [valid, missing])),
            identity: identity,
            client: PlexClient(identity: identity))

        let loaded = try #require(try await controller.loadSubtitleTracks())
        #expect(loaded.tracks.count == 3)
        let validChoice = try #require(loaded.tracks.first { $0.id == .offlineSidecar(1) })
        let missingChoice = try #require(loaded.tracks.first { $0.id == .offlineSidecar(2) })

        try await controller.selectSubtitle(validChoice)
        await #expect(throws: (any Error).self) {
            try await controller.selectSubtitle(missingChoice)
        }
    }

    @Test func rapidOfflineSelectionsCommitOnlyTheLatestCompletedTrack() async throws {
        let gate = ControlledOfflineCueLoader()
        let (controller, tracks) = try await makeControlledOfflineController(gate: gate)
        let english = try #require(tracks.first { $0.id == .offlineSidecar(1) })
        let french = try #require(tracks.first { $0.id == .offlineSidecar(2) })

        let englishTask = Task { try await controller.selectSubtitle(english) }
        await gate.waitUntilStarted("english.srt")
        let frenchTask = Task { try await controller.selectSubtitle(french) }
        await gate.waitUntilStarted("french.srt")

        await gate.complete("french.srt", text: "French")
        try await frenchTask.value
        // The headless controller has no AVPlayerItem clock, so selection clears the live overlay.
        // Seed the newer committed visual state and prove late A cannot overwrite it.
        controller.offlineSubtitleOverlay.set("French")
        await gate.complete("english.srt", text: "English")
        try await englishTask.value

        let snapshot = try #require(try await controller.loadSubtitleTracks())
        #expect(snapshot.selectedID == .offlineSidecar(2))
        #expect(controller.offlineSubtitleOverlay.text == "French")
        #expect(UserDefaults.standard.string(
            forKey: PlaybackPreferences.Keys.preferredSubtitleLanguage) == "fr")
    }

    @Test func selectingOffInvalidatesAnInFlightOfflineParse() async throws {
        let gate = ControlledOfflineCueLoader()
        let (controller, tracks) = try await makeControlledOfflineController(gate: gate)
        let english = try #require(tracks.first { $0.id == .offlineSidecar(1) })
        let off = try #require(tracks.first { $0.id == .offlineOff })

        let englishTask = Task { try await controller.selectSubtitle(english) }
        await gate.waitUntilStarted("english.srt")
        try await controller.selectSubtitle(off)
        await gate.complete("english.srt", text: "English")
        try await englishTask.value

        let snapshot = try #require(try await controller.loadSubtitleTracks())
        #expect(snapshot.selectedID == .offlineOff)
        #expect(controller.offlineSubtitleOverlay.text == nil)
        #expect(UserDefaults.standard.bool(forKey: PlaybackPreferences.Keys.subtitlesOff))
    }

    @Test func staleMetadataAudioIDFallsBackToCurrentSelectedDefaultThenFirst() {
        let selected = PlexStream(id: 2, streamType: StreamType.audio.rawValue, selected: true)
        let fallback = PlexStream(id: 3, streamType: StreamType.audio.rawValue, isDefault: true)
        let first = PlexStream(id: 4, streamType: StreamType.audio.rawValue)

        #expect(PlaybackTrackSelectionPolicy.resolvedMetadataAudioStreamID(
            candidate: 99,
            streams: [selected, fallback, first]) == 2)
        #expect(PlaybackTrackSelectionPolicy.resolvedMetadataAudioStreamID(
            candidate: 99,
            streams: [fallback, first]) == 3)
        #expect(PlaybackTrackSelectionPolicy.resolvedMetadataAudioStreamID(
            candidate: 99,
            streams: [first]) == 4)
    }

    @Test func reversedAudioCompletionsAcceptOnlyTheLatestSelection() {
        var authority = MetadataAudioSelectionAuthority()
        let first = authority.begin(streamID: 1)
        let second = authority.begin(streamID: 2)

        // B completes first and commits; A completes last but is stale and cannot commit/restart.
        #expect(authority.accepts(second, isCancelled: false))
        #expect(!authority.accepts(first, isCancelled: false))
        #expect(!authority.accepts(second, isCancelled: true))
    }

    @Test func plexAudioPUTsSerializeSoNewestIntentIsTheLastServerAndLocalSelection() async throws {
        let gate = ControlledAudioSelector()
        let streams = [
            PlexStream(id: 1, streamType: StreamType.audio.rawValue, selected: true),
            PlexStream(id: 2, streamType: StreamType.audio.rawValue),
            PlexStream(id: 3, streamType: StreamType.audio.rawValue),
            PlexStream(id: 4, streamType: StreamType.audio.rawValue),
        ]
        let item = MediaItem(ratingKey: "item-1", title: "Movie", type: "movie", media: [
            Media(id: 1, part: [Part(id: 10, key: "/part/10", streams: streams)]),
        ])
        let identity = ClientIdentity(clientIdentifier: "device-1",
                                      product: "Labstream",
                                      version: "1",
                                      deviceName: "Test Device")
        let controller = PlaybackController(
            item: item,
            sessionSource: .plex(PlexPlaybackSession(
                server: try #require(URL(string: "https://media.invalid")),
                token: "token")),
            identity: identity,
            client: PlexClient(identity: identity),
            plexAudioStreamSelector: { partID, streamID in
                try await gate.select(partID: partID, streamID: streamID)
            })
        let initial = try #require(controller.loadAudioStreamChoices())
        let second = try #require(initial.tracks.first { $0.id == .plexStream(2) })
        let third = try #require(initial.tracks.first { $0.id == .plexStream(3) })
        let fourth = try #require(initial.tracks.first { $0.id == .plexStream(4) })

        let secondTask = Task { await controller.selectAudioStream(second) }
        await gate.waitUntilStarted(2)
        let thirdTask = Task { await controller.selectAudioStream(third) }
        while controller.activeMetadataAudioSelectionIntentID != 3 { await Task.yield() }
        let fourthTask = Task { await controller.selectAudioStream(fourth) }
        while controller.activeMetadataAudioSelectionIntentID != 4 { await Task.yield() }
        let thirdStartedWhileSecondInFlight = await gate.hasStarted(3)
        let fourthStartedWhileSecondInFlight = await gate.hasStarted(4)
        #expect(!thirdStartedWhileSecondInFlight)
        #expect(!fourthStartedWhileSecondInFlight)
        await gate.complete(2)
        await gate.waitUntilStarted(4)
        let supersededThirdWasSent = await gate.hasStarted(3)
        #expect(!supersededThirdWasSent)
        await gate.complete(4)
        await secondTask.value
        await thirdTask.value
        await fourthTask.value

        let final = try #require(controller.loadAudioStreamChoices())
        #expect(final.selectedID == .plexStream(4))
        let serverSelection = await gate.serverSelection
        let invocationOrder = await gate.invocationOrder
        let applicationOrder = await gate.applicationOrder
        #expect(serverSelection == 4)
        #expect(invocationOrder == [2, 4])
        #expect(applicationOrder == [2, 4])
        controller.stop()
    }

    private func makeControlledOfflineController(
        gate: ControlledOfflineCueLoader
    ) async throws -> (PlaybackController, [PlaybackSubtitleTrack]) {
        let tracks = [
            OfflineTextSubtitleTrack(id: 1,
                                     displayName: "English",
                                     language: "en",
                                     codec: "srt",
                                     relativePath: "english.srt"),
            OfflineTextSubtitleTrack(id: 2,
                                     displayName: "French",
                                     language: "fr",
                                     codec: "srt",
                                     relativePath: "french.srt"),
        ]
        let identity = ClientIdentity(clientIdentifier: "device-1",
                                      product: "Labstream",
                                      version: "1",
                                      deviceName: "Test Device")
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "item-1", title: "Offline", type: "movie"),
            sessionSource: .offline(OfflinePlaybackSession(
                fileURL: URL(fileURLWithPath: "/tmp/video.mkv"),
                textSubtitles: tracks)),
            identity: identity,
            client: PlexClient(identity: identity),
            offlineSubtitleCueLoader: { url in try await gate.load(url) })
        let snapshot = try #require(try await controller.loadSubtitleTracks())
        return (controller, snapshot.tracks)
    }
}

private actor ControlledOfflineCueLoader {
    private var started: Set<String> = []
    private var continuations: [String: CheckedContinuation<[OfflineTextSubtitleCue], any Error>] = [:]

    func load(_ url: URL) async throws -> [OfflineTextSubtitleCue] {
        let name = url.lastPathComponent
        started.insert(name)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[name] = continuation
        }
    }

    func waitUntilStarted(_ name: String) async {
        while !started.contains(name) { await Task.yield() }
    }

    func complete(_ name: String, text: String) {
        continuations.removeValue(forKey: name)?.resume(returning: [
            OfflineTextSubtitleCue(startMs: 0, endMs: 60_000, text: text),
        ])
    }
}

private actor ControlledAudioSelector {
    private var started: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]
    private(set) var invocationOrder: [Int] = []
    private(set) var applicationOrder: [Int] = []
    private(set) var serverSelection: Int?

    func select(partID: Int, streamID: Int) async throws {
        #expect(partID == 10)
        started.insert(streamID)
        invocationOrder.append(streamID)
        try await withCheckedThrowingContinuation { continuation in
            continuations[streamID] = continuation
        }
    }

    func waitUntilStarted(_ streamID: Int) async {
        while !started.contains(streamID) { await Task.yield() }
    }

    func hasStarted(_ streamID: Int) -> Bool {
        started.contains(streamID)
    }

    func complete(_ streamID: Int) {
        applicationOrder.append(streamID)
        serverSelection = streamID
        continuations.removeValue(forKey: streamID)?.resume()
    }
}
