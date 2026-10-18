#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// Exercise the enqueue adapter, not just the negotiator's decode/verdict helper.
@Suite(.serialized)
@MainActor
struct P7JoinedDownloadControlsTests {
    @Test(arguments: [false, true])
    func enqueuePreservesSelectedAudioAndRejectsMissingSource(missing: Bool) async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let requests = TestLockedBox<[URLRequest]>([])
        let stub = TestURLProtocolStub { request in
            var captured = request
            captured.httpBody = Self.bodyData(request)
            requests.withValue { $0.append(captured) }
            let body = #"{"PlaySessionId":"fixture-session","MediaSources":[{"Id":"selected","Container":"mp4","SupportsDirectPlay":true,"Size":64,"MediaStreams":[{"Type":"Audio","Index":1,"Codec":"aac"},{"Type":"Audio","Index":3,"Codec":"dts"}]}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil)!, Data(body.utf8))
        }
        let transport = URLSession(configuration: stub.configuration)
        defer { transport.invalidateAndCancel() }
        configure(f.manager, transport: transport)
        f.manager.setQueuePausedForTesting(true)
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(
            #"{"ratingKey":"joined","title":"Fixture","type":"movie","Media":[{"id":1,"container":"mp4","Part":[{"id":1,"key":"/media/selected","container":"mp4","Stream":[]}]}]}"#.utf8))
        await f.manager.downloadEmby(item, choice: .original, audioStreamIndex: 3,
            mediaSourceIDOverride: missing ? "missing" : "selected", deferStaticStartWhenQueuePaused: true)
        let row = try #require(f.store.record(for: "emby:joined"))
        #expect(row.metadata?.audioStreamIndex == 3)
        if missing {
            #expect(row.status == .failed)
            #expect(f.manager.lastError[row.ratingKey] != nil)
        } else {
            #expect(row.status == .paused)
            #expect(row.metadata?.mediaSourceID == "selected")
            #expect(row.localURL.pathExtension == "mp4")
        }
        let negotiation = try #require(requests.value.first { $0.url?.path.hasSuffix("/PlaybackInfo") == true })
        let data = try #require(negotiation.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["AudioStreamIndex"] as? Int == 3)
        #expect(payload["MediaSourceId"] as? String == (missing ? "missing" : "selected"))
        #expect(!requests.value.contains { $0.url?.path.contains("/stream.") == true })
        await f.finish()
    }

    @Test func enqueueRetainsExistingStaticExtensionAcrossSeedReplacement() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let negotiations = TestLockedBox(0)
        let stub = TestURLProtocolStub { request in
            if request.url?.path.hasSuffix("/PlaybackInfo") == true {
                negotiations.withValue { $0 += 1 }
            }
            let body = #"{"PlaySessionId":"fixture-session","MediaSources":[{"Id":"selected","Container":"mp4","SupportsDirectPlay":true,"Size":64,"MediaStreams":[]}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil)!, Data(body.utf8))
        }
        let transport = URLSession(configuration: stub.configuration)
        defer { transport.invalidateAndCancel() }
        configure(f.manager, transport: transport)
        f.manager.setQueuePausedForTesting(true)
        var previous = f.files.record("previous", status: .failed, ratingKey: "emby:joined", filename: "joined.m4v")
        previous.metadata?.backendKind = .emby
        previous.metadata?.backendBaseURLString = "https://media.invalid"
        previous.metadata?.backendServerID = "fixture-server"
        previous.metadata?.backendUserID = "fixture-user"
        previous.metadata?.downloadLane = .original
        previous.metadata?.mediaSourceID = "selected"
        #expect(await f.store.createAttemptOwnedRecordAsync(previous, attemptID: previous.attemptID!)
            == .committed(.init(ratingKey: previous.ratingKey, attemptID: previous.attemptID!)))
        let item = MediaItem(ratingKey: "joined", title: "Fixture", type: "movie")
        await f.manager.downloadEmby(item, choice: .original, mediaSourceIDOverride: "selected",
            deferStaticStartWhenQueuePaused: true)
        let retried = try #require(f.store.record(for: previous.ratingKey))
        #expect(negotiations.value == 1)
        #expect(retried.attemptID != previous.attemptID)
        #expect(retried.localURL.pathExtension == "m4v")
        #expect(retried.status == .paused)
        #expect(retried.metadata?.resolvedResumeMode(ratingKey: retried.ratingKey) == .staticByteRange)
        await f.finish()
    }

    nonisolated private static func bodyData(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func configure(_ manager: DownloadManager, transport: URLSession) {
        manager.appModel.embyServerBaseURL = URL(string: "https://media.invalid")!
        manager.appModel.embyAccessToken = "fixture"
        manager.appModel.embyUserID = "fixture-user"
        manager.appModel.embyServerID = "fixture-server"
        manager.embyConvertSession = transport
    }
}
#endif
