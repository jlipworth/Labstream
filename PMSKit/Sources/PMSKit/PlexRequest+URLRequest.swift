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
            // `URLComponents.queryItems` under-encodes reserved separators that PMS may
            // parse as query delimiters, so route through the shared strict encoder.
            PlexURLQueryEncoder.appendQueryItems(queryItems, to: &components)
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
