import SwiftUI
import UIKit
import PMSKit

/// Async artwork loader for Plex thumbnails / art.
///
/// Plex serves images through the photo transcoder at
/// `/photo/:/transcode?url=<encoded-image-path>&width=&height=&X-Plex-Token=`.
/// Passing the image path through the transcoder lets the server resize for us
/// (cheaper to download a poster-sized image than the full-res source).
///
/// All inputs come from `AppModel` (base URL + token). If any are missing we
/// render a neutral placeholder so the grid still lays out.
///
/// Visual polish: empty/loading state shows a soft shimmering skeleton (rather than a
/// bare spinner) and successful images fade in, so a scrolling rail never "pops" —
/// it settles. The failure/missing state shows a tasteful film glyph on a material.
struct PosterImage: View {
    /// The Plex image path, e.g. an item's `thumb` or `art` (`/library/metadata/…/thumb/…`).
    let path: String?
    /// Target render size in points; used to size the transcode request.
    var width: CGFloat = 200
    var height: CGFloat = 300
    var cornerRadius: CGFloat = DS.Radius.poster
    /// Request scale for backend image transcodes. Most posters use @2x for crispness;
    /// decorative blurred/backdrop art can opt into @1x to avoid fetching oversized images.
    var requestScale: CGFloat = 2.0

    @Environment(AppModel.self) private var appModel

    @State private var loaded: Image?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                loaded
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if failed || imageRequest == nil {
                placeholder
            } else {
                skeleton
            }
        }
        // task(id:) replaces AsyncImage, which retries NOTHING: one burst of failed
        // requests during a fast scroll left a whole grid page as permanent
        // placeholders (seen live). This loader retries transient errors with
        // backoff; a definitive 4xx (e.g. PMS's 404 for absent art) fails fast.
        .task(id: loadKey) { await load() }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            // Hairline inner edge gives the artwork a crisp, framed finish on glass.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func load() async {
        guard let request = imageRequest else { return }
        loaded = nil
        failed = false

        var attempts = 0
        var completed = false
        let span = PerformanceInstrumentation.begin(.artworkLoad,
                                                     backend: artworkBackendLabel,
                                                     fields: [
                                                        "width": Int(width),
                                                        "height": Int(height),
                                                        "pixel_width": Int(width * requestScale),
                                                        "pixel_height": Int(height * requestScale),
                                                     ])
        defer {
            if !completed {
                span.end(result: Task.isCancelled ? "cancelled" : "failure",
                         fields: ["attempts": attempts])
            }
        }

        for attempt in 0..<3 {
            attempts = attempt + 1
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(300 << attempt))
            }
            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (400..<500).contains(status) { break } // missing art — don't hammer
                guard status == 200, let ui = UIImage(data: data) else { continue }
                withAnimation(.easeOut(duration: 0.35)) { loaded = Image(uiImage: ui) }
                completed = true
                span.end(fields: [
                    "attempts": attempts,
                    "bytes": data.count,
                    "status": status,
                    "width": Int(width),
                    "height": Int(height),
                    "pixel_width": Int(width * requestScale),
                    "pixel_height": Int(height * requestScale),
                ])
                return
            } catch is CancellationError {
                return
            } catch {
                continue // transient (timeout, reset under burst load) — retry
            }
        }
        failed = true
    }

    private var artworkBackendLabel: String {
        MediaArtwork.backendLabel(for: path)
    }

    /// Neutral fallback when there's no artwork or it fails to load.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: min(width, height) * 0.22))
                    .foregroundStyle(.secondary)
            }
    }

    /// Shimmering load skeleton: a material fill with a slow sweeping highlight so a
    /// rail filling in feels alive rather than stalled.
    private var skeleton: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay { ShimmerView().clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
    }

    /// Build the `/photo/:/transcode` URL for `path` at the requested size.
    private var loadKey: String? {
        imageRequest?.url?.absoluteString
    }

    /// Authenticated request for `path` at the requested pixel size, resolved by the
    /// shared `MediaArtwork` helper (Plex transcode / Jellyfin / Emby by ref scheme).
    private var imageRequest: URLRequest? {
        MediaArtwork.imageRequest(path: path,
                                  appModel: appModel,
                                  pixelWidth: Int(width * requestScale),
                                  pixelHeight: Int(height * requestScale))
    }
}

/// A reusable animated shimmer overlay used by loading skeletons. A diagonal
/// highlight sweeps across translucently, the standard "content is on its way" cue.
struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                colors: [.clear, .white.opacity(0.18), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: w * 1.4)
            .offset(x: phase * w * 1.6)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
        .allowsHitTesting(false)
    }
}
