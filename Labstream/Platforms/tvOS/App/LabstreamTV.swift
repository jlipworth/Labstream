import SwiftUI

@main
struct LabstreamTV: App {
    @State private var runtime: AppRuntime?

    init() {
        guard !AppLaunchMode.isUnitTestHost else {
            _runtime = State(initialValue: nil)
            return
        }
        AppStartup.prepareForLaunch()

        let runtime = AppRuntime.make()
        _runtime = State(initialValue: runtime)
        #if DEBUG
        if let runtime {
            DebugUITestLaunchConfiguration.configure(appModel: runtime.appModel,
                                                     bootstrap: runtime.bootstrap)
        }
        TVInputEvidence.installIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let runtime {
                ContentView(runtime: runtime)
                    #if DEBUG
                    .overlay(alignment: .topTrailing) {
                        if DebugUITestLaunchConfiguration.requestsDownloadCompositionEvidence {
                            // Download sources are absent from the tvOS target, enforced by the
                            // synchronized-root topology test and the compile-input gate. This UI
                            // marker proves the streaming-only launch reaches first render.
                            Text("Streaming-only composition")
                                .font(.caption2)
                                .accessibilityIdentifier("tv.download-subsystem.absent")
                        }
                    }
                    #endif
            } else {
                SecureStorageUnavailableView()
            }
        }
    }
}
