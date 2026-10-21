import AppKit
import SwiftUI
import TrackDownloaderCore

struct DownloadedTracksTable: NSViewRepresentable {
    let tracks: [DownloadedTrack]
    let columns: [CatalogueColumn]
    @Binding var selection: URL?
    let artworkLoader: any EmbeddedArtworkLoading
    let waveformLoader: any AudioWaveformLoading
    let preview: (DownloadedTrack) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.headerView = NSTableHeaderView()
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.backgroundColor = .controlBackgroundColor
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.previewSelectedTrack)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.tableView = table
        context.coordinator.rebuildColumns(columns)
        return scroll
    }
    func updateNSView(_ scrollView: NSScrollView, context: Context) { context.coordinator.parent = self; context.coordinator.rebuildColumns(columns); context.coordinator.reloadRowsAndRestoreSelection() }
    func textCell(for track: DownloadedTrack, column: CatalogueColumn, tableColumn: NSTableColumn) -> NSView {
        let view = NSTableCellView()
        view.identifier = tableColumn.identifier
        let field = NSTextField(labelWithString: CatalogueCellPresentation.text(for: track, column: column))
        field.frame = NSRect(x: 4, y: 11, width: max(0, tableColumn.width - 8), height: 18)
        field.font = column == .format ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium) : .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = CatalogueCellPresentation.accessibilityText(for: track, column: column)
        field.setAccessibilityLabel(field.toolTip)
        view.textField = field
        view.addSubview(field)
        return view
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DownloadedTracksTable; weak var tableView: NSTableView?
        init(parent: DownloadedTracksTable) { self.parent = parent }
        func rebuildColumns(_ requested: [CatalogueColumn]) {
            guard let tableView else { return }; let current = tableView.tableColumns.map { $0.identifier.rawValue }; let desired = requested.map(\.rawValue); guard current != desired else { return }
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            for column in requested { let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue)); item.title = column.title; item.width = width(for: column); item.minWidth = minWidth(for: column); tableView.addTableColumn(item) }
        }
        func reloadRowsAndRestoreSelection() { guard let tableView else { return }; tableView.reloadData(); if let selection = parent.selection, let row = parent.tracks.firstIndex(where: { $0.fileURL == selection }) { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.tracks.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, parent.tracks.indices.contains(row), let column = CatalogueColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let track = parent.tracks[row]
            switch column {
            case .artwork:
                return NSHostingView(rootView: CatalogueArtworkThumbnail(
                    fileURL: track.fileURL,
                    artworkLoader: parent.artworkLoader
                ))
            case .waveform:
                return NSHostingView(rootView: CatalogueWaveformThumbnail(
                    fileURL: track.fileURL,
                    waveformLoader: parent.waveformLoader
                ))
            default:
                return parent.textCell(for: track, column: column, tableColumn: tableColumn)
            }
        }
        func tableViewSelectionDidChange(_ notification: Notification) { guard let tableView, tableView.selectedRow >= 0, parent.tracks.indices.contains(tableView.selectedRow) else { parent.selection = nil; return }; parent.selection = parent.tracks[tableView.selectedRow].fileURL }
        @objc func previewSelectedTrack() { guard let tableView, parent.tracks.indices.contains(tableView.clickedRow) else { return }; parent.preview(parent.tracks[tableView.clickedRow]) }
        private func width(for column: CatalogueColumn) -> CGFloat { switch column { case .artwork: 42; case .track: 180; case .waveform: 100; case .artist, .album: 120; case .genre, .source: 110; case .format, .quality, .codec: 70; case .added, .duration, .bitrate, .sampleRate, .fileSize: 86 } }
        private func minWidth(for column: CatalogueColumn) -> CGFloat { switch column { case .artwork: 36; case .waveform: 84; default: 44 } }
    }
}
