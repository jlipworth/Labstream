import Foundation
import Testing
@testable import PMSKit

@Test("secret file fallback policy is DEBUG simulator only")
func secretFileFallbackPolicyIsDebugSimulatorOnly() {
    #expect(SecretFileFallbackPolicy(buildConfiguration: .debug,
                                     runtimeEnvironment: .simulator).allowsSecretFileFallback)
    #expect(!SecretFileFallbackPolicy(buildConfiguration: .debug,
                                      runtimeEnvironment: .device).allowsSecretFileFallback)
    #expect(!SecretFileFallbackPolicy(buildConfiguration: .release,
                                      runtimeEnvironment: .simulator).allowsSecretFileFallback)
    #expect(!SecretFileFallbackPolicy(buildConfiguration: .release,
                                      runtimeEnvironment: .device).allowsSecretFileFallback)
}

enum CredentialArtifactWriter: String, CaseIterable, Sendable {
    case authArtifact
    case credentialFallback

    var fileName: String {
        switch self {
        case .authArtifact: "resume.resume"
        case .credentialFallback: "secret"
        }
    }

    var expectedProtection: FileProtectionType {
        switch self {
        case .authArtifact: .completeUntilFirstUserAuthentication
        case .credentialFallback: .complete
        }
    }

    func write(_ data: Data, to url: URL) throws {
        switch self {
        case .authArtifact: try CredentialArtifactStorage.writeAuthArtifact(data, to: url)
        case .credentialFallback: try CredentialArtifactStorage.writeCredentialFallback(data, to: url)
        }
    }
}

@Test("credential artifact writers exclude persisted files from backup and apply their protection class",
      arguments: CredentialArtifactWriter.allCases)
func credentialArtifactWriterExcludesFromBackupAndAppliesProtection(writer: CredentialArtifactWriter) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CredentialArtifactStorageTests-")
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent(writer.fileName)
    let data = Data("\(writer.rawValue)-data".utf8)
    try writer.write(data, to: url)

    #expect(try Data(contentsOf: url) == data)
    #if canImport(Darwin)
    let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
    if CredentialArtifactStorage.supportsFileProtectionAttributes {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = try #require(attributes[.protectionKey] as? FileProtectionType)
        #expect(protection == writer.expectedProtection)
    }
    #endif
}
