import Foundation
import Testing
@testable import PMSKit

@Test func plexURLQueryEncoderEscapesReservedNamesAndValues() {
    let query = PlexURLQueryEncoder.percentEncodedQuery(for: [
        .init(name: "Item[title]", value: "A; B/C:D, E"),
        .init(name: "empty", value: ""),
        .init(name: "flag", value: nil),
    ])

    #expect(query == "Item%5Btitle%5D=A%3B%20B%2FC%3AD%2C%20E&empty=&flag")
}

@Test func plexURLQueryEncoderAppendsToExistingEncodedQuery() throws {
    var components = try #require(URLComponents(string: "https://pms.example/library?existing=a%3Bb"))

    PlexURLQueryEncoder.appendQueryItems([
        .init(name: "title", value: "Vaccine Court; The Tequila Heist"),
    ], to: &components)

    #expect(components.percentEncodedQuery == "existing=a%3Bb&title=Vaccine%20Court%3B%20The%20Tequila%20Heist")
}
