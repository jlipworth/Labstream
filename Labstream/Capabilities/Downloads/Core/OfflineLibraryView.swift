import SwiftUI
import PMSKit

/// Lists offline downloads with live progress + delete, and plays a completed
/// file through the shared admitted-launch custom player.
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
    @State private var playing: PresentedOfflineLaunch?
    @State private var playbackPresentation: OfflineLibraryPlaybackPresentation
    @State private var playbackError: OfflinePlaybackLaunchRejection?
    @AppStorage(PlaybackPreferences.Keys.resumeRewindSeconds) private var resumeRewindSeconds = 0
    #if os(iOS)
    @State private var mobilePlayerOrientationCoordinator = MobilePlayerOrientationCoordinator()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.duoPose) private var duoPose
    /// The rows' content region in global space, measured for `DownloadsLayoutPolicy`.
    @State private var downloadsRegion: CGRect = .zero
    /// The row the user chose: highlighted in the list + detail split, pushed as a detail page
    /// in the single-column list, and kept across a fold or unfold.
    #if DEBUG
    @State private var selectedRowID: String? = DebugUITestLaunchConfiguration.opensFirstDownload
        ? DebugUIFixtureCatalog.downloadRowsSnapshot?.rows.first?.id : nil
    #else
    @State private var selectedRowID: String?
    #endif
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
        self.init(manager: manager, launchFactory: Self.defaultLaunchFactory(manager), focusedRatingKey: focusedRatingKey)
    }
    init(manager: DownloadManager, launchFactory: any OfflinePlaybackLaunchFactory,
         focusedRatingKey: Binding<String?> = .constant(nil)) {
        _manager = State(initialValue: manager)
        _playbackPresentation = State(initialValue: OfflineLibraryPlaybackPresentation(factory: launchFactory))
        _focusedRatingKey = focusedRatingKey
    }
    #else
    public init(manager: DownloadManager) {
        self.init(manager: manager, launchFactory: Self.defaultLaunchFactory(manager))
    }
    init(manager: DownloadManager, launchFactory: any OfflinePlaybackLaunchFactory) {
        _manager = State(initialValue: manager)
        _playbackPresentation = State(initialValue: OfflineLibraryPlaybackPresentation(factory: launchFactory))
    }
    #endif

    static func defaultLaunchFactory(_ manager: DownloadManager) -> any OfflinePlaybackLaunchFactory {
        manager.offlinePlaybackLaunchFactory
    }

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
            .alert("Can't play offline", isPresented: Binding(
                get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
                Button("OK", role: .cancel) { playbackError = nil }
            } message: {
                Text(playbackError == .missingFile
                    ? "The downloaded file is no longer available on this device."
                    : "This downloaded copy is no longer available for playback. Refresh Offline and try again.")
            }
    }

    /// The manager's snapshot, or in DEBUG browse-fixture runs the synthetic capture rows.
    private var currentSnapshot: OfflineLibrarySnapshot {
        #if DEBUG
        if let fixture = DebugUIFixtureCatalog.downloadRowsSnapshot { return fixture }
        #endif
        return manager.offlineLibrarySnapshot
    }

    private var offlineNavigationContent: some View {
        let snapshot = currentSnapshot

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
            if let notice = manager.upgradeNotice {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                    Text(notice.message)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { manager.dismissUpgradeNotice() }
                        .buttonStyle(.bordered)
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
        if snapshot.rows.isEmpty && manager.startupRecoveryState == .preparing {
            ProgressView("Restoring downloads…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot.rows.isEmpty {
            #if os(iOS)
            // Centred in the content region with a body of at most two lines.
            ContentUnavailableView(
                "No Offline Downloads",
                systemImage: "arrow.down.circle",
                description: Text("Download a movie or episode to watch it offline.")
            )
            #else
            ContentUnavailableView(
                "No Offline Downloads",
                systemImage: "arrow.down.circle",
                description: Text("Download a movie or episode to watch it offline. "
                                  + "Transfers may pause while the app is backgrounded or the device sleeps.")
            )
            #endif
        } else {
            #if os(iOS)
            mobileRows(snapshot: snapshot)
            #else
            offlineList(snapshot: snapshot)
            #endif
        }
    }

    private func offlineList(snapshot: OfflineLibrarySnapshot) -> some View {
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

    @ViewBuilder
    private func offlineRowWithPlatformActions(_ rowSnapshot: OfflineDownloadRowSnapshot) -> some View {
        #if os(iOS)
        row(for: rowSnapshot)
            .id(rowSnapshot.id)
            .listRowBackground(isHighlightedInSplit(rowSnapshot.id)
                ? AnyView(Color.accentColor.opacity(0.18))
                : nil)
            .deleteDisabled(manager.startupRecoveryState != .ready)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { confirmDelete(rowSnapshot) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(manager.startupRecoveryState != .ready)
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

    private func offlinePlayerView(for presented: PresentedOfflineLaunch) -> some View {
        Self.makeOfflinePlayer(launch: presented.launch, onClose: { playing = nil })
        #if os(iOS)
        .withMobileOrientationCoordinator(mobilePlayerOrientationCoordinator)
        #endif
        #if os(visionOS)
        .withCinemaOrigin(.offline(ratingKey: presented.launch.attemptKey.ratingKey))
        #endif
    }

    /// All production library inputs and event authority come from the injected launch factory.
    static func makeOfflinePlayer(launch: OfflinePlaybackLaunch,
                                  onClose: @escaping () -> Void) -> CustomPlayerView {
        CustomPlayerView(offlineLaunch: launch,
                         trickPlayProvider: launch.makeTrickPlayProvider(),
                         onClose: onClose)
    }

    #if os(macOS)
    private func syncMacPlayerPresentation() {
        guard let macPlayerPresenter else { return }
        guard let playing else {
            macPlayerPresenter.dismiss(ownerID: macPlayerPresentationOwnerID)
            return
        }

        macPlayerPresenter.present(ownerID: macPlayerPresentationOwnerID,
                                   contentID: AnyHashable("offline-\(playing.id)"),
                                   onClose: { self.playing = nil }) {
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
        struct Entry {
            let ratingKey: String
            let attemptID: DownloadAttemptID?
        }
        let id = UUID()
        let entries: [Entry]
        let title: String?
        /// D2: at least one row still has server-side preparation that deleting it cancels.
        var cancelsServerPrep = false

        var isMultiple: Bool { entries.count > 1 }

        var dialogTitle: String {
            isMultiple ? "Delete \(entries.count) downloads?" : "Delete download?"
        }

        var actionTitle: String {
            isMultiple ? "Delete Downloads" : "Delete Download"
        }

        var message: String {
            DownloadRemovalMessage.message(count: entries.count, cancelsServerPrep: cancelsServerPrep)
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
        aggregateSpeedMetric(snapshot.aggregateStats)
        if snapshot.aggregateStats.downloadedBytes > 0 {
            aggregateToolbarMetric(value: Self.aggregateByteString(snapshot.aggregateStats.downloadedBytes),
                                   systemImage: "externaldrive.fill",
                                   accessibilityLabel: "Local download data",
                                   envelope: .storageTotal)
        }
        if let queueToolbarAction = snapshot.queueToolbarAction {
            queueToolbarButton(queueToolbarAction)
        }
    }

    #if os(visionOS)
    private func offlineToolbarCluster(snapshot: OfflineLibrarySnapshot) -> some View {
        HStack(spacing: 8) {
            aggregateSpeedMetric(snapshot.aggregateStats)
            if snapshot.aggregateStats.downloadedBytes > 0 {
                aggregateToolbarMetric(value: Self.aggregateByteString(snapshot.aggregateStats.downloadedBytes),
                                       systemImage: "externaldrive.fill",
                                       accessibilityLabel: "Local download data",
                                       envelope: .storageTotal)
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

    @ViewBuilder
    private func aggregateSpeedMetric(_ stats: OfflineDownloadAggregateStats) -> some View {
        if let speed = stats.activeSpeedBytesPerSecond {
            aggregateToolbarMetric(value: "\(Self.aggregateByteString(Int(speed)))/s",
                                   systemImage: "speedometer",
                                   accessibilityLabel: "Active download speed",
                                   envelope: .rate)
        } else if stats.isUpdatingSpeed {
            Text("Updating speed…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func aggregateToolbarMetric(value: String,
                                        systemImage: String,
                                        accessibilityLabel: String,
                                        envelope: HotMetricEnvelope) -> some View {
        Label {
            Text(value)
                .font(.caption.weight(.semibold))
                .stableHotMetric(envelope)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
            #if os(iOS)
            if compactWidth {
                // Compact portrait prioritizes the two live values. The icon keeps the queue
                // action reachable without allowing its title to evict or clip either metric.
                Image(systemName: action.systemImage)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            } else {
                Label(action.title, systemImage: action.systemImage)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            #else
            Label(action.title, systemImage: action.systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            #endif
        }
        #if os(macOS)
        // This is a queue-wide command, not another transfer statistic. Native bordered chrome
        // keeps it visually and semantically separate from the adjacent rate/storage readouts.
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(action.title)
        .keyboardShortcut(action == .pauseQueue ? "p" : "r", modifiers: [.command, .option])
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(action.title)
        .disabled(manager.startupRecoveryState != .ready)
    }

    private static func aggregateByteString(_ bytes: Int) -> String {
        DownloadStorageLimitPolicy.byteString(bytes)
    }

    /// Admission is deliberately after orientation. The presentation coordinator additionally
    /// fences this surface's superseded tasks, independently of the factory's request generation.
    private func presentOfflinePlayer(_ identity: OfflineDownloadRowActionIdentity) {
        Task { @MainActor in
            let result = await playbackPresentation.launch(for: identity,
                resumeRewindSeconds: resumeRewindSeconds, orientation: {
                    #if os(iOS)
                    await mobilePlayerOrientationCoordinator.enterLandscapeBeforePresentationIfNeeded()
                    #endif
                }, restoreOrientation: {
                    #if os(iOS)
                    mobilePlayerOrientationCoordinator.restoreIfNeeded()
                    #endif
                })
            switch result {
            case .success(let launch):
                musicPlayer.pauseForVideo()
                playing = PresentedOfflineLaunch(launch: launch)
            case .failure(.supersededPresentation): break
            case .failure(let rejection): playbackError = rejection
            }
        }
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
        let title = rows.count == 1 ? rows[0].title : nil
        pendingDeletion = PendingOfflineDeletion(
            entries: rows.map { .init(ratingKey: $0.id, attemptID: $0.attemptID) },
            title: title,
            cancelsServerPrep: rows.contains { row in
                DownloadDeletePolicy.deletionCancelsServerPrep(
                    manager.currentRecord(for: row.actionIdentity))
            })
    }

    private func commitPendingDeletion() {
        guard let pendingDeletion else { return }
        for entry in pendingDeletion.entries {
            let identity = OfflineDownloadRowActionIdentity(
                ratingKey: entry.ratingKey, attemptID: entry.attemptID)
            manager.delete(identity)
        }
        self.pendingDeletion = nil
    }

    @ViewBuilder
    private func row(for rowSnapshot: OfflineDownloadRowSnapshot) -> some View {
        let presentation = Self.rowPresentation(rowSnapshot)
        HStack(spacing: 16) {
            OfflinePosterTile(source: rowSnapshot.artwork.flatMap(OfflineArtworkSource.init),
                isComplete: rowSnapshot.isComplete,
                isFailed: presentation.tone == .failure, isUnverified: rowSnapshot.isUnverified)
            DownloadRowContent(presentation: presentation)
            HStack(spacing: 12) {
                ForEach(presentation.actions.filter { $0 != .delete || showsInlineDeleteControl }, id: \.rawValue) { action in
                    Button {
                        switch action {
                        case .play: presentOfflinePlayer(presentation.actionIdentity)
                        case .pause: manager.pause(presentation.actionIdentity)
                        case .resume, .retry: manager.retry(presentation.actionIdentity)
                        case .delete: confirmDelete(rowSnapshot)
                        }
                    } label: {
                        Image(systemName: Self.actionSymbol(action))
                    }
                    .buttonStyle(.plain)
                    .offlineRowActionControl()
                    .foregroundStyle(action == .delete ? Color.red : Self.rowActionColor)
                    .accessibilityLabel(presentation.actionLabel(action))
                    .accessibilityIdentifier("download.\(action.rawValue)")
                    .disabled(action != .play && manager.startupRecoveryState != .ready)
                }
            }
        }
        .padding(.vertical, 4)
        #if os(visionOS)
        .background {
            if highlightedRatingKey == rowSnapshot.id {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.tint.opacity(0.16))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: highlightedRatingKey)
        #endif
        .contentShape(Rectangle())
        .onTapGesture {
            #if os(iOS)
            // iPhone/iPad: a tap chooses the row, which shows it in the detail column of the
            // split or pushes the same detail in the single-column list (Mail model). The row's
            // own Play/Pause/Retry controls keep their one-tap actions.
            selectedRowID = rowSnapshot.id
            #else
            if presentation.actions.contains(.play) {
                presentOfflinePlayer(presentation.actionIdentity)
            } else if presentation.actions.contains(.resume) || presentation.actions.contains(.retry) {
                manager.retry(presentation.actionIdentity)
            }
            #endif
        }
    }

    /// iPhone/iPad row actions use the label color (amber means "selected" only); other
    /// platforms keep the accent.
    private static var rowActionColor: Color {
        #if os(iOS)
        Color.primary
        #else
        Color.accentColor
        #endif
    }

    #if os(iOS)
    private var downloadsLayout: DownloadsLayoutPolicy.Layout {
        var hinge: (minX: Double, maxX: Double)?
        if case .book(let rect) = duoPose {
            hinge = (Double(rect.minX - downloadsRegion.minX), Double(rect.maxX - downloadsRegion.minX))
        }
        return DownloadsLayoutPolicy.layout(width: Double(downloadsRegion.width),
                                            height: Double(downloadsRegion.height),
                                            regularWidth: horizontalSizeClass == .regular,
                                            pagePadding: Double(DS.pagePadding(compact: compactWidth)),
                                            hinge: hinge)
    }

    private var isSplit: Bool {
        if case .split = downloadsLayout { return true }
        return false
    }

    private func isHighlightedInSplit(_ id: String) -> Bool {
        isSplit && displayedRowID(in: currentSnapshot) == id
    }

    /// The split always shows a detail: the chosen row, else the first row.
    private func displayedRowID(in snapshot: OfflineLibrarySnapshot) -> String? {
        if let selectedRowID, snapshot.rows.contains(where: { $0.id == selectedRowID }) {
            return selectedRowID
        }
        return snapshot.rows.first?.id
    }

    /// iPhone/iPad Downloads composition (iPhone Duo design spec, Downloads): one capped column
    /// of rows, or a Mail-style list + detail when the content region is wide and landscape. A
    /// chosen row stays chosen across a fold: the split highlights it, the column pushes it.
    @ViewBuilder
    private func mobileRows(snapshot: OfflineLibrarySnapshot) -> some View {
        Group {
            switch downloadsLayout {
            case .list(let inset):
                if horizontalSizeClass == .regular {
                    // Regular width caps the row column at 560 pt, centred.
                    offlineList(snapshot: snapshot)
                        .contentMargins(.horizontal, CGFloat(inset), for: .scrollContent)
                } else {
                    // Compact keeps the list's own safe-area margins, so rows end one margin
                    // before the vertical bar.
                    offlineList(snapshot: snapshot)
                }
            case .split(let listWidth, let detailStart):
                HStack(spacing: 0) {
                    offlineList(snapshot: snapshot)
                        .frame(width: CGFloat(listWidth))
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 0.5)
                        .accessibilityHidden(true)
                    Color.clear
                        .frame(width: max(CGFloat(detailStart - listWidth) - 0.5, 0))
                        .accessibilityHidden(true)
                    if let id = displayedRowID(in: snapshot),
                       let rowSnapshot = snapshot.rows.first(where: { $0.id == id }) {
                        offlineDetail(for: rowSnapshot)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { region in
            if downloadsRegion != region { downloadsRegion = region }
        }
        .navigationDestination(isPresented: Binding(
            get: {
                !isSplit && selectedRowID.map { id in snapshot.rows.contains { $0.id == id } } == true
            },
            set: { presented in
                // Only a pop in the single column clears the choice; unfolding into the split
                // dismisses the pushed page but keeps the row chosen.
                if !presented, !isSplit { selectedRowID = nil }
            })) {
            if let selectedRowID,
               let rowSnapshot = currentSnapshot.rows.first(where: { $0.id == selectedRowID }) {
                offlineDetail(for: rowSnapshot)
                    .navigationTitle(rowSnapshot.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// The detail for one download (iPhone Duo design spec, Downloads, decision 5): art, title,
    /// context, the route and size, the full status, the row's actions as labelled controls
    /// (Play prominent, Delete in red), then the overview.
    private func offlineDetail(for rowSnapshot: OfflineDownloadRowSnapshot) -> some View {
        let presentation = Self.rowPresentation(rowSnapshot)
        let record = manager.records.first { $0.ratingKey == rowSnapshot.id }
        let sizeBytes = record.map { max(0, $0.bytes) + max(0, $0.sideAssetBytes) } ?? 0
        let routeAndSize = [rowSnapshot.routeBadge.rawValue,
                            sizeBytes > 0 ? DownloadRowDisplayPolicy.byteString(sizeBytes) : nil,
                            rowSnapshot.showBackendBadge ? rowSnapshot.backendName : nil]
            .compactMap { $0 }
            .joined(separator: " • ")
        let overview = record?.metadata?.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                OfflinePosterTile(source: rowSnapshot.artwork.flatMap(OfflineArtworkSource.init),
                                  isComplete: rowSnapshot.isComplete,
                                  isFailed: presentation.tone == .failure,
                                  isUnverified: rowSnapshot.isUnverified,
                                  size: CGSize(width: 120, height: 180))
                    .padding(.bottom, DS.Space.sm)
                Text(rowSnapshot.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let subtitle = rowSnapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(routeAndSize)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("download.detail.size")
                if let quality = rowSnapshot.qualityText, !quality.isEmpty {
                    Text(quality)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // The pane has room for the full status (bytes, rate, ETA) the row abbreviates.
                Text(presentation.statusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(presentation.tone == .failure ? Color.red
                                     : presentation.tone == .verified ? Color.green : Color.secondary)
                    .lineLimit(2)
                HStack(spacing: DS.Space.md) {
                    ForEach(presentation.actions.filter { $0 != .delete }, id: \.rawValue) { action in
                        Button {
                            perform(action, presentation: presentation, row: rowSnapshot)
                        } label: {
                            Label(Self.detailTitle(action), systemImage: Self.detailSymbol(action))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .accessibilityLabel(presentation.actionLabel(action))
                        .modifier(OfflineDetailActionStyle(prominent: action == .play))
                        .disabled(action != .play && manager.startupRecoveryState != .ready)
                    }
                    if presentation.actions.contains(.delete) {
                        Button(role: .destructive) {
                            confirmDelete(rowSnapshot)
                        } label: {
                            Label("Delete Download", systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .font(.subheadline.weight(.semibold))
                        }
                        .labstreamGlassButtonStyle()
                        .tint(.red)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Delete Download")
                        .disabled(manager.startupRecoveryState != .ready)
                    }
                }
                .padding(.top, DS.Space.sm)
                if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DS.Space.sm)
                        .accessibilityIdentifier("download.detail.overview")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.pagePadding(compact: compactWidth))
        }
        .accessibilityIdentifier("download.detail")
    }

    private func perform(_ action: DownloadRowPresentation.Action,
                         presentation: DownloadRowPresentation,
                         row rowSnapshot: OfflineDownloadRowSnapshot) {
        switch action {
        case .play: presentOfflinePlayer(presentation.actionIdentity)
        case .pause: manager.pause(presentation.actionIdentity)
        case .resume, .retry: manager.retry(presentation.actionIdentity)
        case .delete: confirmDelete(rowSnapshot)
        }
    }

    private static func detailTitle(_ action: DownloadRowPresentation.Action) -> String {
        switch action {
        case .play: "Play"
        case .pause: "Pause"
        case .resume: "Resume"
        case .retry: "Retry"
        case .delete: "Delete"
        }
    }

    private static func detailSymbol(_ action: DownloadRowPresentation.Action) -> String {
        switch action {
        case .play, .resume: "play.fill"
        case .pause: "pause.fill"
        case .retry: "arrow.clockwise"
        case .delete: "trash"
        }
    }
    #endif

    static func rowPresentation(_ row: OfflineDownloadRowSnapshot,
                                phase: DownloadJobPhase? = nil) -> DownloadRowPresentation {
        DownloadRowPresentation(row: row, phase: phase)
    }

    private static func actionSymbol(_ action: DownloadRowPresentation.Action) -> String {
        switch action {
        case .play, .resume: "play.circle.fill"
        case .pause: "pause.circle.fill"
        case .retry: "arrow.clockwise.circle.fill"
        case .delete: "trash.circle.fill"
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


}

/// Locally-cached offline artwork. Loading happens from `.task(id:)` with the disk read off the
/// main actor, not inline in row rendering, so frequent progress refreshes don't repeatedly stat,
/// read, and decode poster files while the user scrolls.
private struct OfflinePosterTile: View {
    let source: OfflineArtworkSource?
    let isComplete: Bool
    let isFailed: Bool
    let isUnverified: Bool
    /// Explicit size (detail pane); nil uses the row size: 44×66 compact, 60×90 regular on
    /// iPhone/iPad (iPhone Duo design spec, Downloads), 44×66 elsewhere.
    var size: CGSize? = nil

    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var tileSize: CGSize {
        if let size { return size }
        #if os(iOS)
        return compactWidth ? CGSize(width: 44, height: 66) : CGSize(width: 60, height: 90)
        #else
        return CGSize(width: 44, height: 66)
        #endif
    }

    @Environment(\.artworkPipeline) private var artworkPipeline
    @Environment(\.displayScale) private var displayScale
    @State private var image: DecodedImage?
    @State private var loadedIdentity: ArtworkTaskIdentity?

    private var descriptor: ArtworkRequestDescriptor? {
        let pixels = MediaArtwork.pixelDimensions(width: tileSize.width,
                                                  height: tileSize.height,
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
        .frame(width: tileSize.width, height: tileSize.height)
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
                    .foregroundStyle(glyphColor)
            }
    }

    /// Unverified is the secondary label with its own glyph on iPhone/iPad (no orange, which
    /// reads as amber "selected"); other platforms keep the orange caution hue.
    private var glyphColor: Color {
        if isUnverified {
            #if os(iOS)
            return .secondary
            #else
            return .orange
            #endif
        }
        if isComplete { return .green }
        if isFailed { return .red }
        return .secondary
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

#if os(iOS)
/// Detail-pane action style: Play is the prominent label-on-glass capsule, other actions glass.
private struct OfflineDetailActionStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.labstreamGlassProminentButtonStyle()
        } else {
            content.labstreamGlassButtonStyle()
        }
    }
}
#endif

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

struct OfflineMetricToken: Sendable, Equatable {
    let text: String
    let envelope: HotMetricEnvelope?

    static func tokenize(_ caption: String) -> [Self] {
        caption.components(separatedBy: " • ").map { text in
            let lowercase = text.lowercased()
            let envelope: HotMetricEnvelope?
            if lowercase.hasSuffix("%") {
                envelope = .percent
            } else if lowercase.contains("/s") {
                envelope = lowercase.contains("server-paced") ? .annotatedRate : .rate
            } else if lowercase.contains(" left") || lowercase.contains("under a min") {
                envelope = .duration
            } else if [" kb", " mb", " gb", " tb"].contains(where: lowercase.contains) {
                envelope = .bytes
            } else {
                envelope = nil
            }
            return Self(text: text, envelope: envelope)
        }
    }
}

/// A small leading-aligned flow layout for compact metric fields. Unlike free-form `Text`
/// wrapping, a field never breaks between its number and unit; it moves intact to the next row.
struct OfflineMetricFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    struct Cache {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        layout(proposedWidth: proposal.width, sizes: cache.sizes).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let result = layout(proposedWidth: bounds.width, sizes: cache.sizes)
        for (index, point) in result.origins.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(cache.sizes[index])
            )
        }
    }

    private func layout(
        proposedWidth: CGFloat?,
        sizes: [CGSize]
    ) -> (size: CGSize, origins: [CGPoint]) {
        let available = max(1, proposedWidth ?? sizes.reduce(0) {
            $0 + $1.width + horizontalSpacing
        })
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > available {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, min(available, x - horizontalSpacing))
        }

        return (CGSize(width: proposedWidth ?? usedWidth, height: y + rowHeight), origins)
    }
}

private extension View {
    func offlineRowActionControl() -> some View {
        modifier(OfflineRowActionControlModifier())
    }
}

@MainActor
private struct PresentedOfflineLaunch: Identifiable {
    let launch: OfflinePlaybackLaunch
    nonisolated let id: UInt64
    init(launch: OfflinePlaybackLaunch) {
        self.launch = launch
        id = launch.presentationRequest.generation
    }
}

@MainActor
final class OfflineLibraryPlaybackPresentation {
    private let factory: any OfflinePlaybackLaunchFactory
    private var generation: UInt64 = 0
    init(factory: any OfflinePlaybackLaunchFactory) { self.factory = factory }

    func launch(for identity: OfflineDownloadRowActionIdentity, resumeRewindSeconds: Int,
                orientation: () async -> Void, restoreOrientation: () -> Void = {}) async
        -> Result<OfflinePlaybackLaunch, OfflinePlaybackLaunchRejection> {
        generation += 1
        let captured = generation
        let request = factory.beginPresentationRequest()
        return await factory.makeLaunchAfterOrientation(for: identity, request: request,
            resumeRewindSeconds: resumeRewindSeconds, orientation: orientation,
            restoreOrientation: restoreOrientation, isCurrent: { generation == captured })
    }
}
