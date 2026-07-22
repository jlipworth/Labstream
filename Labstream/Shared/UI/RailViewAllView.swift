import SwiftUI
import PMSKit

struct RailViewAllView: View {
    let destination: RailViewAllDestination
    @Environment(AppModel.self) private var appModel
    @Environment(\.labstreamCompactWidth) private var compactWidth
    @State private var model = RailPagingModel()

    private var source: RailPagingSource { RailPagingSource(destination: destination, appModel: appModel) }
    private var regularColumns: [GridItem] {
        [GridItem(.adaptive(minimum: DS.Poster.gridMin(compact: compactWidth),
                            maximum: DS.Poster.gridMax(compact: compactWidth)),
                  spacing: DS.gridGutter(compact: compactWidth))]
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                destinationContent(availableWidth: geometry.size.width)
            }
        }
        .navigationTitle(destination.title)
        .navigationDestination(for: MediaItem.self) { item in
            if item.isMusicContainer { musicDestination(for: item, sectionKey: nil) }
            else { DetailView(item: item, originBackend: destination.backend) }
        }
        .task(id: destination.id) { await model.loadInitial(source: source) }
        .refreshable { await model.refresh(source: source) }
    }

    @ViewBuilder
    private func destinationContent(availableWidth: CGFloat) -> some View {
            if model.isInitialLoading && model.items.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: 320)
            } else if let error = model.initialError, model.items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t load \(destination.title)", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Retry") { Task { await model.loadInitial(source: source) } }
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else if model.items.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                let metrics = compactGridMetrics(availableWidth: availableWidth)
                LazyVGrid(columns: gridColumns(metrics: metrics),
                          spacing: metrics?.rowSpacing ?? DS.Space.xxl) {
                    ForEach(Array(model.items.enumerated()), id: \.element.ratingKey) { index, item in
                        NavigationLink(value: item) {
                            PosterCell(item: item,
                                       width: metrics.map { CGFloat($0.posterWidth) },
                                       labelStyle: metrics == nil ? .standard : .denseLibrary)
                        }
                            .cardLink()
                            .videoCardContextMenu(for: item)
                            .onAppear {
                                guard index >= model.items.count - 10 else { return }
                                Task { await model.loadNext(source: source) }
                            }
                    }
                }
                .padding(.horizontal, metrics.map { CGFloat($0.horizontalPadding) }
                         ?? DS.pagePadding(compact: compactWidth))
                .padding(.vertical, metrics.map { CGFloat($0.horizontalPadding) }
                         ?? DS.pagePadding(compact: compactWidth))

                if model.isLoadingNext { ProgressView().padding() }
                if let error = model.nextError {
                    VStack(spacing: DS.Space.sm) {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Button("Retry") { Task { await model.retryNext(source: source) } }
                    }.padding()
                }
            }
    }

    private func compactGridMetrics(availableWidth: CGFloat) -> MobileViewAllGridLayout.Metrics? {
        guard compactWidth else { return nil }
        return MobileViewAllGridLayout.metrics(availableWidth: Double(availableWidth))
    }

    private func gridColumns(metrics: MobileViewAllGridLayout.Metrics?) -> [GridItem] {
        guard let metrics else { return regularColumns }
        return Array(repeating: GridItem(.fixed(CGFloat(metrics.posterWidth)),
                                         spacing: CGFloat(metrics.gutter)),
                     count: metrics.columnCount)
    }
}
