import XCTest

final class TestSupportTests: XCTestCase {
    func testTemporaryDirectoryOwnsCleanup() throws {
        let directory = try TestTemporaryDirectory(prefix: "support")
        let file = directory.url.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try directory.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.path))
    }

    func testLockedBoxAndManualClockAreDeterministic() {
        let box = TestLockedBox([1])
        box.withValue { $0.append(2) }
        XCTAssertEqual(box.value, [1, 2])

        let clock = ManualTestClock(nowNanoseconds: 10)
        clock.advance(toNanoseconds: 8)
        XCTAssertEqual(clock.nowNanoseconds, 10)
        clock.advance(byNanoseconds: 5)
        XCTAssertEqual(clock.nowNanoseconds, 15)
    }

    func testGateReleasesAllCurrentAndFutureWaiters() async {
        let gate = TestGate()
        let arrivals = TestLockedBox(0)
        let tasks = (0..<3).map { _ in
            Task {
                await gate.wait()
                arrivals.withValue { $0 += 1 }
            }
        }

        await gate.open()
        for task in tasks { await task.value }
        await gate.wait()
        XCTAssertEqual(arrivals.value, 3)
    }

    func testURLProtocolRoutesHandlersPerSession() async throws {
        let first = makeStub(body: "first")
        let second = makeStub(body: "second")
        let firstSession = URLSession(configuration: first.configuration)
        let secondSession = URLSession(configuration: second.configuration)
        defer {
            firstSession.invalidateAndCancel()
            secondSession.invalidateAndCancel()
        }
        let request = URLRequest(url: URL(string: "https://fixture.invalid/value")!)

        async let firstResult = firstSession.data(for: request)
        async let secondResult = secondSession.data(for: request)

        let (firstData, _) = try await firstResult
        let (secondData, _) = try await secondResult
        let values = [String(decoding: firstData, as: UTF8.self),
                      String(decoding: secondData, as: UTF8.self)]
        XCTAssertEqual(values, ["first", "second"])
    }

    private func makeStub(body: String) -> TestURLProtocolStub {
        TestURLProtocolStub { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
    }
}
