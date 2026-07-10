import SwiftUI
import PMSKit

#if os(visionOS)
struct WatchTogetherJoinView: View {
    @Environment(WatchTogetherCoordinator.self) private var coordinator
    @State private var query = ""
    @State private var showStartWarning = false

    var body: some View {
        NavigationStack {
            Group {
                if let prompt = coordinator.joinPrompt {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        disclosure(prompt)
                        if prompt.isReady { readyView }
                        else if prompt.isSearching { ProgressView("Searching this server…") }
                        else { selectionView(prompt) }
                    }
                    .padding(DS.Space.xxl)
                    .onAppear { if query.isEmpty { query = prompt.searchQuery } }
                }
            }
            .navigationTitle("Join Watch Together")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Leave") { coordinator.declineIncoming() }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .interactiveDismissDisabled()
        .confirmationDialog("Start without everyone?", isPresented: $showStartWarning) {
            Button("Start with ready participants") {
                coordinator.startWithReadyParticipants(acknowledgeUnresolved: true)
            }
            Button("Keep waiting", role: .cancel) {}
        } message: {
            Text("Participants still resolving this title can join later and synchronize without restarting the group.")
        }
    }

    private func disclosure(_ prompt: WatchTogetherCoordinator.JoinPrompt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Label(prompt.title, systemImage: "shareplay")
                .font(.title2.bold())
            if let subtitle = prompt.subtitle { Text(subtitle).foregroundStyle(.secondary) }
            Text("The title and public catalog identity (TMDB, TVDB, or IMDb when available) are shared for matching. Server addresses, account details, library/item IDs, filenames, and credentials are never shared.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Label("Ready on this device", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("\(coordinator.readyParticipantCount) ready · \(coordinator.resolvingParticipantCount) resolving")
                .foregroundStyle(.secondary)
            if coordinator.isLocalInitiator {
                Button("Start Watching") {
                    if coordinator.requiresStartAcknowledgement { showStartWarning = true }
                    else { coordinator.startWithReadyParticipants(acknowledgeUnresolved: false) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView("Waiting for the initiator…")
            }
        }
    }

    private func selectionView(_ prompt: WatchTogetherCoordinator.JoinPrompt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Select the matching item from your current \(backendLabel) server.")
                .font(.headline)
            HStack {
                TextField("Search your server", text: $query)
                Button("Search") { coordinator.searchCandidates(query: query) }
                    .buttonStyle(.bordered)
            }
            if prompt.candidates.isEmpty {
                ContentUnavailableView("No timeline-compatible match found",
                                       systemImage: "questionmark.video",
                                       description: Text("Try a different title. Offline downloads aren’t eligible."))
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(prompt.candidates) { item in
                            Button { coordinator.selectCandidate(item) } label: {
                                HStack {
                                    PosterImage(path: item.thumb, width: 72, height: 48,
                                                cornerRadius: DS.Radius.chip)
                                    VStack(alignment: .leading) {
                                        Text(item.title).font(.headline)
                                        Text(candidateSubtitle(item)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.circle")
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var backendLabel: String { "media" }

    private func candidateSubtitle(_ item: MediaItem) -> String {
        [item.grandparentTitle, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
}
#endif
