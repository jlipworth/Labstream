import Testing
@testable import PMSKit

@Test func versionExists() {
    // Don't hard-code the version literal — that couples this suite to every release bump
    // (the bump-version skill would have to edit it too). Assert the constant is present
    // and semver-shaped instead.
    #expect(PMSKit.version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
}
