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
                    .reportsAppSceneActivity(runtime.sceneActivity, role: .mainWindow)
            } else {
                SecureStorageUnavailableView()
            }
        }
    }
}
