import Foundation
import PMSKit
import Testing
@testable import Labstream

struct SystemEntryRouterTests {
    private actor ReadinessSleeper {
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var callCount = 0
        private var hasEntered = false

        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func sleep(for _: Duration) async throws {
            callCount += 1
            if !hasEntered {
                hasEntered = true
                let waiters = entryWaiters
                entryWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }

            // Keep the first readiness wait suspended until the test cancels it. This is still
            // a real cancellable sleep, but it cannot naturally finish while a loaded executor
            // delays the test task after the entry handshake.
            try await Task.sleep(for: .seconds(30))
        }
    }

    @Test func cancellationEndsReadinessWaitWithoutSpinning() async {
        let sleeper = ReadinessSleeper()
        let router = await MainActor.run {
            SystemEntryRouter { duration in
                try await sleeper.sleep(for: duration)
            }
        }
        let wait = Task { @MainActor in
            await router.ensureBrowseReady(timeout: .seconds(10))
        }

        await sleeper.waitUntilEntered()
        wait.cancel()

        #expect(await wait.value == false)
        #expect(await sleeper.callCount == 1)
    }
}

#if os(macOS)
extension SystemEntryRouterTests {
    @Test @MainActor
    func macSystemEntriesActivateTheUniqueMainWindowExactlyOncePerRoute() {
        let router = SystemEntryRouter()
        var activationCount = 0
        router.registerMainWindowActivation { activationCount += 1 }

        router.open(ratingKey: "movie-1", autoPlay: false)
        #expect(activationCount == 1)

        let item = MediaItem(ratingKey: "movie-2", title: "Movie 2", type: "movie")
        router.open(item: item, autoPlay: true)
        #expect(activationCount == 2)
    }
}
#endif
