import Foundation
import SwiftUI

@main
struct LabstreamMobile: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let runtime {
                ContentView(runtime: runtime)
                    // One switch style app-wide: amber on state, never system green.
                    .toggleStyle(LabstreamSwitchToggleStyle())
                    // The single foldable-pose and vertical-bar-edge source for every surface.
                    .providesDuoPose()
                    .reportsAppSceneActivity(runtime.sceneActivity, role: .mainWindow)
                    // DEBUG-only capture route for folded-landscape evidence (no-op otherwise).
                    .debugCaptureOrientation()
            } else {
                SecureStorageUnavailableView()
            }
        }
    }
}
