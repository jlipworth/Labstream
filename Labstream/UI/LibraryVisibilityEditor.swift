import SwiftUI
#if os(macOS)
import AppKit
#endif
import PMSKit

/// The first-run library picker payload (#104): the candidates to choose from, the backend key
/// they belong to, and the pre-checked "hide" set (known-noise libraries). Identifiable so it can
/// drive a `.sheet(item:)`.
struct LibraryVisibilityPrompt: Identifiable {
    let id = UUID()
    let backendKey: String
    let candidates: [LibraryVisibility.Candidate]
    let preselectedHidden: Set<String>
}

/// First-run sheet that lets the user confirm which libraries to show. Toggles are framed as
/// "Show" (on = visible); known-noise libraries start OFF (pre-checked to hide). Nothing is
/// hidden until the user taps "Done"; "Show All" turns every toggle on before confirming.
struct LibraryVisibilityPickerSheet: View {
    let prompt: LibraryVisibilityPrompt
    /// Called with the final HIDDEN id set on confirm.
    let onConfirm: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var hidden: Set<String>

    init(prompt: LibraryVisibilityPrompt,
         onConfirm: @escaping (Set<String>) -> Void,
         onCancel: @escaping () -> Void) {
        self.prompt = prompt
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _hidden = State(initialValue: prompt.preselectedHidden)
    }

    var body: some View {
        #if os(tvOS)
        tvDialog
        #elseif os(macOS)
        macDialog
        #else
        NavigationStack {
            Form {
                SwiftUI.Section {
                    ForEach(prompt.candidates, id: \.id) { candidate in
                        Toggle(isOn: bindingForVisible(candidate.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title)
                                Text(LibrarySectionKind(visibilityKindToken: candidate.kind).subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Show in Libraries")
                } footer: {
                    Text("Choose which libraries appear on the Libraries screen. Collections, folders, home-video, and trailer libraries are turned off by default — turn any back on to keep it. You can change this anytime in Settings.")
                }

                SwiftUI.Section {
                    Button("Show All") {
                        hidden.removeAll()
                    }
                    .disabled(hidden.isEmpty)
                }
            }
            .navigationTitle("Choose Libraries")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now", role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onConfirm(hidden) }
                }
            }
        }
        #endif
    }

    private func bindingForVisible(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(id) },
            set: { visible in
                if visible { hidden.remove(id) } else { hidden.insert(id) }
            }
        )
    }

    #if os(tvOS)
    private var tvDialog: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose Libraries")
                    .font(.title2.weight(.semibold))
                Text("Select the libraries that should appear in Labstream. You can change this later in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(prompt.candidates, id: \.id) { candidate in
                        Button {
                            let visible = !hidden.contains(candidate.id)
                            if visible {
                                hidden.insert(candidate.id)
                            } else {
                                hidden.remove(candidate.id)
                            }
                        } label: {
                            HStack(spacing: 20) {
                                Image(systemName: hidden.contains(candidate.id) ? "circle" : "checkmark.circle.fill")
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(LibrarySectionKind(visibilityKindToken: candidate.kind).subtitle)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                                Text(hidden.contains(candidate.id) ? "Hidden" : "Shown")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 540)

            HStack(spacing: 20) {
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                Spacer()

                Button("Save Selection") { onConfirm(hidden) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(64)
        .frame(maxWidth: 1120, maxHeight: 860)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35).ignoresSafeArea())
    }
    #endif

    #if os(macOS)
    private var macDialog: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Choose Libraries")
                    .font(.title2.weight(.semibold))
                Text("Pick which libraries should appear in Labstream. You can change this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(prompt.candidates.enumerated()), id: \.element.id) { index, candidate in
                        LibraryVisibilityMacRow(candidate: candidate,
                                                isVisible: bindingForVisible(candidate.id))

                        if index < prompt.candidates.count - 1 {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.5)
                }
                .padding(20)
            }
            .frame(minHeight: 180, maxHeight: 340)

            Divider()

            HStack(spacing: DS.Space.md) {
                Button("Show All") {
                    hidden.removeAll()
                }
                .disabled(hidden.isEmpty)

                Spacer()

                Button("Not Now", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button("Done") { onConfirm(hidden) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 520)
    }
    #endif
}

