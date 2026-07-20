import Foundation
import PMSKit
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// @MainActor because `deviceName` reads `UIDevice.current` on iOS. Every caller is a
// SwiftUI App/View init (already main-actor); the annotation makes an off-main caller a
// compile error instead of the runtime crash `MainActor.assumeIsolated` would have been.
@MainActor
enum PlatformClientIdentity {
    static var deviceName: String {
        #if os(visionOS)
        "Apple Vision Pro"
        #elseif os(tvOS)
        "Apple TV"
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #elseif os(macOS)
        HostPlatformIdentity.modelName
        #else
        "Apple Device"
        #endif
    }

    static var plexPlatform: String {
        #if os(visionOS)
        "visionOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
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


#if os(macOS)
private enum HostPlatformIdentity {
    static var modelName: String {
        var size: size_t = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = sysctlbyname("hw.model", &buffer, &size, nil, 0)
        guard result == 0 else { return "Mac" }
        let model = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return model.isEmpty ? "Mac" : model
    }
}
#endif
