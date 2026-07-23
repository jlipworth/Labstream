import CoreGraphics
import Foundation
import ImageIO
import PMSKit
import Testing
@testable import Labstream

@Suite("Artwork pipeline")
@MainActor
struct ArtworkPipelineTests {
    @Test func plexDescriptorExecutesExactAuthenticatedRequestBytes() async throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "plex-secret")
        let descriptor = try #require(MediaArtwork.descriptor(
            path: "/library/metadata/42/thumb/9",
            appModel: model,
            pixelWidth: 420,
            pixelHeight: 630
        ))

        let request = try await executeAndCapture(descriptor)
        let url = try #require(request.url)
        #expect(descriptor.backend == .plex)
        #expect(url.host == "plex.example.test")
        #expect(url.path == "/photo/:/transcode")
        let query = queryMap(url)
        #expect(query["url"] == "/library/metadata/42/thumb/9")
        #expect(query["width"] == "420")
        #expect(query["height"] == "630")
        #expect(query["minSize"] == "1")
        #expect(query["upscale"] == "1")
        #expect(query["X-Plex-Token"] == "plex-secret")
    }

    @Test func jellyfinDescriptorExecutesExactAuthenticatedRequestBytes() async throws {
        let model = makeModel(activeBackend: .jellyfin)
        applyMediaBrowser(.jellyfin, to: model, token: "jellyfin-secret")
        let descriptor = try #require(MediaArtwork.descriptor(
            path: "jellyfin://item/item-7/Primary?tag=tag-jf",
            appModel: model,
            pixelWidth: 320,
            pixelHeight: 480
        ))

        let request = try await executeAndCapture(descriptor)
        let url = try #require(request.url)
        #expect(descriptor.backend == .jellyfin)
        #expect(url.host == "jellyfin.example.test")
        #expect(url.path == "/base/Items/item-7/Images/Primary")
        let query = queryMap(url)
        #expect(query["tag"] == "tag-jf")
        #expect(query["width"] == "320")
        #expect(query["height"] == "480")
        #expect(url.query?.contains("jellyfin-secret") == false)
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/jpeg,*/*")
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("MediaBrowser "))
        #expect(authorization.contains("Token=\"jellyfin-secret\""))
        #expect(authorization.contains("DeviceId=\"artwork-device\""))
    }

    @Test func embyDescriptorExecutesExactAuthenticatedRequestBytes() async throws {
        let model = makeModel(activeBackend: .emby)
        applyMediaBrowser(.emby, to: model, token: "emby-secret")
        let descriptor = try #require(MediaArtwork.descriptor(
            path: "emby://item/item-8/Backdrop?tag=tag-emby",
            appModel: model,
            pixelWidth: 640,
            pixelHeight: 360
        ))

        let request = try await executeAndCapture(descriptor)
        let url = try #require(request.url)
        #expect(descriptor.backend == .emby)
        #expect(url.host == "emby.example.test")
        #expect(url.path == "/base/Items/item-8/Images/Backdrop")
        let query = queryMap(url)
        #expect(query["tag"] == "tag-emby")
        #expect(query["width"] == "640")
        #expect(query["height"] == "360")
        #expect(url.query?.contains("emby-secret") == false)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "emby-secret")
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("Emby "))
        #expect(authorization.contains("Token=\"emby-secret\""))
        #expect(authorization.contains("UserId=\"emby-user\""))
    }

    @Test func tokenABAAndDimensionsDriveOpaqueTaskIdentity() throws {
        let model = makeModel(activeBackend: .jellyfin)
        let path = "jellyfin://item/item-1/Primary?tag=stable"
        applyMediaBrowser(.jellyfin, to: model, token: "token-A")
        let first = try #require(MediaArtwork.descriptor(path: path,
                                                         appModel: model,
                                                         pixelWidth: 400,
                                                         pixelHeight: 600))
        let identical = try #require(MediaArtwork.descriptor(path: path,
                                                             appModel: model,
                                                             pixelWidth: 400,
                                                             pixelHeight: 600))
        let resized = try #require(MediaArtwork.descriptor(path: path,
                                                           appModel: model,
                                                           pixelWidth: 401,
                                                           pixelHeight: 600))
        let differentSource = try #require(MediaArtwork.descriptor(
            path: "jellyfin://item/item-2/Primary?tag=stable",
            appModel: model,
            pixelWidth: 400,
            pixelHeight: 600
        ))

        model.jellyfinAccessToken = "token-B"
        let second = try #require(MediaArtwork.descriptor(path: path,
                                                          appModel: model,
                                                          pixelWidth: 400,
                                                          pixelHeight: 600))
        model.jellyfinAccessToken = "token-A"
        let third = try #require(MediaArtwork.descriptor(path: path,
                                                         appModel: model,
                                                         pixelWidth: 400,
                                                         pixelHeight: 600))

        #expect(first.taskIdentity == identical.taskIdentity)
        #expect(first.taskIdentity.purpose == .poster)
        #expect(first.taskIdentity != resized.taskIdentity)
        #expect(first.taskIdentity != differentSource.taskIdentity)
        #expect(first.taskIdentity != second.taskIdentity)
        #expect(second.taskIdentity != third.taskIdentity)
        #expect(first.taskIdentity != third.taskIdentity)
    }

    @Test func syntheticRefsResolveTheirInactiveOwningLanes() throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "plex")
        applyMediaBrowser(.jellyfin, to: model, token: "jf")
        applyMediaBrowser(.emby, to: model, token: "emby")
        let jellyfinAuthority = try #require(
            model.authenticatedBrowseSession(for: .jellyfin)?.authority)
        let embyAuthority = try #require(model.authenticatedBrowseSession(for: .emby)?.authority)

        let jellyfin = try #require(MediaArtwork.descriptor(
            path: "jellyfin://item/jf/Primary?tag=t",
            appModel: model,
            pixelWidth: 200,
            pixelHeight: 300
        ))
        let emby = try #require(MediaArtwork.descriptor(
            path: "emby://item/em/Primary?tag=t",
            appModel: model,
            pixelWidth: 200,
            pixelHeight: 300
        ))

        #expect(model.activeBackend == .plex)
        #expect(jellyfin.backend == .jellyfin)
        #expect(jellyfin.taskIdentity.authority == .authenticated(jellyfinAuthority))
        #expect(emby.backend == .emby)
        #expect(emby.taskIdentity.authority == .authenticated(embyAuthority))
    }

    @Test func unconfiguredSyntheticLaneNeverFallsBackToActivePlexCredentials() {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "plex-secret")

        #expect(MediaArtwork.descriptor(path: "jellyfin://item/jf/Primary?tag=t",
                                        appModel: model,
                                        pixelWidth: 200,
                                        pixelHeight: 300) == nil)
        #expect(MediaArtwork.descriptor(path: "emby://item/em/Primary?tag=t",
                                        appModel: model,
                                        pixelWidth: 200,
                                        pixelHeight: 300) == nil)
    }

    @Test func taskAndDescriptorDescriptionsNeverExposeCredentialsOrSource() throws {
        let model = makeModel(activeBackend: .plex)
        let token = "never-log-this-plex-secret"
        let source = "/library/metadata/private-source/thumb/1"
        applyPlex(to: model, token: token)
        let descriptor = try #require(MediaArtwork.descriptor(path: source,
                                                               appModel: model,
                                                               pixelWidth: 400,
                                                               pixelHeight: 600))

        for rendered in [
            String(describing: descriptor.taskIdentity),
            String(reflecting: descriptor.taskIdentity),
            String(describing: descriptor),
            String(reflecting: descriptor),
        ] {
            #expect(!rendered.contains(token))
            #expect(!rendered.contains(source))
            #expect(!rendered.contains("X-Plex-Token"))
            #expect(rendered.contains("<redacted>"))
        }

        var dumped = ""
        dump(descriptor, to: &dumped)
        #expect(!dumped.contains(token))
        #expect(!dumped.contains(source))
        #expect(!dumped.contains("X-Plex-Token"))
        #expect(!dumped.contains("request"))
        #expect(dumped.contains("taskIdentity"))

        var identityDump = ""
        dump(descriptor.taskIdentity, to: &identityDump)
        #expect(!identityDump.contains(token))
        #expect(!identityDump.contains(source))
        #expect(!identityDump.contains("sourceDigest"))
        #expect(!identityDump.contains("UUID"))
        #expect(identityDump.contains("<opaque>"))
        #expect(identityDump.contains("<redacted>"))

        let reflectedLabels = Mirror(reflecting: descriptor).children.compactMap(\.label)
        #expect(reflectedLabels == ["taskIdentity", "backend"])
    }

    @Test func pipelineClassifiesHTTPAndDecodeFailuresForPosterRetryPolicy() async throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "token")
        let descriptor = try #require(MediaArtwork.descriptor(path: "/thumb",
                                                               appModel: model,
                                                               pixelWidth: 40,
                                                               pixelHeight: 60))

        let missing = try await pipelineError(descriptor, status: 404, data: Data())
        #expect(missing == .httpStatus(404))
        #expect(missing.isDefinitiveClientFailure)

        let server = try await pipelineError(descriptor, status: 503, data: Data())
        #expect(server == .httpStatus(503))
        #expect(!server.isDefinitiveClientFailure)

        let invalid = try await pipelineError(descriptor, status: 200, data: Data("not-image".utf8))
        #expect(invalid == .invalidImage)
        #expect(!invalid.isDefinitiveClientFailure)
    }

    @Test func localFileBypassesRemoteTransportAndUsesPersistedGenerationIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("private-offline-poster.png")
        try Self.validPNG.write(to: url)
        let owner = Data("persisted-owner".utf8)
        let first = try #require(ArtworkRequestDescriptor.localFile(
            url, backend: .emby, ownerData: owner, generation: 7,
            pixelWidth: 44, pixelHeight: 66))
        let identical = try #require(ArtworkRequestDescriptor.localFile(
            url, backend: .emby, ownerData: owner, generation: 7,
            pixelWidth: 44, pixelHeight: 66))
        let replacement = try #require(ArtworkRequestDescriptor.localFile(
            url, backend: .emby, ownerData: owner, generation: 8,
            pixelWidth: 44, pixelHeight: 66))
        #expect(first.taskIdentity == identical.taskIdentity)
        #expect(first.taskIdentity != replacement.taskIdentity)
        #expect(first.taskIdentity.authority != .authenticated(BrowseSessionAuthority()))

        let remoteCalls = TestLockedBox(0)
        let pipeline = ArtworkPipeline { _ in
            remoteCalls.withValue { $0 += 1 }
            throw ArtworkTestTransportFailure.injected
        }
        let result = try await pipeline.fetch(first)
        #expect(remoteCalls.value == 0)
        #expect(result.delivery == .localFile)
        #expect(result.encodedData == Self.validPNG)
        #expect(result.encodedTypeIdentifier == "public.png")

        var responseDump = ""
        dump(result, to: &responseDump)
        #expect(!responseDump.contains("CGImage"))
        #expect(!responseDump.contains("bytes: ["))
        #expect(responseDump.contains("<opaque>"))
        #expect(responseDump.contains("<redacted>"))

        for rendered in [String(describing: first), String(reflecting: first)] {
            #expect(!rendered.contains(directory.path))
            #expect(!rendered.contains(url.lastPathComponent))
        }
        var dumped = ""
        dump(first, to: &dumped)
        #expect(!dumped.contains(directory.path))
        #expect(!dumped.contains(url.lastPathComponent))
        #expect(!dumped.contains("localFile"))
    }

    @Test func samePathSameByteCountReplacementBypassesEveryCacheGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stable-poster-name")
        let owner = Data("same-persisted-owner".utf8)
        try Self.validPNG.write(to: url)
        let first = try #require(ArtworkRequestDescriptor.localFile(
            url, backend: .jellyfin, ownerData: owner, generation: 41,
            pixelWidth: 40, pixelHeight: 60))
        let pipeline = ArtworkPipeline { _ in
            throw ArtworkTestTransportFailure.injected
        }
        _ = try await pipeline.fetch(first)

        // Stable path and stable byte count deliberately reproduce the alias that sideAssetBytes
        // could not detect. Only the persisted content generation changes.
        try Data(repeating: 0xA5, count: Self.validPNG.count).write(to: url)
        let replacement = try #require(ArtworkRequestDescriptor.localFile(
            url, backend: .jellyfin, ownerData: owner, generation: 42,
            pixelWidth: 40, pixelHeight: 60))
        do {
            _ = try await pipeline.fetch(replacement)
            Issue.record("Replacement generation must not reuse old decoded/compressed bytes")
        } catch let error as ArtworkPipelineError {
            #expect(error == .invalidImage)
        }
    }

    @Test func localFileRejectsNonFilesAndNormalizesMissingPathErrors() async throws {
        #expect(ArtworkRequestDescriptor.localFile(
            URL(string: "https://example.test/poster")!,
            backend: .plex,
            ownerData: Data("owner".utf8),
            generation: 1,
            pixelWidth: 40,
            pixelHeight: 60) == nil)

        let secretPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("must-not-escape-\(UUID().uuidString).png")
        let descriptor = try #require(ArtworkRequestDescriptor.localFile(
            secretPath, backend: .plex, ownerData: Data("owner".utf8), generation: 1,
            pixelWidth: 40, pixelHeight: 60))
        do {
            _ = try await ArtworkPipeline { _ in
                throw ArtworkTestTransportFailure.injected
            }.fetch(descriptor)
            Issue.record("Expected normalized local-file failure")
        } catch let error as ArtworkPipelineError {
            #expect(error == .transportFailure(code: nil))
            #expect(!String(reflecting: error).contains(secretPath.path))
        }
    }

    @Test func offlineArtworkSourceReflectionRedactsFileAndPersistedServerOwner() throws {
        let secretServer = "https://secret-offline-owner.example.test/private"
        let owner = OfflineSideAssetBundleOwner(
            attemptID: "private-attempt",
            source: OfflineSideAssetSourceIdentity(
                backendKind: .emby,
                backendBaseURLString: secretServer,
                backendServerID: "private-server-id",
                mediaSourceID: "private-media-source",
                mediaIndex: 0,
                partIndex: 0,
                sourcePartID: 1,
                downloadLane: .original,
                serverPreparedVersion: false))
        let metadata = OfflineMetadata(ratingKey: "emby:item",
                                       title: "Offline",
                                       type: "movie",
                                       posterRelativePath: "private-poster.png",
                                       posterGeneration: 9,
                                       sideAssetBundleOwner: owner,
                                       backendKind: .emby)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-poster.png")
        let source = try #require(OfflineArtworkSource(fileURL: fileURL,
                                                       metadata: metadata,
                                                       ratingKey: metadata.ratingKey))
        for rendered in [String(describing: source), String(reflecting: source)] {
            #expect(!rendered.contains(fileURL.path))
            #expect(!rendered.contains(secretServer))
            #expect(!rendered.contains("private-attempt"))
            #expect(!rendered.contains("private-server-id"))
        }
        var dumped = ""
        dump(source, to: &dumped)
        #expect(!dumped.contains(fileURL.path))
        #expect(!dumped.contains(secretServer))
        #expect(!dumped.contains("private-attempt"))
        #expect(dumped.contains("<redacted>"))
        #expect(dumped.contains("<opaque>"))
    }

    @Test func localPlaybackWithoutPersistedArtworkNeverConsultsCurrentAuthentication() throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "wrong-current-account")
        let path = "/library/metadata/from-old-offline-owner/thumb/1"
        let local = PlayerArtworkDescriptorPolicy.descriptor(
            isLocalPlayback: true,
            offlineSource: nil,
            path: path,
            appModel: model,
            pixelWidth: 600,
            pixelHeight: 900)
        #expect(local == nil)

        let online = PlayerArtworkDescriptorPolicy.descriptor(
            isLocalPlayback: false,
            offlineSource: nil,
            path: path,
            appModel: model,
            pixelWidth: 600,
            pixelHeight: 900)
        #expect(online != nil)
    }

    @Test func decodedCacheChargesRetainedEncodedBytes() async throws {
        let descriptor = try makePlexDescriptor(path: "/encoded-cost", pixels: 1)
        let calls = TestLockedBox(0)
        var configuration = ArtworkPipelineConfiguration()
        configuration.compressedCostLimit = 0
        // A decoded 1x1 image alone fits; the decoded image plus retained PNG bytes does not.
        configuration.decodedCostLimit = 16
        let pipeline = ArtworkPipeline(configuration: configuration) { _ in
            calls.withValue { $0 += 1 }
            return (Self.validPNG, Self.response(status: 200))
        }
        _ = try await pipeline.fetch(descriptor)
        _ = try await pipeline.fetch(descriptor)
        #expect(calls.value == 2)
    }

    @Test func deliveryProvenanceDistinguishesWireDecodedCompressedAndJoinedReaders() async throws {
        let descriptor = try makePlexDescriptor(path: "/delivery", pixels: 80)

        let decodedCalls = TestLockedBox(0)
        let decodedPipeline = ArtworkPipeline { _ in
            decodedCalls.withValue { $0 += 1 }
            return (Self.squarePNG, Self.response(status: 200))
        }
        let network = try await decodedPipeline.fetch(descriptor)
        let decoded = try await decodedPipeline.fetch(descriptor)
        #expect(network.delivery == .networkDecode)
        #expect(decoded.delivery == .decodedCache)
        #expect(decodedCalls.value == 1)

        var compressedConfiguration = ArtworkPipelineConfiguration()
        compressedConfiguration.decodedCostLimit = 0
        let compressedCalls = TestLockedBox(0)
        let compressedPipeline = ArtworkPipeline(configuration: compressedConfiguration) { _ in
            compressedCalls.withValue { $0 += 1 }
            return (Self.squarePNG, Self.response(status: 200))
        }
        #expect(try await compressedPipeline.fetch(descriptor).delivery == .networkDecode)
        #expect(try await compressedPipeline.fetch(descriptor).delivery == .compressedCacheDecode)
        #expect(compressedCalls.value == 1)

        let probe = ControlledArtworkTransport()
        let joinedPipeline = ArtworkPipeline { descriptor in try await probe.fetch(descriptor) }
        let owner = Task { try await joinedPipeline.fetch(descriptor) }
        try await probe.waitUntilStarted(count: 1)
        let joiner = Task { try await joinedPipeline.fetch(descriptor) }
        try await waitForWaiters(2, descriptor: descriptor, pipeline: joinedPipeline)
        await probe.succeed(at: 0, data: Self.squarePNG)
        #expect(try await owner.value.delivery == .networkDecode)
        #expect(try await joiner.value.delivery == .inFlightJoin)
        #expect(await probe.startedCount == 1)
    }

    @Test func pipelineRedactsTransportErrorsAndRejectsNonHTTPResponses() async throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "token")
        let descriptor = try #require(MediaArtwork.descriptor(path: "/thumb",
                                                               appModel: model,
                                                               pixelWidth: 40,
                                                               pixelHeight: 60))
        let secret = "transport-secret"
        let failingURL = URL(string: "https://plex.example.test/image?X-Plex-Token=\(secret)")!
        let failed = ArtworkPipeline { _ in
            throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: failingURL])
        }
        do {
            _ = try await failed.fetch(descriptor)
            Issue.record("Transport errors must remain retryable without leaking request data")
        } catch let error as ArtworkPipelineError {
            #expect(error == .transportFailure(code: URLError.timedOut.rawValue))
            #expect(!String(reflecting: error).contains(secret))
            #expect(!String(reflecting: error).contains("X-Plex-Token"))
        }

        let unknown = ArtworkPipeline { _ in throw ArtworkTestTransportFailure.injected }
        do {
            _ = try await unknown.fetch(descriptor)
            Issue.record("Unknown transport errors must be normalized")
        } catch let error as ArtworkPipelineError {
            #expect(error == .transportFailure(code: nil))
        }

        let nonHTTP = ArtworkPipeline { _ in
            let url = URL(string: "file:///tmp/artwork")!
            return (Self.validPNG,
                    URLResponse(url: url,
                                mimeType: "image/png",
                                expectedContentLength: Self.validPNG.count,
                                textEncodingName: nil))
        }
        do {
            _ = try await nonHTTP.fetch(descriptor)
            Issue.record("Non-HTTP responses must be classified explicitly")
        } catch let error as ArtworkPipelineError {
            #expect(error == .invalidResponse)
        }
    }

    @Test func cancelledFetchRejectsLateBytesFromCancellationIgnoringTransport() async throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "token")
        let descriptor = try #require(MediaArtwork.descriptor(path: "/thumb",
                                                               appModel: model,
                                                               pixelWidth: 40,
                                                               pixelHeight: 60))
        let gate = CancellationIgnoringArtworkTransport()
        let pipeline = ArtworkPipeline { _ in try await gate.fetch() }
        let fetch = Task { try await pipeline.fetch(descriptor) }
        try await gate.waitUntilStarted()

        fetch.cancel()
        await gate.succeed(url: URL(string: "https://plex.example.test/thumb")!,
                           data: Self.validPNG)
        do {
            _ = try await fetch.value
            Issue.record("A cancelled artwork fetch must reject late transport bytes")
        } catch is CancellationError {
            // The post-await fence, not transport cooperation, owns this guarantee.
        }
    }

    @Test func exactConcurrentReadersJoinOneTransportAndOneWaiterCanCancel() async throws {
        let descriptor = try makePlexDescriptor(path: "/joined", pixels: 80)
        let probe = ControlledArtworkTransport()
        let pipeline = ArtworkPipeline { descriptor in try await probe.fetch(descriptor) }

        let cancelled = Task { try await pipeline.fetch(descriptor) }
        try await probe.waitUntilStarted(count: 1)
        let survivor = Task { try await pipeline.fetch(descriptor) }
        try await waitForWaiters(2, descriptor: descriptor, pipeline: pipeline)
        #expect(await probe.startedCount == 1)

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("An individual artwork waiter must cancel promptly")
        } catch is CancellationError {
            // The shared transport remains owned by the surviving waiter.
        }
        #expect(await probe.cancelledTransportCount == 0)

        await probe.succeed(at: 0, data: Self.squarePNG)
        #expect(try await survivor.value.statusCode == 200)
        #expect(await probe.startedCount == 1)
    }

    @Test func sameSourceUnderDifferentAuthoritiesNeverJoinsOrSharesCache() async throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "token-A")
        let firstDescriptor = try #require(MediaArtwork.descriptor(
            path: "/authority-isolation", appModel: model,
            pixelWidth: 80, pixelHeight: 80))
        model.serverToken = "token-B"
        let secondDescriptor = try #require(MediaArtwork.descriptor(
            path: "/authority-isolation", appModel: model,
            pixelWidth: 80, pixelHeight: 80))
        let probe = ControlledArtworkTransport()
        let pipeline = ArtworkPipeline { descriptor in try await probe.fetch(descriptor) }

        let first = Task { try await pipeline.fetch(firstDescriptor) }
        let second = Task { try await pipeline.fetch(secondDescriptor) }
        try await probe.waitUntilStarted(count: 2)
        #expect(firstDescriptor.taskIdentity != secondDescriptor.taskIdentity)
        #expect(await probe.startedCount == 2)

        await probe.succeed(identity: firstDescriptor.taskIdentity, data: Self.squarePNG)
        await probe.succeed(identity: secondDescriptor.taskIdentity, data: Self.squarePNG)
        _ = try await first.value
        _ = try await second.value

        _ = try await pipeline.fetch(firstDescriptor)
        _ = try await pipeline.fetch(secondDescriptor)
        #expect(await probe.startedCount == 2)
    }

    @Test func lastWaiterCancellationCancelsSharedTransportWithoutPublishingCache() async throws {
        let descriptor = try makePlexDescriptor(path: "/all-cancel", pixels: 80)
        let probe = ControlledArtworkTransport()
        let pipeline = ArtworkPipeline { descriptor in try await probe.fetch(descriptor) }
        let first = Task { try await pipeline.fetch(descriptor) }
        let second = Task { try await pipeline.fetch(descriptor) }
        try await probe.waitUntilStarted(count: 1)
        try await waitForWaiters(2, descriptor: descriptor, pipeline: pipeline)

        first.cancel()
        second.cancel()
        for waiter in [first, second] {
            do {
                _ = try await waiter.value
                Issue.record("Every cancelled waiter must return CancellationError")
            } catch is CancellationError {}
        }
        try await probe.waitUntilCancelled(count: 1)
        #expect(await probe.startedCount == 1)

        // Let the deliberately cancellation-ignoring transport unwind. Its late bytes must not
        // become a cache hit for the next real consumer.
        await probe.succeed(at: 0, data: Self.squarePNG)
        let retry = Task { try await pipeline.fetch(descriptor) }
        try await probe.waitUntilStarted(count: 2)
        await probe.succeed(at: 1, data: Self.squarePNG)
        #expect(try await retry.value.statusCode == 200)
        #expect(await probe.startedCount == 2)
    }

    @Test func samePhysicalOriginIsBoundedAndQueuedVisibleWorkPreemptsBackground() async throws {
        var configuration = ArtworkPipelineConfiguration()
        configuration.maxConcurrentPerOrigin = 1
        let probe = ControlledArtworkTransport()
        let pipeline = ArtworkPipeline(configuration: configuration) { descriptor in
            try await probe.fetch(descriptor)
        }
        let blockerDescriptor = try makePlexDescriptor(path: "/blocker", pixels: 80)
        let lowDescriptor = try makePlexDescriptor(path: "/low", pixels: 80)
        let highDescriptor = try makePlexDescriptor(path: "/high", pixels: 80)

        let blocker = Task { try await pipeline.fetch(blockerDescriptor, priority: .utility) }
        try await probe.waitUntilStarted(count: 1)
        let low = Task { try await pipeline.fetch(lowDescriptor, priority: .background) }
        try await waitForWaiters(1, descriptor: lowDescriptor, pipeline: pipeline)
        let high = Task { try await pipeline.fetch(highDescriptor, priority: .visible) }
        try await waitForWaiters(1, descriptor: highDescriptor, pipeline: pipeline)
        #expect(await probe.startedCount == 1)
        #expect(await probe.maximumActive == 1)

        await probe.succeed(at: 0, data: Self.squarePNG)
        _ = try await blocker.value
        try await probe.waitUntilStarted(count: 2)
        let afterHighAdmission = await probe.startedIdentities
        #expect(afterHighAdmission[1] == highDescriptor.taskIdentity)
        await probe.succeed(at: 1, data: Self.squarePNG)
        _ = try await high.value
        try await probe.waitUntilStarted(count: 3)
        let afterLowAdmission = await probe.startedIdentities
        #expect(afterLowAdmission[2] == lowDescriptor.taskIdentity)
        await probe.succeed(at: 2, data: Self.squarePNG)
        _ = try await low.value
        #expect(await probe.maximumActive == 1)
    }

    @Test func differentOriginsAdmitIndependentlyButReauthAtSameOriginDoesNotBypassLimit() async throws {
        var configuration = ArtworkPipelineConfiguration()
        configuration.maxConcurrentPerOrigin = 1
        let probe = ControlledArtworkTransport()
        let pipeline = ArtworkPipeline(configuration: configuration) { descriptor in
            try await probe.fetch(descriptor)
        }
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "token-A")
        let plexA = try #require(MediaArtwork.descriptor(path: "/a", appModel: model,
                                                         pixelWidth: 80, pixelHeight: 80))
        model.serverToken = "token-B"
        let plexB = try #require(MediaArtwork.descriptor(path: "/b", appModel: model,
                                                         pixelWidth: 80, pixelHeight: 80))
        applyMediaBrowser(.jellyfin, to: model, token: "jf")
        let jellyfin = try #require(MediaArtwork.descriptor(
            path: "jellyfin://item/jf/Primary?tag=t", appModel: model,
            pixelWidth: 80, pixelHeight: 80))

        let firstOrigin = Task { try await pipeline.fetch(plexA) }
        try await probe.waitUntilStarted(count: 1)
        let reauthenticatedSameOrigin = Task { try await pipeline.fetch(plexB) }
        let otherOrigin = Task { try await pipeline.fetch(jellyfin) }
        try await waitForWaiters(1, descriptor: plexB, pipeline: pipeline)
        try await probe.waitUntilStarted(count: 2)
        let initiallyStarted = await probe.startedIdentities
        #expect(initiallyStarted.contains(jellyfin.taskIdentity))
        #expect(!initiallyStarted.contains(plexB.taskIdentity))
        #expect(await probe.maximumActive == 2)

        await probe.succeed(identity: plexA.taskIdentity, data: Self.squarePNG)
        _ = try await firstOrigin.value
        try await probe.waitUntilStarted(count: 3)
        #expect(await probe.startedIdentities.contains(plexB.taskIdentity))

        await probe.succeed(identity: jellyfin.taskIdentity, data: Self.squarePNG)
        _ = try await otherOrigin.value
        await probe.succeed(identity: plexB.taskIdentity, data: Self.squarePNG)
        _ = try await reauthenticatedSameOrigin.value
    }

    @Test func sharedOriginAcrossBackendsAndExplicitDefaultPortUsesOneAdmissionLane() async throws {
        var configuration = ArtworkPipelineConfiguration()
        configuration.maxConcurrentPerOrigin = 1
        let probe = ControlledArtworkTransport()
        let pipeline = ArtworkPipeline(configuration: configuration) { descriptor in
            try await probe.fetch(descriptor)
        }
        let model = makeModel(activeBackend: .plex)
        model.serverBaseURL = URL(string: "https://shared.example.test")!
        model.serverToken = "plex"
        let plex = try #require(MediaArtwork.descriptor(path: "/plex", appModel: model,
                                                         pixelWidth: 80, pixelHeight: 80))
        model.applyMediaBrowserSession(
            backend: .jellyfin,
            server: URL(string: "https://shared.example.test:443")!,
            token: "jellyfin",
            userID: "jf-user",
            serverID: "jf-server"
        )
        let jellyfin = try #require(MediaArtwork.descriptor(
            path: "jellyfin://item/jf/Primary?tag=t", appModel: model,
            pixelWidth: 80, pixelHeight: 80))

        let first = Task { try await pipeline.fetch(plex) }
        try await probe.waitUntilStarted(count: 1)
        let second = Task { try await pipeline.fetch(jellyfin) }
        try await waitForWaiters(1, descriptor: jellyfin, pipeline: pipeline)
        #expect(await probe.startedCount == 1)
        #expect(await probe.maximumActive == 1)

        await probe.succeed(identity: plex.taskIdentity, data: Self.squarePNG)
        _ = try await first.value
        try await probe.waitUntilStarted(count: 2)
        #expect(await probe.startedIdentities[1] == jellyfin.taskIdentity)
        await probe.succeed(identity: jellyfin.taskIdentity, data: Self.squarePNG)
        _ = try await second.value
        #expect(await probe.maximumActive == 1)
    }

    @Test func memoryCostsEvictCompressedAndDecodedEntriesDeterministically() async throws {
        let firstDescriptor = try makePlexDescriptor(path: "/cache-a", pixels: 64)
        let secondDescriptor = try makePlexDescriptor(path: "/cache-b", pixels: 64)
        let firstData = try Self.makePNG(width: 128, height: 128, component: 0x22)
        let secondData = try Self.makePNG(width: 128, height: 128, component: 0xCC)
        var configuration = ArtworkPipelineConfiguration()
        configuration.decodedCostLimit = 64 * 64 * 4
        configuration.compressedCostLimit = max(firstData.count, secondData.count)
        let counts = TestLockedBox<[ArtworkTaskIdentity: Int]>([:])
        let pipeline = ArtworkPipeline(configuration: configuration) { descriptor in
            counts.withValue { $0[descriptor.taskIdentity, default: 0] += 1 }
            let data = descriptor.taskIdentity == firstDescriptor.taskIdentity ? firstData : secondData
            return (data, Self.response(status: 200))
        }

        _ = try await pipeline.fetch(firstDescriptor)
        _ = try await pipeline.fetch(secondDescriptor)
        _ = try await pipeline.fetch(firstDescriptor)
        #expect(counts.value[firstDescriptor.taskIdentity] == 2)
        #expect(counts.value[secondDescriptor.taskIdentity] == 1)
    }

    @Test func imageIODownsamplesAtActualOneTwoAndThreeXDisplayScales() async throws {
        let source = try Self.makePNG(width: 900, height: 900, component: 0x77)
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: "token")
        let pipeline = ArtworkPipeline { _ in (source, Self.response(status: 200)) }

        for scale in [CGFloat(1), 2, 3] {
            let pixels = MediaArtwork.pixelDimensions(width: 100,
                                                       height: 80,
                                                       displayScale: scale,
                                                       requestScale: nil)
            #expect(pixels.width == Int(100 * scale))
            #expect(pixels.height == Int(80 * scale))
            let descriptor = try #require(MediaArtwork.descriptor(
                path: "/scale-\(Int(scale))", appModel: model,
                pixelWidth: pixels.width, pixelHeight: pixels.height))
            let result = try await pipeline.fetch(descriptor)
            #expect(result.image.pixelWidth == pixels.height)
            #expect(result.image.pixelHeight == pixels.height)
            #expect(result.image.pixelWidth <= pixels.width)
            #expect(result.image.pixelHeight <= pixels.height)
        }

        let override = MediaArtwork.pixelDimensions(width: 100,
                                                     height: 80,
                                                     displayScale: 3,
                                                     requestScale: 1)
        #expect(override.width == 100)
        #expect(override.height == 80)

        let fractional = MediaArtwork.pixelDimensions(width: 100.5,
                                                       height: 80.25,
                                                       displayScale: 3,
                                                       requestScale: nil)
        #expect(fractional.width == 302)
        #expect(fractional.height == 241)

        let rotatedSource = try Self.makeImageData(width: 600,
                                                   height: 300,
                                                   component: 0x44,
                                                   type: "public.jpeg" as CFString,
                                                   orientation: .right)
        let rotatedPipeline = ArtworkPipeline { _ in
            (rotatedSource, Self.response(status: 200))
        }
        let rotatedDescriptor = try #require(MediaArtwork.descriptor(
            path: "/rotated", appModel: model,
            pixelWidth: 100, pixelHeight: 200))
        let rotated = try await rotatedPipeline.fetch(rotatedDescriptor)
        #expect(rotated.image.orientation == .up)
        #expect(rotated.image.pixelWidth == 100)
        #expect(rotated.image.pixelHeight == 200)
    }

    @Test func nonpersistentTransportDisablesCredentialBearingCachesAndCookies() async throws {
        let configuration = ArtworkTransportPolicy.nonpersistentConfiguration()
        #expect(configuration.identifier == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)

        let descriptor = try makePlexDescriptor(path: "/privacy", pixels: 80,
                                                token: "never-persist")
        let captured = TestLockedBox<URLRequest?>(nil)
        let stub = TestURLProtocolStub { request in
            captured.withValue { $0 = request }
            return (Self.response(for: request, status: 200), Self.squarePNG)
        }
        let pipeline = ArtworkPipeline(session: URLSession(configuration: stub.configuration))
        _ = try await pipeline.fetch(descriptor)
        #expect(captured.value?.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test func negativePolicyCachesOnlyClientFailuresAndClearResetsAllMemoryState() async throws {
        let descriptor = try makePlexDescriptor(path: "/negative", pixels: 80)
        let now = TestLockedBox<UInt64>(1_000)
        let status = TestLockedBox(404)
        let calls = TestLockedBox(0)
        var configuration = ArtworkPipelineConfiguration()
        configuration.negativeTTLNanoseconds = 100
        configuration.nowNanoseconds = { now.value }
        let pipeline = ArtworkPipeline(configuration: configuration) { _ in
            calls.withValue { $0 += 1 }
            return (Self.squarePNG, Self.response(status: status.value))
        }

        for _ in 0..<2 {
            do { _ = try await pipeline.fetch(descriptor); Issue.record("Expected 404") }
            catch let error as ArtworkPipelineError { #expect(error == .httpStatus(404)) }
        }
        #expect(calls.value == 1)

        now.withValue { $0 = 1_101 }
        do { _ = try await pipeline.fetch(descriptor); Issue.record("Expected expired 404 retry") }
        catch let error as ArtworkPipelineError { #expect(error == .httpStatus(404)) }
        #expect(calls.value == 2)

        await pipeline.clear()
        status.withValue { $0 = 200 }
        _ = try await pipeline.fetch(descriptor)
        #expect(calls.value == 3)
        _ = try await pipeline.fetch(descriptor)
        #expect(calls.value == 3)

        await pipeline.clear()
        _ = try await pipeline.fetch(descriptor)
        #expect(calls.value == 4)

        let transient = try makePlexDescriptor(path: "/transient", pixels: 80)
        status.withValue { $0 = 503 }
        for _ in 0..<2 {
            do { _ = try await pipeline.fetch(transient); Issue.record("Expected 503") }
            catch let error as ArtworkPipelineError { #expect(error == .httpStatus(503)) }
        }
        #expect(calls.value == 6)

        let throttled = try makePlexDescriptor(path: "/throttled", pixels: 80)
        status.withValue { $0 = 429 }
        for _ in 0..<2 {
            do { _ = try await pipeline.fetch(throttled); Issue.record("Expected 429") }
            catch let error as ArtworkPipelineError {
                #expect(error == .httpStatus(429))
                #expect(!error.isDefinitiveClientFailure)
            }
        }
        #expect(calls.value == 8)
    }

    @Test func clearDuringFlightPreventsLateCompletionFromRepopulatingCache() async throws {
        let descriptor = try makePlexDescriptor(path: "/clear-flight", pixels: 80)
        let probe = ControlledArtworkTransport()
        let pipeline = ArtworkPipeline { descriptor in try await probe.fetch(descriptor) }
        let first = Task { try await pipeline.fetch(descriptor) }
        try await probe.waitUntilStarted(count: 1)
        await pipeline.clear()

        // Clear is also a join boundary: a new consumer starts fresh even though the old consumer
        // remains allowed to finish.
        let second = Task { try await pipeline.fetch(descriptor) }
        try await probe.waitUntilStarted(count: 2)
        await probe.succeed(at: 0, data: Self.squarePNG)
        _ = try await first.value
        await probe.succeed(at: 1, data: Self.squarePNG)
        _ = try await second.value

        // Only the current-epoch completion publishes into the cache.
        _ = try await pipeline.fetch(descriptor)
        #expect(await probe.startedCount == 2)
    }

    @Test func appRuntimeInjectsOnePipelineAndPosterUsesOnlyFacade() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtime = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/App/AppRuntime.swift"), encoding: .utf8)
        #expect(runtime.contains("let artworkPipeline = ArtworkPipeline()"))

        let rootView = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/UI/RootView.swift"), encoding: .utf8)
        #expect(rootView.contains(".environment(\\.artworkPipeline, runtime.artworkPipeline)"))

        let poster = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/UI/PosterImage.swift"), encoding: .utf8)
        #expect(poster.contains("@Environment(\\.artworkPipeline)"))
        #expect(poster.contains("@Environment(\\.displayScale)"))
        #expect(poster.contains("artworkPipeline.fetch(descriptor)"))
        #expect(poster.contains("PosterLoadPublicationPolicy.canPublish"))
        #expect(poster.contains("ArtworkMeasurementTargetGate.processLifetime.claim()"))
        #expect(poster.contains(
            "accessibilityIdentifier(\"performance.mac.library-grid.first-poster.loaded\")"))
        #expect(poster.contains("fields[\"scoped\"] = 1"))
        #expect(poster.contains("fields[\"milestone\"] = \"library_first_poster\""))
        #expect(poster.contains("for attempt in 0..<3"))
        #expect(poster.contains("300 << attempt"))
        #expect(poster.contains(".easeOut(duration: 0.35)"))
        #expect(!poster.contains("URLSession.shared.data(for:"))

        let reset = try #require(poster.range(of: "loaded = nil"))
        let descriptorGuard = try #require(poster.range(of: "guard let descriptor = artworkDescriptor"))
        #expect(reset.lowerBound < descriptorGuard.lowerBound)
        let unavailableBranch = try #require(poster.range(
            of: "if artworkDescriptor == nil || artworkPipeline == nil"))
        let loadedBranch = try #require(poster.range(of: "} else if let loaded"))
        #expect(unavailableBranch.lowerBound < loadedBranch.lowerBound)

        let libraryGrid = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/UI/LibraryGridView.swift"), encoding: .utf8)
        #expect(libraryGrid.contains("artworkMeasurementRole: artworkMeasurementRole"))
        #expect(libraryGrid.contains("index == 0 ? .coldFirstPoster : nil"))
        #expect(libraryGrid.contains("#if DEBUG || PERFORMANCE_AUDIT"))

        let claim = try #require(poster.range(of:
            "ArtworkMeasurementTargetGate.processLifetime.claim()"))
        let spanStart = try #require(poster.range(of:
            "PerformanceInstrumentation.begin(.artworkLoad"))
        #expect(claim.lowerBound < spanStart.lowerBound)
        #expect(poster.contains("span.end(result: Task.isCancelled ? \"cancelled\" : \"failure\""))
    }

    @Test func posterPublicationRejectsSignOutPathRemovalStaleFailureAndPipelineReplacement() throws {
        let descriptor = try makePlexDescriptor(path: "/poster-publication", pixels: 80)
        let staleDescriptor = try makePlexDescriptor(path: "/different-poster", pixels: 80)
        let pipeline = ArtworkPipeline { _ in
            (Self.validPNG, Self.response(status: 200))
        }
        let replacementPipeline = ArtworkPipeline { _ in
            (Self.validPNG, Self.response(status: 200))
        }

        #expect(PosterLoadPublicationPolicy.canPublish(
            expectedIdentity: descriptor.taskIdentity,
            currentIdentity: descriptor.taskIdentity,
            expectedPipeline: pipeline,
            currentPipeline: pipeline,
            isCancelled: false))
        #expect(!PosterLoadPublicationPolicy.canPublish(
            expectedIdentity: descriptor.taskIdentity,
            currentIdentity: nil,
            expectedPipeline: pipeline,
            currentPipeline: pipeline,
            isCancelled: false))
        #expect(!PosterLoadPublicationPolicy.canPublish(
            expectedIdentity: descriptor.taskIdentity,
            currentIdentity: staleDescriptor.taskIdentity,
            expectedPipeline: pipeline,
            currentPipeline: pipeline,
            isCancelled: false))
        #expect(!PosterLoadPublicationPolicy.canPublish(
            expectedIdentity: descriptor.taskIdentity,
            currentIdentity: descriptor.taskIdentity,
            expectedPipeline: pipeline,
            currentPipeline: replacementPipeline,
            isCancelled: false))
        #expect(!PosterLoadPublicationPolicy.canPublish(
            expectedIdentity: descriptor.taskIdentity,
            currentIdentity: descriptor.taskIdentity,
            expectedPipeline: pipeline,
            currentPipeline: pipeline,
            isCancelled: true))
    }

    @Test func cinemaImmersiveSpaceReceivesSharedShimmerClock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Platforms/visionOS/App/Labstream.swift"), encoding: .utf8)
        #expect(app.contains(
            ".environment(\\.artworkShimmerClock, runtime.artworkShimmerClock)"))
    }

    private func executeAndCapture(_ descriptor: ArtworkRequestDescriptor) async throws -> URLRequest {
        let requests = TestLockedBox<[URLRequest]>([])
        let stub = TestURLProtocolStub { request in
            requests.withValue { $0.append(request) }
            return (Self.response(for: request, status: 200), Self.validPNG)
        }
        let pipeline = ArtworkPipeline(session: URLSession(configuration: stub.configuration))
        let result = try await pipeline.fetch(descriptor)
        #expect(result.statusCode == 200)
        #expect(result.byteCount == Self.validPNG.count)
        #expect(result.encodedData == Self.validPNG)
        #expect(result.encodedTypeIdentifier == "public.png")
        return try #require(requests.value.first)
    }

    private func waitForWaiters(_ count: Int,
                                descriptor: ArtworkRequestDescriptor,
                                pipeline: ArtworkPipeline) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await pipeline.waiterCountForTesting(descriptor.taskIdentity) < count {
            guard clock.now < deadline else { throw ArtworkTestTimeout.waiters }
            await Task.yield()
        }
    }

    private func pipelineError(_ descriptor: ArtworkRequestDescriptor,
                               status: Int,
                               data: Data) async throws -> ArtworkPipelineError {
        let stub = TestURLProtocolStub { request in
            (Self.response(for: request, status: status), data)
        }
        let pipeline = ArtworkPipeline(session: URLSession(configuration: stub.configuration))
        do {
            _ = try await pipeline.fetch(descriptor)
            Issue.record("Expected artwork pipeline failure")
            return .invalidResponse
        } catch let error as ArtworkPipelineError {
            return error
        }
    }

    private func makePlexDescriptor(path: String,
                                    pixels: Int,
                                    token: String = "token") throws
        -> ArtworkRequestDescriptor {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model, token: token)
        return try #require(MediaArtwork.descriptor(path: path,
                                                     appModel: model,
                                                     pixelWidth: pixels,
                                                     pixelHeight: pixels))
    }

    private func makeModel(activeBackend: MediaBackendKind) -> AppModel {
        AppModel(identity: ClientIdentity(clientIdentifier: "artwork-device",
                                          product: "Labstream",
                                          version: "1",
                                          deviceName: "Artwork Test"),
                 activeBackend: activeBackend)
    }

    private func applyPlex(to model: AppModel, token: String) {
        model.serverBaseURL = URL(string: "https://plex.example.test")!
        model.serverToken = token
    }

    private func applyMediaBrowser(_ backend: MediaBackendKind,
                                   to model: AppModel,
                                   token: String) {
        model.applyMediaBrowserSession(
            backend: backend,
            server: URL(string: "https://\(backend.rawValue).example.test/base")!,
            token: token,
            userID: backend == .emby ? "emby-user" : "jellyfin-user",
            serverID: "\(backend.rawValue)-server"
        )
    }

    private func queryMap(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url,
                                                         resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } })
    }

    private nonisolated static func response(for request: URLRequest,
                                             status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "image/png"])!
    }

    private nonisolated static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://artwork.example.test/image")!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "image/png"])!
    }

    private nonisolated static func makePNG(width: Int,
                                            height: Int,
                                            component: UInt8) throws -> Data {
        try makeImageData(width: width,
                          height: height,
                          component: component,
                          type: "public.png" as CFString,
                          orientation: .up)
    }

    private nonisolated static func makeImageData(
        width: Int,
        height: Int,
        component: UInt8,
        type: CFString,
        orientation: CGImagePropertyOrientation
    ) throws -> Data {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ArtworkTestImageError.creation }
        context.setFillColor(red: CGFloat(component) / 255,
                             green: CGFloat(255 - component) / 255,
                             blue: 0.5,
                             alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { throw ArtworkTestImageError.creation }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,
                                                                 type,
                                                                 1,
                                                                 nil) else {
            throw ArtworkTestImageError.creation
        }
        CGImageDestinationAddImage(destination, rendered, [
            kCGImagePropertyOrientation: orientation.rawValue,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ArtworkTestImageError.creation
        }
        return output as Data
    }

    private nonisolated static let squarePNG = try! makePNG(width: 256,
                                                            height: 256,
                                                            component: 0x66)

    private nonisolated static let validPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

private actor CancellationIgnoringArtworkTransport {
    private var started = false
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    func fetch() async throws -> (Data, URLResponse) {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !started {
            guard clock.now < deadline else { throw ArtworkTestTimeout.started }
            await Task.yield()
        }
    }

    func succeed(url: URL, data: Data) {
        let response = HTTPURLResponse(url: url,
                                       statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png"])!
        continuation?.resume(returning: (data, response))
        continuation = nil
    }
}

private enum ArtworkTestTransportFailure: Error {
    case injected
}

private enum ArtworkTestImageError: Error {
    case creation
}

private enum ArtworkTestTimeout: Error {
    case started
    case cancelled
    case waiters
}

private actor ControlledArtworkTransport {
    private var continuations:
        [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private(set) var startedIdentities: [ArtworkTaskIdentity] = []
    private(set) var cancelledTransportCount = 0
    private(set) var activeCount = 0
    private(set) var maximumActive = 0

    var startedCount: Int { startedIdentities.count }

    func fetch(_ descriptor: ArtworkRequestDescriptor) async throws -> (Data, URLResponse) {
        let identity = descriptor.taskIdentity
        let startIndex = startedIdentities.count
        startedIdentities.append(identity)
        activeCount += 1
        maximumActive = max(maximumActive, activeCount)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[startIndex] = continuation
            }
        } onCancel: {
            Task { await self.noteCancellation() }
        }
    }

    func waitUntilStarted(count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while startedIdentities.count < count {
            guard clock.now < deadline else { throw ArtworkTestTimeout.started }
            await Task.yield()
        }
    }

    func waitUntilCancelled(count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while cancelledTransportCount < count {
            guard clock.now < deadline else { throw ArtworkTestTimeout.cancelled }
            await Task.yield()
        }
    }

    func succeed(at startedIndex: Int, data: Data) {
        guard let continuation = continuations.removeValue(forKey: startedIndex) else { return }
        finish(continuation, data: data)
    }

    func succeed(identity: ArtworkTaskIdentity, data: Data) {
        guard let startedIndex = startedIdentities.indices.first(where: {
            startedIdentities[$0] == identity && continuations[$0] != nil
        }), let continuation = continuations.removeValue(forKey: startedIndex) else { return }
        finish(continuation, data: data)
    }

    private func finish(_ continuation: CheckedContinuation<(Data, URLResponse), Error>,
                        data: Data) {
        activeCount = max(0, activeCount - 1)
        continuation.resume(returning: (
            data,
            HTTPURLResponse(url: URL(string: "https://artwork.example.test/image")!,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "image/png"])!
        ))
    }

    private func noteCancellation() {
        cancelledTransportCount += 1
    }
}
