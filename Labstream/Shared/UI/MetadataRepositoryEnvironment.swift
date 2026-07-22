import SwiftUI

private struct MetadataRepositoryEnvironmentKey: EnvironmentKey {
    static let defaultValue: MetadataRepository? = nil
}

extension EnvironmentValues {
    /// Optional so isolated previews/fixtures retain their direct-read fallback. Every shipping
    /// RootView injects AppRuntime's single app-lifetime repository.
    var metadataRepository: MetadataRepository? {
        get { self[MetadataRepositoryEnvironmentKey.self] }
        set { self[MetadataRepositoryEnvironmentKey.self] = newValue }
    }
}
