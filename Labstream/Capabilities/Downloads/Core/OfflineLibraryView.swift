import SwiftUI
import PMSKit

/// Lists offline downloads with live progress + delete, and plays a completed
/// file through the custom player (`CustomPlayerView(localFile:item:)`).
///
/// Surfaces the offline-transfer reality (research/10): background transfers may be
/// deferred while the app is backgrounded or the device is locked/asleep, then resume
/// when the app or system transfer daemon is allowed to run again.
public struct OfflineLibraryView: View {
    @Environment(MusicPlayerController.self) private var musicPlayer
    @Environment(\.labstreamCompactWidth) private var compactWidth
    #if os(macOS)
    @Environment(\.macPlayerPresentationStore) private var macPlayerPresenter
    #endif
    @State private var manager: DownloadManager
    @State private var playing: DownloadRecord?
    #if os(iOS)
    @State private var mobilePlayerOrientationCoordinator = MobilePlayerOrientationCoordinator()
    #endif
    #if os(visionOS)
    @Binding private var focusedRatingKey: String?
    @State private var highlightedRatingKey: String?
    #endif
    @State private var pendingDeletion: PendingOfflineDeletion?
    #if os(macOS)
    @State private var macPlayerPresentationOwnerID = UUID()
    #endif

    #if os(visionOS)
    public init(manager: DownloadManager, focusedRatingKey: Binding<String?> = .constant(nil)) {
        _manager = State(initialValue: manager)
        _focusedRatingKey = focusedRatingKey
    }
    #else
    public init(manager: DownloadManager) {
        _manager = State(initialValue: manager)
    }
    #endif

    public var body: some View {
        platformPresentedContent
            .confirmationDialog(
                pendingDeletion?.dialogTitle ?? "Delete download?",
                isPresented: deletionDialogIsPresented,
                titleVisibility: .visible
            ) {
                deletionDialogActions
            } message: {
                deletionDialogMessage
            }
    }

    private var offlineNavigationContent: some View {
        let snapshot = manager.offlineLibrarySnapshot

        // No NavigationStack here: RootView already wraps the Offline tab in one on every
        // platform, so opening a second stack nested large-title collapse and toolbar merging.
        // The navigationTitle/toolbar below attach to this content and merge into the outer stack.
        return ScrollViewReader { scrollProxy in
            navigableOfflineContent(snapshot: snapshot, scrollProxy: scrollProxy)
        }
    }

    private func navigableOfflineContent(
        snapshot: OfflineLibrarySnapshot,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        VStack(spacing: 0) {
            if case .blocked(let message) = manager.startupRecoveryState {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    Text(message)
                        .font(.callout)
                    Spacer()
                    Button("Retry Recovery") { manager.retryDownloadStartupRecovery() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .accessibilityElement(children: .combine)
            }
            offlineRowsOrEmpty(snapshot: snapshot)
        }
            .navigationTitle("Offline")
            .toolbar { offlineToolbar(snapshot: snapshot) }
            #if os(visionOS)
            .task(id: focusedRatingKey) { await focusRequestedDownload(using: scrollProxy) }
            .onChange(of: snapshot.ratingKeys) { _, _ in
                Task { @MainActor in await focusRequestedDownload(using: scrollProxy) }
            }
            #endif
    }

    @ViewBuilder
    private func offlineRowsOrEmpty(snapshot: OfflineLibrarySnapshot) -> some View {
        if snapshot.rows.isEmpty {
            ContentUnavailableView(
                "No Offline Downloads",
                systemImage: "arrow.down.circle",
                description: Text("Download a movie or episode to watch it offline. "
                                  + "Transfers may pause while the app is backgrounded or the device sleeps.")
            )
        } else {
            List {
                SwiftUI.Section {
                    ForEach(snapshot.rows) { rowSnapshot in
                        offlineRowWithPlatformActions(rowSnapshot)
                    }
                    .onDelete { offsets in
                        confirmDelete(rows: offsets.compactMap { index in
                            snapshot.rows.indices.contains(index) ? snapshot.rows[index] : nil
                        })
                    }
                } footer: {
                    Text(snapshot.footerText)
                }
            }
        }
    }

    @ViewBuilder
    private func offlineRowWithPlatformActions(_ rowSnapshot: OfflineDownloadRowSnapshot) -> some View {
        #if os(iOS)
        row(for: rowSnapshot)
            .id(rowSnapshot.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { confirmDelete(rowSnapshot) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        #else
        row(for: rowSnapshot)
            .id(rowSnapshot.id)
        #endif
    }

    @ViewBuilder
    private var platformPresentedContent: some View {
        #if os(macOS)
        offlineNavigationContent
            .onChange(of: playing?.id) { _, _ in syncMacPlayerPresentation() }
            .onDisappear { dismissMacPlayerPresentation() }
        #else
        offlineNavigationContent
            .fullScreenCover(item: $playing) { record in offlinePlayerView(for: record) }
        #endif
    }

    private var deletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in if !isPresented { pendingDeletion = nil } }
        )
    }

