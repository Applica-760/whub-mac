import AppKit
import SwiftUI
import WhubCore

struct ExplorerDiffView: View {
    @ObservedObject var git: GitStore
    @ObservedObject var editor: EditorStore
    let focus: ExplorerFocusNavigation
    let onPreview: (FileLocation) -> Void
    let onOpen: (FileLocation) -> Void
    let onShowMarkdownPreview: (FileLocation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Git差分 · HEAD ↔ 保存済み").font(.caption).foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.mini)
                    .opacity(git.isLoadingDiff ? 1 : 0)
                    .accessibilityLabel("変更ファイルを読み込み中")
                    .accessibilityHidden(!git.isLoadingDiff)
            }
            if let error = git.diffError {
                Text(error).foregroundStyle(.secondary)
            } else if git.isLoadingDiff && git.diffChanges.isEmpty {
                Text("変更ファイルを読み込み中…").foregroundStyle(.secondary)
            } else if !git.isRepository {
                Text("Gitリポジトリを選択してください").foregroundStyle(.secondary)
            } else if git.diffChanges.isEmpty {
                Text("未コミットの差分はありません").foregroundStyle(.secondary)
            } else if let root = git.rootURL {
                DiffFileList(changes: git.diffChanges, root: root, selectedTab: editor.selectedTab, focus: focus,
                             onPreview: onPreview, onOpen: onOpen, onShowMarkdownPreview: onShowMarkdownPreview)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DiffFileList: NSViewRepresentable {
    let changes: [URL: GitChange]
    let root: URL
    let selectedTab: EditorTab?
    let focus: ExplorerFocusNavigation
    let onPreview: (FileLocation) -> Void
    let onOpen: (FileLocation) -> Void
    let onShowMarkdownPreview: (FileLocation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DiffTableControl()
        focus.attachList(table)
        table.onOpenSelection = { [weak coordinator = context.coordinator, weak table] in
            guard let coordinator, let table, coordinator.urls.indices.contains(table.selectedRow) else { return }
            coordinator.parent.onOpen(.local(coordinator.urls[table.selectedRow]))
        }
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: .init("path"))
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openFile(_:))
        table.menuForRow = { [weak coordinator = context.coordinator] row in
            guard let coordinator, coordinator.urls.indices.contains(row) else { return nil }
            return ExplorerContextMenu(location: .local(coordinator.urls[row]), isDirectory: false,
                                       basePath: coordinator.parent.root.path,
                                       onAction: { [weak coordinator] action, location in
                                           if case .showPreview = action { coordinator?.parent.onShowMarkdownPreview(location) }
                                       }, onShowDiff: coordinator.parent.onOpen)
        }
        table.setAccessibilityLabel("未コミットの変更ファイル")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.update(self, table: table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        focus.list = table
        context.coordinator.update(self, table: table)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DiffFileList
        var urls: [URL] = []
        private var updating = false

        init(_ parent: DiffFileList) { self.parent = parent }

        func update(_ parent: DiffFileList, table: NSTableView) {
            updating = true
            defer { updating = false }
            let changed = self.parent.changes != parent.changes || self.parent.root != parent.root || urls.isEmpty
            self.parent = parent
            if changed {
                urls = parent.changes.keys.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                table.reloadData()
            }
            if case let .diff(url) = parent.selectedTab, let row = urls.firstIndex(of: url) {
                if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            } else { table.deselectAll(nil) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let label = NSTextField(labelWithString: "")
            let url = urls[row]
            let prefix = parent.root.path == "/" ? "/" : parent.root.path + "/"
            let path = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
            let mark: String
            switch parent.changes[url] {
            case .added: mark = "A"; label.textColor = .systemGreen
            case .deleted: mark = "D"; label.textColor = .systemRed
            default: mark = "M"; label.textColor = .systemOrange
            }
            label.stringValue = "\(mark)  \(path)"
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = url.path
            return label
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView,
                  urls.indices.contains(table.selectedRow) else { return }
            parent.onPreview(.local(urls[table.selectedRow]))
        }

        @objc func openFile(_ table: NSTableView) {
            guard urls.indices.contains(table.clickedRow) else { return }
            parent.onOpen(.local(urls[table.clickedRow]))
        }
    }
}

private final class DiffTableControl: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?
    var onOpenSelection: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if handleExplorerNavigation(event, open: onOpenSelection) { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        menuForRow?(row(at: convert(event.locationInWindow, from: nil)))
    }
}