#if os(macOS)
private struct LibraryVisibilityMacRow: View {
    let candidate: LibraryVisibility.Candidate
    @Binding var isVisible: Bool

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(LibrarySectionKind(visibilityKindToken: candidate.kind).subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DS.Space.lg)

            Toggle("", isOn: $isVisible)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
#endif

/// Settings editor (#104): live per-library Show/Hide toggles for the active backend, persisting
/// to `LibraryVisibilityStore`. Re-fetches the current library list on appear so newly-added
/// server libraries surface (and default visible).
struct LibraryVisibilityEditor: View {
    @Environment(AppModel.self) private var appModel

    @State private var candidates: [LibraryVisibility.Candidate] = []
    @State private var hidden: Set<String> = []
    @State private var loadState: LoadState = .loading

    private let store = LibraryVisibilityStore()

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
        case unavailable
    }

    var body: some View {
        Form {
            switch loadState {
            case .loading:
                HStack { ProgressView(); Text("Loading libraries…").foregroundStyle(.secondary) }
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            case .unavailable:
                Text("Connect to a server to choose libraries.").foregroundStyle(.secondary)
            case .loaded:
                if candidates.isEmpty {
                    Text("This server has no libraries.").foregroundStyle(.secondary)
                } else {
                    SwiftUI.Section {
                        ForEach(candidates, id: \.id) { candidate in
                            Toggle(isOn: bindingForVisible(candidate.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.title)
                                    Text(LibrarySectionKind(visibilityKindToken: candidate.kind).subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } footer: {
                        Text("Turn a library off to hide it from the Libraries screen for this server. New libraries on the server appear automatically. Choices are kept separately per backend.")
                    }
                }
            }
        }
        .navigationTitle("Libraries")
        .task { await load() }
    }

    private func bindingForVisible(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(id) },
            set: { visible in
                hidden = store.toggle(id: id, hidden: !visible,
                                      forBackendKey: appModel.libraryVisibilityBackendKey)
            }
        )
    }

    private func load() async {
        appModel.migrateLibraryVisibilityKeysIfNeeded(store: store)
        let backendKey = appModel.libraryVisibilityBackendKey
        guard backendKey != nil else { loadState = .unavailable; return }
        hidden = store.hiddenIDs(forBackendKey: backendKey)
        do {
            candidates = try await fetchCandidates()
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }

    private func fetchCandidates() async throws -> [LibraryVisibility.Candidate] {
        switch appModel.activeBackend {
        case .plex:
            guard let service = try? PlexBrowseService(appModel: appModel) else {
                throw LibraryVisibilityEditorError.noServer
            }
            return try await service.libraries()
                .filter { !$0.isMusic }
                .map { LibraryVisibility.Candidate(id: $0.key, title: $0.title,
                                                   kind: LibrarySectionKind(plexType: $0.type).visibilityKindToken) }
        case .jellyfin:
            return try await JellyfinBrowseService(appModel: appModel).userViewLinks()
                .map { LibraryVisibility.Candidate(id: $0.id, title: $0.title,
                                                   kind: LibrarySectionKind(collectionType: $0.collectionType).visibilityKindToken) }
        case .emby:
            return try await EmbyBrowseService(appModel: appModel).userViewLinks()
                .map { LibraryVisibility.Candidate(id: $0.id, title: $0.title,
                                                   kind: LibrarySectionKind(collectionType: $0.collectionType).visibilityKindToken) }
        }
    }
}

private enum LibraryVisibilityEditorError: Error { case noServer }

/// Convenience init so the picker/editor can recover a `LibrarySectionKind` from a stored token.
extension LibrarySectionKind {
    init(visibilityKindToken token: String) {
        switch token.lowercased() {
        case "movies": self = .movies
        case "tvshows": self = .tvShows
        case "music": self = .music
        case "collections": self = .collections
        case "homevideos": self = .homeVideos
        case "livetv": self = .liveTV
        case "photos": self = .photos
        case "folders": self = .folders
        default: self = .other
        }
    }
}
