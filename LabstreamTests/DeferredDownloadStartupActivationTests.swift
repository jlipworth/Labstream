import Foundation
import PMSKit
import Testing

@testable import Labstream

@Suite("Deferred current-store startup activation")
struct DeferredDownloadStartupActivationTests {
  @Test @MainActor
  func currentStoreDoesNotActivateSynchronouslyButSubmitsPromptly() async throws {
    try await withManager { manager, session in
      #expect(manager.startupActivationSubmissionCountForTesting == 0)
      #expect(!session.startupAdmissionIsActiveForTesting)
      #expect(manager.startupRecoveryState == .preparing)

      #expect(
        await waitUntil {
          manager.startupActivationSubmissionCountForTesting == 1
        })
      #expect(await waitUntil { session.startupAdmissionIsActiveForTesting })
      // Session admission becomes active before its completion crosses back to MainActor.
      #expect(await waitUntil { manager.startupRecoveryState == .ready })
    }
  }

  @Test @MainActor
  func pendingBackgroundHandlerIsRegisteredBeforeActivationCanSubmit() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DownloadStore(baseDirectory: directory)
    let registry = BackgroundDownloadCompletionRegistry()
    let session = BackgroundDownloadSession(
      store: store,
      protocolClasses: [],
      releaseBackgroundCompletion: { registry.fireCompletions(in: $0) }
    )
    defer { session.invalidateInjectedSessionForTesting() }
    var completionCount = 0
    registry.store(
      identifier: BackgroundDownloadSession.identifier,
      completion: { completionCount += 1 }
    )
    let manager = DownloadManager(
      appModel: makeAppModel("deferred-registration-order"),
      store: store,
      session: session,
      backgroundCompletionRegistry: registry
    )

    #expect(manager.startupActivationSubmissionCountForTesting == 0)
    #expect(session.diagnosticSnapshot().backgroundCompletionHandlerCount == 1)
    #expect(
      await waitUntil {
        manager.startupActivationSubmissionCountForTesting == 1
      })
    session.finishBackgroundEventsForTesting(
      identifier: BackgroundDownloadSession.identifier
    )
    #expect(await waitUntil { completionCount == 1 })
  }

  @Test @MainActor
  func retryBeforeDeferredTurnOwnsExactlyOneActivation() async throws {
    try await withManager { manager, session in
      #expect(manager.startupActivationSubmissionCountForTesting == 0)
      manager.retryDownloadStartupRecovery()
      #expect(manager.startupActivationSubmissionCountForTesting == 1)

      for _ in 0..<10 { await Task.yield() }
      #expect(manager.startupActivationSubmissionCountForTesting == 1)
      #expect(await waitUntil { session.startupAdmissionIsActiveForTesting })
      #expect(manager.startupRecoveryState == .ready)
    }
  }

  @Test @MainActor
  func failedAdmissionNeverSchedulesActivation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("not-json".utf8).write(to: directory.appendingPathComponent("index.json"))
    let store = DownloadStore(baseDirectory: directory)
    let session = BackgroundDownloadSession(store: store, protocolClasses: [])
    defer { session.invalidateInjectedSessionForTesting() }
    let manager = DownloadManager(
      appModel: makeAppModel("deferred-failed-admission"),
      store: store,
      session: session,
      backgroundCompletionRegistry: BackgroundDownloadCompletionRegistry()
    )

    for _ in 0..<10 { await Task.yield() }
    #expect(manager.startupActivationSubmissionCountForTesting == 0)
    #expect(!session.startupAdmissionIsActiveForTesting)
    guard case .blocked = manager.startupRecoveryState else {
      Issue.record("Unreadable startup data must remain blocked")
      return
    }
  }

  @Test @MainActor
  func pendingTurnRetainsManagerUntilItsRegisteredSessionActivates() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DownloadStore(baseDirectory: directory)
    let registry = BackgroundDownloadCompletionRegistry()
    let session = BackgroundDownloadSession(
      store: store,
      protocolClasses: [],
      releaseBackgroundCompletion: { registry.fireCompletions(in: $0) }
    )
    defer { session.invalidateInjectedSessionForTesting() }
    weak var weakManager: DownloadManager?

    do {
      let manager = DownloadManager(
        appModel: makeAppModel("deferred-deallocation"),
        store: store,
        session: session,
        backgroundCompletionRegistry: registry
      )
      weakManager = manager
      #expect(manager.startupActivationSubmissionCountForTesting == 0)
    }

    #expect(weakManager != nil)
    #expect(await waitUntil { session.startupAdmissionIsActiveForTesting })
    #expect(await waitUntil { weakManager == nil })
  }

  @MainActor
  private func withManager(
    _ body: (
      _ manager: DownloadManager,
      _ session: BackgroundDownloadSession
    ) async throws -> Void
  ) async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DownloadStore(baseDirectory: directory)
    let registry = BackgroundDownloadCompletionRegistry()
    let session = BackgroundDownloadSession(
      store: store,
      protocolClasses: [],
      releaseBackgroundCompletion: { registry.fireCompletions(in: $0) }
    )
    defer { session.invalidateInjectedSessionForTesting() }
    let manager = DownloadManager(
      appModel: makeAppModel("deferred-current-\(UUID().uuidString)"),
      store: store,
      session: session,
      backgroundCompletionRegistry: registry
    )
    try await body(manager, session)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "deferred-download-activation-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  @MainActor
  private func makeAppModel(_ identifier: String) -> AppModel {
    AppModel(identity: PlatformClientIdentity.make(clientIdentifier: identifier))
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    for _ in 0..<100 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}
