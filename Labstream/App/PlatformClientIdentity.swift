import Foundation
import PMSKit
#if os(iOS) || os(visionOS)
import UIKit
#endif

// @MainActor because `deviceName` reads `UIDevice.current` on iOS. Every caller is a
// SwiftUI App/View init (already main-actor); the annotation makes an off-main caller a
// compile error instead of the runtime crash `MainActor.assumeIsolated` would have been.
@MainActor
enum PlatformClientIdentity {
    static var deviceName: String {
        #if os(visionOS)
        "Apple Vision Pro"
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Apple Device"
        #endif
    }

    static var plexPlatform: String {
        #if os(visionOS)
        "visionOS"
        #elseif os(iOS)
        "iOS"
        #else
        "Apple"
        #endif
    }

    static func make(clientIdentifier: String,
                     product: String = "Labstream",
                     version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0") -> ClientIdentity {
        ClientIdentity(clientIdentifier: clientIdentifier,
                       product: product,
                       version: version,
                       deviceName: deviceName,
                       platform: plexPlatform,
                       device: deviceName)
    }
}
