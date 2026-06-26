import Foundation

/// Build/runtime gate for the legacy file fallback used only when developing unsigned
/// simulator builds whose Keychain entitlement path is unavailable.
public struct SecretFileFallbackPolicy: Sendable, Equatable {
    public enum BuildConfiguration: Sendable, Equatable {
        case debug
        case release
    }

    public enum RuntimeEnvironment: Sendable, Equatable {
        case simulator
        case device
    }

    public let buildConfiguration: BuildConfiguration
    public let runtimeEnvironment: RuntimeEnvironment

    public init(buildConfiguration: BuildConfiguration,
                runtimeEnvironment: RuntimeEnvironment) {
        self.buildConfiguration = buildConfiguration
        self.runtimeEnvironment = runtimeEnvironment
    }

    /// File-backed secrets are allowed only for DEBUG simulator workflows. Release
    /// builds and physical devices must fail closed rather than persist credentials
    /// outside Keychain.
    public var allowsSecretFileFallback: Bool {
        buildConfiguration == .debug && runtimeEnvironment == .simulator
    }

    public static var current: SecretFileFallbackPolicy {
        #if DEBUG
        let build: BuildConfiguration = .debug
        #else
        let build: BuildConfiguration = .release
        #endif

        #if targetEnvironment(simulator)
        let runtime: RuntimeEnvironment = .simulator
        #else
        let runtime: RuntimeEnvironment = .device
        #endif

        return SecretFileFallbackPolicy(buildConfiguration: build,
                                        runtimeEnvironment: runtime)
    }
}

/// Shared hardening for auth-adjacent artifacts that must remain in the app
/// container, such as URLSession resume blobs or DEBUG-only credential fallback files.
public enum CredentialArtifactStorage {
    /// Background-download-friendly protection: encrypted before first unlock,
    /// available after the user has unlocked once so resumable downloads do not
    /// become unusable merely because the device later locks.
    public static let authArtifactProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    /// DEBUG simulator fallback secrets are not needed by background daemons; use
    /// stronger protection when the platform supports it.
    public static let credentialFallbackProtection: FileProtectionType = .complete

    public static func writeAuthArtifact(_ data: Data, to url: URL,
                                         fileManager: FileManager = .default) throws {
        try write(data, to: url, protection: authArtifactProtection, fileManager: fileManager)
    }

    public static func writeCredentialFallback(_ data: Data, to url: URL,
                                               fileManager: FileManager = .default) throws {
        try write(data, to: url, protection: credentialFallbackProtection, fileManager: fileManager)
    }

    public static func write(_ data: Data, to url: URL,
                             protection: FileProtectionType,
                             fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: writingOptions(for: protection))
            try applyProtectionAndBackupExclusion(to: url, protection: protection, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    public static func applyProtectionAndBackupExclusion(to url: URL,
                                                         protection: FileProtectionType,
                                                         fileManager: FileManager = .default) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    }

    public static func writingOptions(for protection: FileProtectionType) -> Data.WritingOptions {
        if protection == .complete { return [.atomic, .completeFileProtection] }
        if protection == .completeUnlessOpen { return [.atomic, .completeFileProtectionUnlessOpen] }
        if protection == .completeUntilFirstUserAuthentication {
            return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        }
        if protection == .none { return [.atomic, .noFileProtection] }
        return [.atomic]
    }
}