    @ViewBuilder
    private var deletionDialogActions: some View {
        Button(pendingDeletion?.actionTitle ?? "Delete Download", role: .destructive) {
            commitPendingDeletion()
        }
        Button("Cancel", role: .cancel) {
            pendingDeletion = nil
        }
    }

    @ViewBuilder
    private var deletionDialogMessage: some View {
        if let pendingDeletion {
            Text(pendingDeletion.message)
        }
    }

    private func offlinePlayerView(for record: DownloadRecord) -> some View {
        CustomPlayerView(localFile: record.localURL,
                         item: offlineItem(from: record),
                         trickPlayProvider: localTrickPlayProvider(for: record),
                         offlineArtworkSource: OfflineArtworkSource(fileURL: record.posterURL,
                                                                    metadata: record.metadata,
                                                                    ratingKey: record.ratingKey),
                         offlineTextSubtitles: record.metadata?.offlineTextSubtitles ?? [],
                         offlineChapterImageURLs: record.chapterImageURLs,
                         onLocalPlaybackProgress: { positionMs, durationMs in
                             manager.updateLocalPlaybackPosition(ratingKey: record.ratingKey,
                                                                 positionMs: positionMs,
                                                                 durationMs: durationMs)
                         },
                         onClose: { playing = nil })
        #if os(iOS)
        .withMobileOrientationCoordinator(mobilePlayerOrientationCoordinator)
        #endif
        #if os(visionOS)
        .withCinemaOrigin(.offline(ratingKey: record.ratingKey))
        #endif
    }

