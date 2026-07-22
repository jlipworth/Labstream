import SwiftUI
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
    /// Optional request-scale override. Ordinary posters use the environment's actual display
    /// scale; decorative blurred/backdrop art can retain its explicit @1x request.
    var requestScale: CGFloat? = nil
    /// SF Symbol shown when there's no artwork (or it fails). Defaults to the film glyph
    /// for video posters; music cells pass a `music.*` glyph so an art-less artist/album
    /// reads as "no cover" rather than "broken" (#111).
    var placeholderSymbol: String = "film"

    @Environment(AppModel.self) private var appModel
    @Environment(\.artworkPipeline) private var artworkPipeline
    @Environment(\.displayScale) private var displayScale

    @State private var loaded: Image?
    @State private var failed = false

    var body: some View {
        Group {
            // Hide old pixels immediately on sign-out, path removal, or facade loss; do not wait
            // for the replacement task to run and clear state.
            if artworkDescriptor == nil || artworkPipeline == nil {
                placeholder
            } else if let loaded {
                loaded
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if failed {
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
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func load() async {
        loaded = nil
        failed = false
        guard let descriptor = artworkDescriptor,
              let artworkPipeline else { return }

        var attempts = 0
        var completed = false
        let span = PerformanceInstrumentation.begin(.artworkLoad,
                                                     backend: artworkBackendLabel,
                                                     fields: [
                                                        "width": Int(width),
                                                        "height": Int(height),
                                                        "pixel_width": pixelDimensions.width,
                                                        "pixel_height": pixelDimensions.height,
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
                let response = try await artworkPipeline.fetch(descriptor)
                try Task.checkCancellation()
                // `.task(id:)` requests cancellation when identity changes, but the transport may
                // not cooperate. Fence publication against the exact current backend authority,
                // purpose, source, and size as well as the Task cancellation bit.
                guard PosterLoadPublicationPolicy.canPublish(
                    expectedIdentity: descriptor.taskIdentity,
                    currentIdentity: artworkDescriptor?.taskIdentity,
                    expectedPipeline: artworkPipeline,
                    currentPipeline: self.artworkPipeline,
                    isCancelled: Task.isCancelled) else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    loaded = Image(decodedImage: response.image)
                }
                completed = true
                #if DEBUG || PERFORMANCE_AUDIT
                span.end(fields: [
                    "attempts": attempts,
                    "bytes": response.byteCount,
                    "status": response.statusCode,
                    "width": Int(width),
                    "height": Int(height),
                    "pixel_width": pixelDimensions.width,
                    "pixel_height": pixelDimensions.height,
                    "delivery": response.delivery.rawValue,
                ])
                #else
                span.end(fields: [
                    "attempts": attempts,
                    "bytes": response.byteCount,
                    "status": response.statusCode,
                    "width": Int(width),
                    "height": Int(height),
                    "pixel_width": pixelDimensions.width,
                    "pixel_height": pixelDimensions.height,
                ])
                #endif
                return
            } catch is CancellationError {
                return
            } catch let error as ArtworkPipelineError where error.isDefinitiveClientFailure {
                break // missing/forbidden art — don't hammer
            } catch {
                continue // transient (timeout, reset under burst load) — retry
            }
        }
        guard PosterLoadPublicationPolicy.canPublish(
            expectedIdentity: descriptor.taskIdentity,
            currentIdentity: artworkDescriptor?.taskIdentity,
            expectedPipeline: artworkPipeline,
            currentPipeline: self.artworkPipeline,
            isCancelled: Task.isCancelled) else { return }
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
                Image(systemName: placeholderSymbol)
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
    private var loadKey: PosterLoadKey {
        PosterLoadKey(identity: artworkDescriptor?.taskIdentity,
                      pipelineIdentity: artworkPipeline.map(ObjectIdentifier.init))
    }

    /// Authenticated, non-loggable descriptor for `path` at the requested pixel size.
    private var artworkDescriptor: ArtworkRequestDescriptor? {
        MediaArtwork.descriptor(path: path,
                                appModel: appModel,
                                pixelWidth: pixelDimensions.width,
                                pixelHeight: pixelDimensions.height)
    }

    private var pixelDimensions: (width: Int, height: Int) {
        MediaArtwork.pixelDimensions(width: width,
                                     height: height,
                                     displayScale: displayScale,
                                     requestScale: requestScale)
    }
}

private struct PosterLoadKey: Hashable {
    let identity: ArtworkTaskIdentity?
    let pipelineIdentity: ObjectIdentifier?
}

/// Pure publication fence shared by success and terminal failure. Cancellation is advisory for
/// transports, so publication also requires the exact current descriptor and facade instance.
enum PosterLoadPublicationPolicy {
    static func canPublish(expectedIdentity: ArtworkTaskIdentity,
                           currentIdentity: ArtworkTaskIdentity?,
                           expectedPipeline: ArtworkPipeline,
                           currentPipeline: ArtworkPipeline?,
                           isCancelled: Bool) -> Bool {
        !isCancelled
            && currentIdentity == expectedIdentity
            && currentPipeline === expectedPipeline
    }
}

/// A reusable animated shimmer overlay used by loading skeletons. A diagonal
/// highlight sweeps across translucently, the standard "content is on its way" cue.
struct ShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.artworkShimmerClock) private var shimmerClock
    @State private var subscribedClock: ArtworkShimmerClock?
    @State private var subscription: ArtworkShimmerClock.Subscription?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            if !reduceMotion, let shimmerClock {
                shimmerGradient(highlightOpacity: 0.18)
                .frame(width: w * 1.4)
                .offset(x: shimmerClock.phase * w * 1.6)
            } else {
                shimmerGradient(highlightOpacity: 0.10)
                .frame(width: w * 1.4)
                .offset(x: -0.2 * w)
            }
        }
        .allowsHitTesting(false)
        .onAppear { updateSubscription() }
        .onDisappear { releaseSubscription() }
        .onChange(of: reduceMotion) { _, _ in updateSubscription() }
    }

    private func shimmerGradient(highlightOpacity: Double) -> LinearGradient {
        LinearGradient(
            colors: [.clear, .white.opacity(highlightOpacity), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func updateSubscription() {
        if subscribedClock !== shimmerClock || reduceMotion {
            releaseSubscription()
        }
        guard subscription == nil, let shimmerClock else { return }
        subscription = shimmerClock.subscribe(reduceMotion: reduceMotion)
        if subscription != nil {
            subscribedClock = shimmerClock
        }
    }

    private func releaseSubscription() {
        if let subscription {
            subscribedClock?.unsubscribe(subscription)
        }
        subscription = nil
        subscribedClock = nil
    }
}
