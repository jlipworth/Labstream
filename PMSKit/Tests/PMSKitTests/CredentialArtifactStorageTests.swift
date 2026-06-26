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

@Test("auth artifact writer excludes persisted files from backup")
func authArtifactWriterExcludesPersistedFilesFromBackup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CredentialArtifactStorageTests-")
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("resume.resume")
    let data = Data("resume-data".utf8)
    try CredentialArtifactStorage.writeAuthArtifact(data, to: url)

    #expect(try Data(contentsOf: url) == data)
    let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.protectionKey] as? FileProtectionType == CredentialArtifactStorage.authArtifactProtection)
}

@Test("credential fallback writer uses complete protection")
func credentialFallbackWriterUsesCompleteProtection() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CredentialArtifactStorageTests-")
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("secret")
    try CredentialArtifactStorage.writeCredentialFallback(Data("secret".utf8), to: url)

    let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.protectionKey] as? FileProtectionType == CredentialArtifactStorage.credentialFallbackProtection)
}
