#if !os(tvOS)
import SwiftUI

/// Restricted cold-launch surface shown only when saved credentials were preserved after a
/// transient restore failure and at least one completed local media file still exists.
struct OfflineLaunchView: View {
    let runtime: AppRuntime

    @State private var reconnecting = false
    @State private var showingSignIn = false
    @State private var showingSettings = false
    #if os(macOS)
    @State private var macPlayerPresenter = MacPlayerPresentationStore()
    #endif

    private var appModel: AppModel { runtime.appModel }
    private var authManager: AuthManager { runtime.authManager }
    private var downloadManager: DownloadManager { runtime.downloadManager }

    var body: some View {
        presentedContent
            .environment(appModel)
            .environment(downloadManager)
            .environment(runtime.musicPlayer)
            .environment(\.artworkPipeline, runtime.artworkPipeline)
            .environment(\.artworkShimmerClock, runtime.artworkShimmerClock)
            .sheet(isPresented: $showingSignIn) {
                LoginView(authManager: authManager)
                    .environment(appModel)
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView(authManager: authManager,
                                 catalogRepository: runtime.libraryCatalogRepository)
                }
                .environment(appModel)
                .environment(downloadManager)
                .environment(runtime.musicPlayer)
                .environment(\.artworkPipeline, runtime.artworkPipeline)
                .environment(\.artworkShimmerClock, runtime.artworkShimmerClock)
            }
            .accessibilityIdentifier("labstream.offline-launch.root")
    }

    @ViewBuilder
    private var presentedContent: some View {
        #if os(macOS)
        ZStack {
            offlineNavigation
            if let presentation = macPlayerPresenter.presentation {
                presentation.content
                    .id(presentation.contentID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .ignoresSafeArea()
                    .zIndex(10)
            }
        }
        .environment(\.macPlayerPresentationStore, macPlayerPresenter)
        #else
        offlineNavigation
        #endif
    }

    private var offlineNavigation: some View {
        NavigationStack {
            #if os(visionOS)
            OfflineLibraryView(manager: downloadManager, focusedRatingKey: .constant(nil))
                .toolbar { launchToolbar }
            #else
            OfflineLibraryView(manager: downloadManager)
                .toolbar { launchToolbar }
            #endif
        }
        .safeAreaInset(edge: .top) {
            offlineStatusBanner
        }
    }

    private var offlineStatusBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline mode")
                    .font(.headline)
                Text("Your server could not be reached. Completed downloads remain available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(reconnecting ? "Connecting…" : "Reconnect") {
                reconnect()
            }
            .buttonStyle(.borderedProminent)
            .disabled(reconnecting)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    @ToolbarContentBuilder
    private var launchToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showingSignIn = true
            } label: {
                Label("Sign In", systemImage: "person.crop.circle")
            }
            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private func reconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        Task { @MainActor in
            _ = await authManager.restoreSession()
            reconnecting = false
        }
    }
}
#endif