    #if os(macOS)
    private func syncMacPlayerPresentation() {
        guard let macPlayerPresenter else { return }
        guard let playing else {
            macPlayerPresenter.dismiss(ownerID: macPlayerPresentationOwnerID)
            return
        }

        macPlayerPresenter.present(ownerID: macPlayerPresentationOwnerID,
                                   contentID: AnyHashable("offline-\(playing.id)")) {
            offlinePlayerView(for: playing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    private func dismissMacPlayerPresentation() {
        macPlayerPresenter?.dismiss(ownerID: macPlayerPresentationOwnerID)
    }
    #endif

    fileprivate static let rowActionControlSize: CGFloat = 56

    private struct PendingOfflineDeletion: Identifiable {
        let id = UUID()
        let ratingKeys: [String]
        let title: String?

        var isMultiple: Bool { ratingKeys.count > 1 }

        var dialogTitle: String {
            isMultiple ? "Delete \(ratingKeys.count) downloads?" : "Delete download?"
        }

        var actionTitle: String {
            isMultiple ? "Delete Downloads" : "Delete Download"
        }

        var message: String {
            if isMultiple {
                return "This removes \(ratingKeys.count) downloads from offline storage. You can download them again later."
            }
            if let title, !title.isEmpty {
                return "This removes “\(title)” from offline storage. You can download it again later."
            }
            return "This removes the download from offline storage. You can download it again later."
        }
    }

    /// The Offline toolbar. On iOS 26 bare toolbar items get Liquid Glass (and adjacent items
    /// share one glass background) automatically, so the metrics + queue action keep their
    /// top-trailing `ToolbarItemGroup` with no hand-rolled material. macOS uses the default
    /// native toolbar placement, and visionOS keeps the custom capsule cluster.
    @ToolbarContentBuilder
    private func offlineToolbar(snapshot: OfflineLibrarySnapshot) -> some ToolbarContent {
        if snapshot.aggregateStats.hasVisibleMetrics || snapshot.queueToolbarAction != nil {
            #if os(macOS)
            ToolbarItemGroup {
                offlineToolbarInlineItems(snapshot: snapshot)
            }
            #elseif os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                offlineToolbarInlineItems(snapshot: snapshot)
            }
            #elseif os(visionOS)
            ToolbarItem(placement: .topBarTrailing) {
                offlineToolbarCluster(snapshot: snapshot)
            }
            #else
            ToolbarItemGroup {
                offlineToolbarInlineItems(snapshot: snapshot)
            }
            #endif
        }
    }

    @ViewBuilder
    private func offlineToolbarInlineItems(snapshot: OfflineLibrarySnapshot) -> some View {
        if let speed = snapshot.aggregateStats.activeSpeedBytesPerSecond, speed > 0 {
            aggregateToolbarMetric(value: "\(Self.aggregateByteString(Int(speed)))/s",
                                   systemImage: "speedometer",
                                   accessibilityLabel: "Active download speed")
        }
        if snapshot.aggregateStats.downloadedBytes > 0 {
            aggregateToolbarMetric(value: Self.aggregateByteString(snapshot.aggregateStats.downloadedBytes),
                                   systemImage: "externaldrive.fill",
                                   accessibilityLabel: "Local download data")
        }
        if let queueToolbarAction = snapshot.queueToolbarAction {
            queueToolbarButton(queueToolbarAction)
        }
    }

    #if os(visionOS)
    private func offlineToolbarCluster(snapshot: OfflineLibrarySnapshot) -> some View {
        HStack(spacing: 8) {
            if let speed = snapshot.aggregateStats.activeSpeedBytesPerSecond, speed > 0 {
                aggregateToolbarMetric(value: "\(Self.aggregateByteString(Int(speed)))/s",
                                       systemImage: "speedometer",
                                       accessibilityLabel: "Active download speed")
            }
            if snapshot.aggregateStats.downloadedBytes > 0 {
                aggregateToolbarMetric(value: Self.aggregateByteString(snapshot.aggregateStats.downloadedBytes),
                                       systemImage: "externaldrive.fill",
                                       accessibilityLabel: "Local download data")
            }
            if snapshot.aggregateStats.hasVisibleMetrics, snapshot.queueToolbarAction != nil {
                Divider()
                    .frame(height: 18)
                    .accessibilityHidden(true)
            }
            if let queueToolbarAction = snapshot.queueToolbarAction {
                queueToolbarButton(queueToolbarAction)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.primary.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
    }
    #endif

    private func aggregateToolbarMetric(value: String,
                                        systemImage: String,
                                        accessibilityLabel: String) -> some View {
        Label {
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                // iOS toolbars compress adjacent items and ellipsize the value ("1.7 M…");
                // the metric is only a few characters, so keep its intrinsic width.
                .fixedSize(horizontal: true, vertical: false)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value)
    }

    private func queueToolbarButton(_ action: DownloadQueueToolbarPolicy.Action) -> some View {
        Button {
            switch action {
            case .pauseQueue:
                manager.pauseQueue()
            case .resumeQueue:
                manager.resumeQueue()
            }
        } label: {
            Label(action.title, systemImage: action.systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }

    private static func aggregateByteString(_ bytes: Int) -> String {
        DownloadStorageLimitPolicy.byteString(bytes)
    }

    /// Match DetailView's iPhone presentation contract: rotate the presenting browse surface
    /// before introducing the full-screen player, then pass that same coordinator into the player
    /// so Close/natural-end restoration uses the instance that captured the prior orientation.
    private func presentOfflinePlayer(_ record: DownloadRecord) {
        #if os(iOS)
        Task { @MainActor in
            await mobilePlayerOrientationCoordinator.enterLandscapeBeforePresentationIfNeeded()
            playing = record
        }
        #else
        playing = record
        #endif
    }

    private func localTrickPlayProvider(for record: DownloadRecord) -> (any TrickPlayThumbnailProviding)? {
        if backendKind(for: record) == .emby {
            let providers = ([
                LocalBIFTrickPlayThumbnailProvider(bifURL: record.embyBIFURL),
                LocalEmbyChapterTrickPlayThumbnailProvider(
                    chapters: record.metadata?.chapters ?? [],
                    imageURLsByChapterIndex: record.chapterImageURLs),
            ] as [(any TrickPlayThumbnailProviding)?]).compactMap { $0 }
            return providers.isEmpty ? nil : HierarchicalTrickPlayThumbnailProvider(providers)
        }
        if let playlist = record.jellyfinTrickPlayPlaylistURL {
            return LocalJellyfinTrickPlayThumbnailProvider(playlistURL: playlist)
        }
        return LocalBIFTrickPlayThumbnailProvider(bifURL: record.plexBIFURL)
    }

    private var showsInlineDeleteControl: Bool {
        #if os(iOS)
        return !compactWidth
        #else
        return true
        #endif
    }

    private func confirmDelete(_ rowSnapshot: OfflineDownloadRowSnapshot) {
        confirmDelete(rows: [rowSnapshot])
    }

    private func confirmDelete(rows: [OfflineDownloadRowSnapshot]) {
        let rows = rows.filter { !$0.id.isEmpty }
        guard !rows.isEmpty else { return }
        let title = rows.count == 1 ? displayTitle(for: rows[0].record) : nil
        pendingDeletion = PendingOfflineDeletion(ratingKeys: rows.map(\.id),
                                                title: title)
    }

    private func commitPendingDeletion() {
        guard let pendingDeletion else { return }
        pendingDeletion.ratingKeys.forEach { manager.delete(ratingKey: $0) }
        self.pendingDeletion = nil
    }

    @ViewBuilder
    private func row(for rowSnapshot: OfflineDownloadRowSnapshot) -> some View {
        let record = rowSnapshot.record
        // Drive the row off the explicit, persisted status (D2) instead of inferring
        // completion from `progress >= 1.0` — a stalled job that froze at <100% and a
        // failed-but-100% body are now distinct, observable states.
        let isComplete = record.isComplete
        let isRetrying = rowSnapshot.isRetrying
        let isFailed = record.status == .failed && !isRetrying
        let isUnverified = record.isUnverified
        // #95: a recoverable interruption is resumable, not failed — show a non-red "will resume"
        // affordance and a Resume control that continues from the saved byte offset.
        let isPaused = record.status == .paused

        HStack(spacing: 16) {
            // D5: show the locally-cached poster when present (works fully offline);
            // otherwise fall back to a small offline glyph tile.
            OfflinePosterTile(source: OfflineArtworkSource(fileURL: record.posterURL,
                                                           metadata: record.metadata,
                                                           ratingKey: record.ratingKey),
                              isComplete: isComplete,
                              isFailed: isFailed,
                              isUnverified: isUnverified)

            VStack(alignment: .leading, spacing: 4) {
                // On compact width (iPhone) the title column is too narrow to share a line with
                // the lane + backend capsules — they crush a long episode string — so drop the
                // badges onto their own row beneath a 2-line-truncating title. Regular/visionOS
                // keep the single-line title-plus-badges HStack.
                if compactWidth {
                    Text(displayTitle(for: record)).font(.headline).lineLimit(2)
                    HStack(spacing: 8) {
                        titleBadges(for: record, rowSnapshot: rowSnapshot)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(displayTitle(for: record)).font(.headline)
                        titleBadges(for: record, rowSnapshot: rowSnapshot)
                    }
                }
                if let subtitle = subtitle(for: record) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let bitrate = downloadBitrateText(for: record) {
                    Text(bitrate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isFailed {
                    // Prefer the surfaced reason; fall back to a generic failed line so
                    // a `.failed` row reconciled at launch (no live error) still explains.
                    Text(rowSnapshot.errorMessage ?? rowSnapshot.statusCaption)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if isRetrying {
                    ProgressView()
                    Text(rowSnapshot.statusCaption)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else if isPaused {
                    // #95: paused (recoverably interrupted). Show how far it got and that it
                    // resumes, in secondary (not red) — it's not a failure.
                    Text(rowSnapshot.errorMessage ?? rowSnapshot.statusCaption)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else if isComplete {
                    Text(rowSnapshot.statusCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Unified bar (#97): an exact Content-Length fraction for Plex/static
                    // originals, an estimated fraction for transcoder-streamed JF/Emby rows;
                    // nil only before any bytes flow, when we keep the spinner below.
                    if let progress = rowSnapshot.displayProgress {
                        ProgressView(value: progress)
                            .animation(.linear(duration: 0.2), value: progress)
                        Text(rowSnapshot.statusCaption)
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text(rowSnapshot.statusCaption)
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 12) {
                if isComplete {
                    Button {
                        // Music and video share one audio session — yield music
                        // before launching the offline player (#17).
                        musicPlayer.pauseForVideo()
                        presentOfflinePlayer(record)
                    } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                    .accessibilityLabel("Play offline download")
                } else if isFailed {
                    Button {
                        manager.retry(ratingKey: record.ratingKey)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                } else if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Retrying download")
                } else if isPaused {
                    // #95: Resume continues from the saved byte offset (manager.retry resumes a
                    // `.paused` row from persisted resume data).
                    Button {
                        manager.retry(ratingKey: record.ratingKey)
                    } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                    .accessibilityLabel("Resume download")
                } else {
                    Button {
                        manager.pause(ratingKey: record.ratingKey)
                    } label: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                    .accessibilityLabel("Pause download")
                }

                if showsInlineDeleteControl {
                    // Explicit delete stays visible on visionOS / regular-width layouts, where
                    // swipe affordances are less discoverable. Compact iOS relies on the trailing
                    // swipe action to keep the row controls from crowding the title column.
                    Button {
                        confirmDelete(rowSnapshot)
                    } label: {
                        Image(systemName: "trash.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Delete download")
                }
            }
        }
        .padding(.vertical, 4)
        #if os(visionOS)
        .background {
            if highlightedRatingKey == record.ratingKey {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.tint.opacity(0.16))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: highlightedRatingKey)
        #endif
        .contentShape(Rectangle())
        .onTapGesture {
            if isComplete {
                musicPlayer.pauseForVideo()
                presentOfflinePlayer(record)
            } else if isFailed || isPaused {
                // #95: tapping a paused row resumes it (manager.retry continues from the offset).
                manager.retry(ratingKey: record.ratingKey)
            }
        }
    }

    #if os(visionOS)
    @MainActor
    private func focusRequestedDownload(using scrollProxy: ScrollViewProxy) async {
        guard let ratingKey = focusedRatingKey else { return }
        guard manager.offlineLibrarySnapshot.rows.contains(where: { $0.id == ratingKey }) else { return }

        // RootView may set the focus request in the same transaction as switching to the Offline
        // tab after the Cinema window is recreated. Yield once so the list row exists before the
        // scroll, mirroring the proven tab-switch/navigation timing used by RootView.
        await Task.yield()
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollProxy.scrollTo(ratingKey, anchor: .center)
        }
        highlightedRatingKey = ratingKey
        focusedRatingKey = nil

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if highlightedRatingKey == ratingKey {
                highlightedRatingKey = nil
            }
        }
    }
    #endif

    /// Backend that owns this row, via the single migration fallback on the
    /// persisted snapshot (#84): a stored `backendKind` wins; pre-#84 rows fall
    /// back to the ratingKey prefix. Drives the mixed-backend badge below.
    private func backendKind(for record: DownloadRecord) -> DownloadBackendKind {
        record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
    }

    /// The lane + (mixed-library only) backend capsules that sit with the title. Factored out
    /// so the compact stacked layout and the regular inline HStack share one definition.
    @ViewBuilder
    private func titleBadges(for record: DownloadRecord,
                             rowSnapshot: OfflineDownloadRowSnapshot) -> some View {
        downloadLaneBadge(for: record)
        // Only label the backend when the library mixes them, so a
        // simultaneous Plex + Jellyfin/Emby library (#84) stays legible
        // and single-backend libraries carry no visual noise.
        if rowSnapshot.showBackendBadge {
            backendBadge(name: rowSnapshot.backendName)
        }
    }

    /// A subtle source chip ("Plex" / "Jellyfin" / "Emby") shown beside the title
    /// when the library mixes backends (#84). Matches the caption typography so it
    /// reads as part of the row rather than a bolted-on control.
    private func backendBadge(name: String) -> some View {
        Text(name)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("Source: \(name)")
    }

    /// Show the download route next to the title so Jellyfin/Emby rows make it clear whether
    /// the server is sending a raw file, a compatible remux, or a live transcode. This is useful
    /// context for resumability and "why is this slower?" without making normal downloads look
    /// like failures.
    private func downloadLaneBadge(for record: DownloadRecord) -> some View {
        let badge = DownloadRowDisplayPolicy.routeBadge(for: record)
        let label = badge.rawValue
        let systemImage: String
        let tint: Color
        switch badge {
        case .optimized:
            // B4: a server-prepared version rides the `.original` STATIC byte-range lane — it is a
            // finished file transferred/resumed byte-for-byte, NOT a live server transcode. Badge it
            // "Optimized" (distinct from a true source "Original", but never the alarming orange
            // "Transcode", which is reserved for the encoder-gated `.optimize`/remux lanes below).
            systemImage = "checkmark.seal"
            tint = .secondary
        case .original:
            systemImage = "checkmark.seal"
            tint = .secondary
        case .remux:
            systemImage = "arrow.triangle.2.circlepath"
            tint = .orange
        case .transcode:
            systemImage = "gauge.with.dots.needle.bottom.50percent"
            tint = .orange
        }
        return Label(label, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityLabel("Download route: \(label)")
    }

    /// Keep downloaded episodes self-identifying and sortable by eye even without the server:
    /// "Show · S1E3 · Episode Title" instead of only the episode title.
    private func displayTitle(for record: DownloadRecord) -> String {
        guard let item = record.metadata?.makeMediaItem(), item.kind == .episode else {
            return record.title
        }
        return item.displaySubtitleLine
    }

    /// A secondary line built from the persisted snapshot (D5): year + runtime +
    /// content rating, when available. Returns nil for rows with no metadata.
    private func subtitle(for record: DownloadRecord) -> String? {
        guard let meta = record.metadata else { return nil }
        var parts: [String] = []
        if let year = meta.year { parts.append(String(year)) }
        if let duration = meta.duration, duration > 0 {
            let minutes = max(1, duration / 60_000)
            parts.append("\(minutes) min")
        }
        if let rating = meta.contentRating, !rating.isEmpty { parts.append(rating) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func downloadBitrateText(for record: DownloadRecord) -> String? {
        DownloadRowDisplayPolicy.downloadQualityText(for: record)
    }

    /// Reconstruct a faithful `MediaItem` from the persisted snapshot (D5) so the
    /// offline file flows through the same `CustomPlayerView` path with real title/metadata.
    /// Rows persisted before D5 fall back to a minimal movie.
    private func offlineItem(from record: DownloadRecord) -> MediaItem {
        record.metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
    }

}

/// Locally-cached offline artwork. Loading happens from `.task(id:)` with the disk read off the
/// main actor, not inline in row rendering, so frequent progress refreshes don't repeatedly stat,
/// read, and decode poster files while the user scrolls.
private struct OfflinePosterTile: View {
    let source: OfflineArtworkSource?
    let isComplete: Bool
    let isFailed: Bool
    let isUnverified: Bool

    @Environment(\.artworkPipeline) private var artworkPipeline
    @Environment(\.displayScale) private var displayScale
    @State private var image: DecodedImage?
    @State private var loadedIdentity: ArtworkTaskIdentity?

    private var descriptor: ArtworkRequestDescriptor? {
        let pixels = MediaArtwork.pixelDimensions(width: 44,
                                                  height: 66,
                                                  displayScale: displayScale,
                                                  requestScale: nil)
        return source?.descriptor(pixelWidth: pixels.width, pixelHeight: pixels.height)
    }

    var body: some View {
        Group {
            if loadedIdentity == descriptor?.taskIdentity, let image {
                Image(decodedImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: descriptor?.taskIdentity) {
            await loadPoster()
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                Image(systemName: tileGlyph)
                    .font(.title3)
                    .foregroundStyle(isUnverified ? .yellow : (isComplete ? .green : (isFailed ? .red : .secondary)))
            }
    }

    private var tileGlyph: String {
        if isUnverified { return "exclamationmark.circle.fill" }
        if isComplete { return "arrow.down.circle.fill" }
        if isFailed { return "exclamationmark.circle" }
        return "arrow.down.circle"
    }

    @MainActor
    private func loadPoster() async {
        image = nil
        loadedIdentity = nil
        guard let descriptor, let artworkPipeline else { return }
        do {
            let response = try await artworkPipeline.fetch(descriptor, priority: .utility)
            guard !Task.isCancelled,
                  self.descriptor?.taskIdentity == descriptor.taskIdentity else { return }
            image = response.image
            loadedIdentity = descriptor.taskIdentity
        } catch is CancellationError {
            return
        } catch {
            // Offline poster art is optional; retain the status-specific placeholder.
        }
    }
}

private struct OfflineRowActionControlModifier: ViewModifier {
    // visionOS/iPad ride the gaze-sized 56×56 / 34-pt glyph; compact width (iPhone) shrinks to
    // a 44-pt frame (the HIG touch minimum) with a 24-pt glyph so two controls plus spacing no
    // longer eat ~124 pt of a ~358-pt phone row.
    @Environment(\.labstreamCompactWidth) private var compactWidth

    func body(content: Content) -> some View {
        let size = compactWidth ? 44 : OfflineLibraryView.rowActionControlSize
        let glyphSize: CGFloat = compactWidth ? 24 : 34
        content
            .font(.system(size: glyphSize, weight: .semibold))
            .frame(width: size, height: size)
            .contentShape(Circle())
    }
}

private extension View {
    func offlineRowActionControl() -> some View {
        modifier(OfflineRowActionControlModifier())
    }
}
