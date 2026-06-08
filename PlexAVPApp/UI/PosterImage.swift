import SwiftUI
import PlexKit

/// Async artwork loader for Plex thumbnails / art.
///
/// Plex serves images through the photo transcoder at
/// `/photo/:/transcode?url=<encoded-image-path>&width=&height=&X-Plex-Token=`.
/// Passing the image path through the transcoder lets the server resize for us
/// (cheaper to download a poster-sized image than the full-res source).
///
/// All inputs come from `AppModel` (base URL + token). If any are missing we
/// render a neutral placeholder so the grid still lays out.
struct PosterImage: View {
    /// The Plex image path, e.g. an item's `thumb` or `art` (`/library/metadata/…/thumb/…`).
    let path: String?
    /// Target render size in points; used to size the transcode request.
    var width: CGFloat = 200
    var height: CGFloat = 300
    var cornerRadius: CGFloat = 12

    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if let url = transcodeURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    case .empty:
                        ZStack {
                            placeholder
                            ProgressView()
                        }
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.tertiary)
            .overlay {
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
    }

    /// Build the `/photo/:/transcode` URL for `path` at the requested size.
    private var transcodeURL: URL? {
        guard let base = appModel.serverBaseURL,
              let token = appModel.token,
              let path, !path.isEmpty
        else { return nil }

        // The image path is itself relative to the server; the transcoder wants it
        // as the `url` query value (it may be an absolute path on the same server).
        let scale = 2.0 // request at @2x for crisp posters on visionOS
        var comps = URLComponents(url: base.appendingPathComponent("/photo/:/transcode"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "url", value: path),
            .init(name: "width", value: String(Int(width * scale))),
            .init(name: "height", value: String(Int(height * scale))),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ]
        return comps?.url
    }
}
