import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("MediaBrowser request executor")
struct MediaBrowserRequestExecutorTests {
    private struct Payload: Decodable, Equatable {
        let value: String
    }

    private enum TransportFailure: Error, Equatable {
        case offline
    }

    @Test func decodesSuccessfulHTTPResponses() async throws {
        let executor = MediaBrowserRequestExecutor { request in
            #expect(request.url?.absoluteString == "https://media.example.test/Items")
            return (Data(#"{"value":"ok"}"#.utf8), Self.httpResponse(status: 200))
        }
        let request = URLRequest(url: URL(string: "https://media.example.test/Items")!)

        let payload = try await executor.send(request, as: Payload.self)

        #expect(payload == Payload(value: "ok"))
    }

    @Test func returnsDataForSuccessfulStatusWithoutDecoding() async throws {
        let body = Data("raw".utf8)
        let executor = MediaBrowserRequestExecutor { _ in
            (body, Self.httpResponse(status: 204))
        }
        let request = MediaBrowserRequest(URLRequest(url: URL(string: "https://media.example.test/Delete")!))

        let data = try await executor.send(request)

        #expect(data == body)
    }

    @Test func mapsAuthAndOtherHTTPFailuresToStatusError() async throws {
        for status in [401, 403, 500] {
            let executor = MediaBrowserRequestExecutor { _ in
                (Data(), Self.httpResponse(status: status))
            }
            let request = URLRequest(url: URL(string: "https://media.example.test/Items")!)

            do {
                _ = try await executor.send(request)
                Issue.record("Expected HTTP status error for \(status)")
            } catch let error as MediaBrowserRequestError {
                #expect(error == .httpStatus(status))
            }
        }
    }

    @Test func propagatesTransportFailure() async throws {
        let executor = MediaBrowserRequestExecutor { _ in
            throw TransportFailure.offline
        }
        let request = URLRequest(url: URL(string: "https://media.example.test/Items")!)

        do {
            _ = try await executor.send(request)
            Issue.record("Expected transport failure")
        } catch let error as TransportFailure {
            #expect(error == .offline)
        }
    }

    @Test func propagatesDecodeFailure() async throws {
        let executor = MediaBrowserRequestExecutor { _ in
            (Data(#"{"other":"value"}"#.utf8), Self.httpResponse(status: 200))
        }
        let request = URLRequest(url: URL(string: "https://media.example.test/Items")!)

        do {
            _ = try await executor.send(request, as: Payload.self)
            Issue.record("Expected decode failure")
        } catch is DecodingError {
            // Expected: the executor centralizes the decode call but preserves DecodingError.
        }
    }

    private static func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://media.example.test/Items")!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil)!
    }
}
