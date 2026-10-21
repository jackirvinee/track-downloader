import AppKit
import QuickLook
import TrackDownloaderCore
import SwiftUI

struct DownloadedTracksView: View {
    @ObservedObject var store: DownloadedTrackStore
    @Binding var selection: URL?
    @State private var destination: LibraryDestination = .allTracks
    @State private var searchText = ""
    @State private var sort: LibrarySort = .recentlyAdded
    @State private var showingNewCrate = false
    @State private var newCrateName = ""
    @State private var crateBeingRenamed: TrackCrate?
    @State private var renamedCrateName = ""
    @State private var cratePendingDeletion: TrackCrate?
    @State private var waveformLoader = AudioWaveformLoader()
    @State private var previewURL: URL?
    private let toolbarMetrics = LibraryToolbarMetrics()

    init(store: DownloadedTrackStore, selection: Binding<URL?>) {
        self.store = store
        _selection = selection
    }

    private var tracks: [DownloadedTrack] {
        store.tracks(in: destination, matching: searchText, sortedBy: sort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                libraryHeader
                catalogueControls
                organizationNotice
            }
            .padding(12)
            Divider()
            libraryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let selectedTrack {
                Divider()
                LibrarySelectionDetailView(
                    track: selectedTrack,
                    waveformLoader: waveformLoader,
                    showInFinder: store.reveal,
                    findBetterSource: findBetterSource
                )
            }
        }
        .quickLookPreview($previewURL)
        .onAppear(perform: store.refresh)
        .onChange(of: visibleTrackURLs) { visibleURLs in
            if let selection, !visibleURLs.contains(selection) {
                self.selection = nil
            }
        }
        .alert("New Crate", isPresented: $showingNewCrate) {
            TextField("Crate name", text: $newCrateName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let crateID = store.createCrate(named: newCrateName) {
                    destination = .crate(crateID)
                }
            }
            .disabled(newCrateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Crates organize tracks inside the app without moving or renaming audio files.")
        }
        .alert(
            "Rename Crate",
            isPresented: Binding(
                get: { crateBeingRenamed != nil },
                set: { if !$0 { crateBeingRenamed = nil } }
            )
        ) {
            TextField("Crate name", text: $renamedCrateName)
            Button("Cancel", role: .cancel) { crateBeingRenamed = nil }
            Button("Rename") {
                if let crateBeingRenamed {
                    store.renameCrate(crateBeingRenamed.id, to: renamedCrateName)
                }
                crateBeingRenamed = nil
            }
            .disabled(renamedCrateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Delete \(cratePendingDeletion?.name ?? "Crate")?",
            isPresented: Binding(
                get: { cratePendingDeletion != nil },
                set: { if !$0 { cratePendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { cratePendingDeletion = nil }
            Button("Delete Crate", role: .destructive) {
                guard let cratePendingDeletion else { return }
                if store.deleteCrate(cratePendingDeletion.id) {
                    if destination == .crate(cratePendingDeletion.id) {
                        destination = .allTracks
                    }
                }
                self.cratePendingDeletion = nil
            }
        } message: {
            Text("Only this app's crate membership will be removed. Audio files will stay exactly where they are.")
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            Label("Library", systemImage: "music.note.list")
                .font(.headline)
            Text(store.tracks.count, format: .number)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: store.refresh) {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.isRefreshing)
            .help("Refresh library")
            .accessibilityLabel(store.isRefreshing ? "Refreshing library" : "Refresh library")
            Button("Open Downloads", systemImage: "folder", action: store.openOutputDirectory)
                .fixedSize()
        }
        .controlSize(.small)
    }

    private var catalogueControls: some View {
        HStack(spacing: toolbarMetrics.itemSpacing) {
            scopePicker

            TextField("Search tracks…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(
                    minWidth: toolbarMetrics.minimumSearchWidth,
                    idealWidth: toolbarMetrics.searchWidth(in: LibraryToolbarMetrics.minimumPaneWidth),
                    maxWidth: .infinity
                )
                .accessibilityLabel("Search downloaded tracks")

            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: toolbarMetrics.sortWidth)
            .accessibilityLabel("Sort downloaded tracks")

            crateActions
            columnsMenu
        }
        .controlSize(.small)
    }

    private var scopePicker: some View {
        Menu {
            Picker("Library Scope", selection: $destination) {
                Section("Library") {
                    ForEach(builtInDestinations, id: \.self) { scope in
                        Label(scope.title, systemImage: scope.systemImage)
                            .tag(scope)
                    }
                }

                if !store.crates.isEmpty {
                    Section("Crates") {
                        ForEach(store.crates) { crate in
                            Label(crate.name, systemImage: "shippingbox")
                                .tag(LibraryDestination.crate(crate.id))
                        }
                    }
                }
            }
        } label: {
            Label(destinationTitle, systemImage: destination.systemImage)
                .lineLimit(1)
        }
        .frame(width: toolbarMetrics.scopeWidth, alignment: .leading)
        .accessibilityLabel("Library scope")
    }

    private var crateActions: some View {
        Menu {
            Button("New Crate", systemImage: "plus") {
                newCrateName = ""
                showingNewCrate = true
            }

            if let selectedCrate {
                Divider()
                Button("Rename \(selectedCrate.name)", systemImage: "pencil") {
                    crateBeingRenamed = selectedCrate
                    renamedCrateName = selectedCrate.name
                }
                Button(role: .destructive) {
                    cratePendingDeletion = selectedCrate
                } label: {
                    Label("Delete \(selectedCrate.name)", systemImage: "trash")
                }
            }
        } label: {
            Label("Manage Crates", systemImage: "shippingbox")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: toolbarMetrics.iconButtonWidth)
        .help("Manage crates")
        .accessibilityLabel("Manage crates")
    }

    private var columnsMenu: some View {
        Menu {
            Text("Choose the fields shown in the Library table.")
            Divider()
            ForEach(CatalogueColumn.allCases) { column in
                Toggle(column.title, isOn: Binding(
                    get: { store.visibleCatalogueColumns.contains(column) },
                    set: { _ in store.toggleCatalogueColumn(column) }
                ))
                .accessibilityLabel("Show \(column.title) column")
            }
            Divider()
            Menu("Reorder Visible Columns") {
                ForEach(Array(store.visibleCatalogueColumns.enumerated()), id: \.element) { index, column in
                    Menu(column.title) {
                        Button("Move Earlier") {
                            moveVisibleColumn(column, from: index, earlier: true)
                        }
                        .disabled(index == 0)

                        Button("Move Later") {
                            moveVisibleColumn(column, from: index, earlier: false)
                        }
                        .disabled(index == store.visibleCatalogueColumns.count - 1)
                    }
                }
            }
        } label: {
            Label("Visible Columns", systemImage: "rectangle.split.3x1")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: toolbarMetrics.iconButtonWidth)
        .help("Visible columns")
        .accessibilityLabel("Visible library columns")
    }

    @ViewBuilder
    private var organizationNotice: some View {
        if let organizationNotice = store.organizationNotice {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(organizationNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Dismiss", systemImage: "xmark", action: store.dismissOrganizationNotice)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss library notice")
            }
        }
    }

    private var libraryPresentation: LibraryContentPresentation {
        LibraryContentPresentation.resolve(
            isOutputDirectoryAvailable: store.isOutputDirectoryAvailable,
            visibleTrackCount: tracks.count,
            hasSearchQuery: hasSearchQuery,
            destinationTitle: destinationTitle
        )
    }

    private var libraryContent: some View {
        ZStack(alignment: .topLeading) {
            catalogueTable
            libraryOverlay
        }
    }

    @ViewBuilder
    private var libraryOverlay: some View {
        switch libraryPresentation {
        case .populated:
            EmptyView()
        case .unavailable(let title, let detail):
            libraryState(title: title, detail: detail) {
                HStack(spacing: 8) {
                    Button("Refresh", action: store.refresh)
                    Button("Open Downloads", action: store.openOutputDirectory)
                }
            }
        case .noMatches(let title, let detail):
            libraryState(title: title, detail: detail) {
                Button("Clear Search") { searchText = "" }
            }
        case .empty(let title, let detail):
            libraryState(title: title, detail: detail) { EmptyView() }
        }
    }

    private var builtInDestinations: [LibraryDestination] {
        [
            LibraryDestination.allTracks,
            .recentlyAdded,
            .favorites,
            .needsMetadata,
        ]
        .filter(\.isBuiltIn)
    }

    private var selectedCrate: TrackCrate? {
        guard case .crate(let crateID) = destination else { return nil }
        return store.crates.first { $0.id == crateID }
    }

    private var destinationTitle: String {
        selectedCrate?.name ?? destination.title
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func libraryState<Actions: View>(title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            actions()
        }
        .padding(14)
        .accessibilityElement(children: .contain)
    }

    private func moveVisibleColumn(_ column: CatalogueColumn, from index: Int, earlier: Bool) {
        let columns = store.visibleCatalogueColumns
        guard columns.indices.contains(index) else { return }

        if earlier {
            guard index > 0 else { return }
            store.moveCatalogueColumn(column, before: columns[index - 1])
        } else {
            guard index < columns.count - 1 else { return }

            if index + 2 < columns.count {
                store.moveCatalogueColumn(column, before: columns[index + 2])
            } else {
                store.moveCatalogueColumn(columns[index + 1], before: column)
            }
        }
    }

    private var catalogueTable: some View {
        DownloadedTracksTable(tracks: tracks, columns: store.visibleCatalogueColumns, selection: $selection, artworkLoader: EmbeddedArtworkLoader(), waveformLoader: waveformLoader, preview: { previewURL = $0.fileURL })
        .frame(minHeight: 220, maxHeight: .infinity)
        .accessibilityLabel("Downloaded tracks catalogue")
    }

    private var visibleTrackURLs: [URL] { tracks.map(\.fileURL) }

    private var selectedTrack: DownloadedTrack? {
        guard let selection else { return nil }
        return tracks.first { $0.fileURL == selection }
    }

    private func findBetterSource(_ track: DownloadedTrack) {
        let terms = SearchLinkBuilder.terms(from: track.fileURL)
        SearchLinkBuilder.urls(for: terms).forEach { NSWorkspace.shared.open($0) }
    }
}
