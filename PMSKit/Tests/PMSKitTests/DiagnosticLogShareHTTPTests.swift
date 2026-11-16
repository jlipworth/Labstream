import XCTest
@testable import PMSKit

final class DiagnosticLogShareHTTPTests: XCTestCase {
    private let token = "0123456789abcdef"
    private let payload = DiagnosticLogShareHTTP.Payload(
        reportText: "Labstream diagnostic report\nline two\n",
        eventLog: Data("{\"name\":\"a\"}\n{\"name\":\"b\"}\n".utf8))

    private func respond(_ requestLine: String,
                         payload: DiagnosticLogShareHTTP.Payload? = nil) -> DiagnosticLogShareHTTP.Response {
        DiagnosticLogShareHTTP.respond(toRequestHead: requestLine + "\r\nHost: 192.0.2.10:5000\r\n\r\n",
                                       token: token, payload: payload ?? self.payload)
    }

    func testPageLinksBothDownloadsUnderTheToken() throws {
        for path in ["/\(token)", "/\(token)/"] {
            let response = respond("GET \(path) HTTP/1.1")
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.served, .page)
            XCTAssertEqual(response.header("Content-Type"), "text/html; charset=utf-8")
            let html = try XCTUnwrap(String(data: response.body, encoding: .utf8))
            XCTAssertTrue(html.contains("href=\"/\(token)/report.txt\""))
            XCTAssertTrue(html.contains("href=\"/\(token)/events.jsonl\""))
            XCTAssertTrue(html.contains("2 events"))
        }
    }

    func testPageOmitsEventLogLinkWhenNothingWasRecorded() throws {
        let empty = DiagnosticLogShareHTTP.Payload(reportText: "report", eventLog: Data())
        let html = try XCTUnwrap(String(data: respond("GET /\(token)/ HTTP/1.1", payload: empty).body,
                                        encoding: .utf8))
        XCTAssertFalse(html.contains("events.jsonl"))
        XCTAssertTrue(html.contains("Turn on diagnostic logging"))
    }

    func testReportDownloadsAsAnAttachment() {
        let response = respond("GET /\(token)/report.txt HTTP/1.1")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.served, .report)
        XCTAssertEqual(response.body, Data(payload.reportText.utf8))
        XCTAssertEqual(response.header("Content-Disposition"),
                       "attachment; filename=\"Labstream-Diagnostic-Report.txt\"")
        XCTAssertEqual(response.header("Cache-Control"), "no-store")
    }

    func testEventLogDownloadsAsAnAttachment() {
        let response = respond("GET /\(token)/events.jsonl?x=1 HTTP/1.1")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.served, .eventLog)
        XCTAssertEqual(response.body, payload.eventLog)
        XCTAssertEqual(response.header("Content-Disposition"),
                       "attachment; filename=\"Labstream-Diagnostic-Events.jsonl\"")
    }

    func testAnythingOutsideTheTokenIsNotFound() {
        for path in ["/", "/report.txt", "/fedcba9876543210/report.txt", "/\(token)x/",
                     "/\(token)/other", "/\(token)/report.txt/extra", "/\(token)/../report.txt"] {
            let response = respond("GET \(path) HTTP/1.1")
            XCTAssertEqual(response.status, 404, path)
            XCTAssertNil(response.served, path)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("diagnostic report"), path)
        }
    }

    func testAnEmptyTokenServesNothing() {
        let response = DiagnosticLogShareHTTP.respond(toRequestHead: "GET / HTTP/1.1\r\n\r\n",
                                                      token: "", payload: payload)
        XCTAssertEqual(response.status, 404)
    }

    func testOtherMethodsAndMalformedRequestsAreRejected() {
        XCTAssertEqual(respond("POST /\(token)/report.txt HTTP/1.1").status, 405)
        XCTAssertEqual(respond("POST /\(token)/report.txt HTTP/1.1").header("Allow"), "GET, HEAD")
        XCTAssertEqual(respond("GET /\(token)/report.txt").status, 400)
        XCTAssertEqual(respond("").status, 400)
        XCTAssertEqual(respond("GET /\(token)/ SPDY/3").status, 400)
    }

    func testSerializedResponseHasLengthAndClosesTheConnection() throws {
        let response = respond("GET /\(token)/report.txt HTTP/1.1")
        let wire = String(decoding: response.serialized(), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("\r\nContent-Length: \(response.body.count)\r\n"))
        XCTAssertTrue(wire.contains("\r\nConnection: close\r\n\r\n"))
        XCTAssertTrue(wire.hasSuffix(payload.reportText))

        let head = String(decoding: response.serialized(includeBody: false), as: UTF8.self)
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(head.contains("Content-Length: \(response.body.count)"))
        XCTAssertTrue(DiagnosticLogShareHTTP.isHeadRequest("HEAD /x HTTP/1.1\r\n\r\n"))
        XCTAssertFalse(DiagnosticLogShareHTTP.isHeadRequest("GET /x HTTP/1.1\r\n\r\n"))
    }

    func testHeadCompletionAndTokenShape() {
        XCTAssertFalse(DiagnosticLogShareHTTP.hasCompleteHead(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
        XCTAssertTrue(DiagnosticLogShareHTTP.hasCompleteHead(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))

        let tokens = Set((0..<50).map { _ in DiagnosticLogShareHTTP.makeToken() })
        XCTAssertEqual(tokens.count, 50)
        for token in tokens {
            XCTAssertEqual(token.count, 16)
            XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }
}
