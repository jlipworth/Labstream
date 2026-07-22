#if !os(tvOS)
import Foundation
import Testing
@testable import Labstream

@Suite("Download planning request executor")
struct DownloadPlanningRequestExecutorTests {
    @Test("injected operation receives the exact authenticated request")
    func injectedOperationPreservesRequest() async throws {
        let received = TestLockedBox<URLRequest?>(nil)
        let expectedData = Data("planned".utf8)
        let url = try #require(URL(string: "https://media.example.test/Items/123/PlaybackInfo?api_key=secret"))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        let executor = DownloadPlanningRequestExecutor { request in
            received.withValue { $0 = request }
            return (expectedData, response)
        }
        var request = URLRequest(url: url, timeoutInterval: 17)
        request.httpMethod = "POST"
        request.setValue("MediaBrowser Token=secret", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"probe\":true}".utf8)

        let (data, returnedResponse) = try await executor.data(for: request)

        let captured = try #require(received.value)
        #expect(captured.url == request.url)
        #expect(captured.httpMethod == request.httpMethod)
        #expect(captured.allHTTPHeaderFields == request.allHTTPHeaderFields)
        #expect(captured.timeoutInterval == request.timeoutInterval)
        #expect(captured.httpBody == request.httpBody)
        #expect(data == expectedData)
        #expect((returnedResponse as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("production configuration has no persistent ambient authority")
    func productionConfigurationIsNonpersistent() {
        let configuration = DownloadPlanningRequestExecutor.authenticatedEphemeralConfiguration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test("production session installs the redirect authority policy")
    func productionSessionInstallsRedirectPolicy() {
        let session = DownloadPlanningRequestExecutor.authenticatedEphemeralSession()

        #expect(session.delegate is DownloadPlanningRedirectDelegate)
    }

    @Test("redirect policy permits only same-origin semantic-preserving redirects")
    func redirectPolicyIsOriginAndSemanticSafe() throws {
        let source = try #require(URL(string: "https://media.example.test/playback"))
        var original = URLRequest(url: source)
        original.httpMethod = "POST"
        original.httpBody = Data("probe".utf8)
        original.setValue("secret", forHTTPHeaderField: "X-Emby-Token")
        let response = try #require(HTTPURLResponse(
            url: source, statusCode: 307, httpVersion: nil, headerFields: nil))
        let rewritingResponse = try #require(HTTPURLResponse(
            url: source, statusCode: 302, httpVersion: nil, headerFields: nil))
        var safe = original
        safe.url = try #require(URL(string: "https://media.example.test/new-playback"))
        var crossOrigin = safe
        crossOrigin.url = try #require(URL(string: "https://other.example.test/new-playback"))
        var changedMethod = safe
        changedMethod.httpMethod = "GET"

        #expect(DownloadPlanningRedirectDelegate.allowedRedirect(
            from: original, response: response, to: safe))
        #expect(!DownloadPlanningRedirectDelegate.allowedRedirect(
            from: original, response: response, to: crossOrigin))
        #expect(!DownloadPlanningRedirectDelegate.allowedRedirect(
            from: original, response: response, to: changedMethod))
        #expect(!DownloadPlanningRedirectDelegate.allowedRedirect(
            from: original, response: rewritingResponse, to: safe))
    }

    @Test("planner has no ambient shared-session escape hatch")
    func plannerUsesInjectedBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Capabilities/Downloads/Core/DownloadItemPlanner.swift"), encoding: .utf8)

        #expect(!source.contains("URLSession.shared"))
        #expect(source.contains("requestExecutor.data(for:"))
    }
}
#endif
