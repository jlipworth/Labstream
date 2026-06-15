import Foundation

extension PlexRequest {
    /// Compose the final `URLRequest` from this descriptor: merge `queryItems`
    /// into the URL, set the HTTP method, apply headers, and attach the body.
    ///
    /// Lives in PMSKit (not the app) so the wire shape is unit-testable next to
    /// the builders — load-bearing for filters whose operator rides in the query
    /// item NAME (`ratingCount>>`, `album.subformat!`) and must percent-encode.
    public func urlRequest() -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            ?? URLComponents()

        if !queryItems.isEmpty {
            // Preserve any query items already on the URL, then append ours.
            // URLComponents.queryItems leaves some reserved separators (notably `;`, `:`
            // and `/`) unescaped in query VALUES. PMS treats `;` as a query separator on
            // optimizer playlist PUTs, so titles like `Vaccine Court; ...` produce a
            // malformed request. Build the percentEncodedQuery ourselves with RFC3986
            // unreserved characters only for both names and values.
            let existing = components.percentEncodedQuery
            let encoded = queryItems
                .map { "\($0.name.plexQueryEscaped)=\(($0.value ?? "").plexQueryEscaped)" }
                .joined(separator: "&")
            components.percentEncodedQuery = [existing, encoded]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "&")
        }

        let finalURL = components.url ?? url
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        return request
    }
}


private extension String {
    var plexQueryEscaped: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
