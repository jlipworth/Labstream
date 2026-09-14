#if canImport(Network)
import Foundation
import XCTest
@testable import PMSKit

final class P7HDR10TransportTests: XCTestCase {
    func testBoundedFetchReadsWithinLimitAndRejectsOversizedResponse() async throws {
        let origin = LoopbackOrigin()
        let port = try await origin.start { head in
            HTTPResponse(status: 200, reason: "OK", headers: [],
                         body: Data(repeating: 7, count: head.target == "/small" ? 16 : 1024))
        }
        defer { origin.stop() }
        let box = SessionBox(config: .ephemeral, delegate: nil)
        let attempt = box.makeAttempt()
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/small")!)
        let (data, response) = try await attempt.response(for: request, maximumBytes: 16)
        XCTAssertEqual(data.count, 16)
        XCTAssertEqual(response.statusCode, 200)
        let large = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/large")!)
        do {
            _ = try await attempt.response(for: large, maximumBytes: 16)
            XCTFail("oversized metadata accepted")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
    }

    func testBoundedMetadataDoesNotFollowRedirect() async throws {
        let origin = LoopbackOrigin()
        let port = try await origin.start { _ in
            HTTPResponse(status: 302, reason: "Found", headers: [("Location", "/redirected")], body: Data())
        }
        defer { origin.stop() }
        let box = SessionBox(config: .ephemeral, delegate: nil)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/init.mp4")!)
        let (_, response) = try await box.makeAttempt().response(for: request, maximumBytes: 1024)
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.url, request.url)
    }
    func testCandidateSegmentsCannotRedirectCredentialsEither() async throws {
        let origin = LoopbackOrigin()
        let port = try await origin.start { _ in
            HTTPResponse(status: 302, reason: "Found", headers: [("Location", "/redirected")], body: Data())
        }
        defer { origin.stop() }
        let box = SessionBox(config: .ephemeral, delegate: nil, rejectRedirects: true)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/segment.m4s")!)
        let (_, response) = try await box.makeAttempt().response(for: request, maximumBytes: nil)
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.url, request.url)
    }

}
#endif
