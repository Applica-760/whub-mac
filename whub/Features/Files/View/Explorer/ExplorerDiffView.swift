import AppKit
import SwiftUI
import WhubClient
import WhubGit

struct RemoteExplorerDiffView: View {
    @ObservedObject var git: RemoteGitStore
    @ObservedObject var editor: EditorStore
    let focus: ExplorerFocusNavigation
    let onPreview: (FileLocation) -> Void
    let onOpen: (FileLocation) -> Void
    let onShowMarkdownPreview: (FileLocation) -> Void
    @State private var usageID = UUID()
    @Environment(\.isRetainedPageActive) private var isActive

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Git差分 · HEAD ↔ 保存済み").font(.caption).foregroundStyle(.secondary)
                if git.isLoading { ProgressView().controlSize(.mini) }
            }
            if !git.isConnected {
                Text("接続されていません").foregroundStyle(.secondary)
            } else if let error = git.watchError {
                Text(error).foregroundStyle(.secondary)
                Button("再試行") { git.retry() }
            } else if let error = git.errorMessage {
                Text(error).foregroundStyle(.secondary)
            } else if git.isLoading && git.changes.isEmpty {
                Text("変更ファイルを読み込み中…").foregroundStyle(.secondary)
            } else if git.changes.isEmpty {
                Text("未コミットの差分はありません").foregroundStyle(.secondary)
            } else {
                DiffFileList(changes: git.fileChanges, root: git.root, selectedTab: editor.selectedTab, focus: focus,
                onPreview: onPreview, onOpen: onOpen, onShowMarkdownPreview: onShowMarkdownPreview)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { git.setUsage(id: usageID, listVisible: isActive, visibleDiffPaths: []) }
        .onChange(of: isActive) { _, active in git.setUsage(id: usageID, listVisible: active, visibleDiffPaths: []) }
        .onDisappear { git.setUsage(id: usageID, listVisible: false, visibleDiffPaths: []) }
    }
}

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
                DiffFileList(changes: Dictionary(uniqueKeysWithValues: git.diffChanges.map { (.local($0.key), $0.value) }), root: .local(root), selectedTab: editor.selectedTab, focus: focus,
                             onPreview: onPreview, onOpen: onOpen, onShowMarkdownPreview: onShowMarkdownPreview)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DiffFileList: NSViewRepresentable {
    let changes: [FileLocation: GitChange]
    let root: FileLocation
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
            guard let coordinator, let table, coordinator.locations.indices.contains(table.selectedRow) else { return }
            coordinator.parent.onOpen(coordinator.locations[table.selectedRow])
        }
        table.backgroundColor = .clear
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("path"))
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openFile(_:))
        table.menuForRow = { [weak coordinator = context.coordinator] row in
            guard let coordinator, coordinator.locations.indices.contains(row) else { return nil }
            return ExplorerContextMenu(location: coordinator.locations[row], isDirectory: false,
                                       basePath: coordinator.parent.root.path, allowsFileOperations: false,
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
        scroll.hasHorizontalScroller = true
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
        var locations: [FileLocation] = []
        private var updating = false

        init(_ parent: DiffFileList) { self.parent = parent }

        func update(_ parent: DiffFileList, table: NSTableView) {
            updating = true
            defer { updating = false }
            let changed = self.parent.changes != parent.changes || self.parent.root != parent.root || locations.isEmpty
            self.parent = parent
            if changed {
                locations = parent.changes.keys.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                table.reloadData()
                let width = locations.indices.map { row in
                    makeLabel(row: row).intrinsicContentSize.width
                }.max() ?? 0
                table.fitExplorerColumn(to: width + 8)
            }
            if case let .diff(location) = parent.selectedTab, let row = locations.firstIndex(of: location) {
                if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            } else { table.deselectAll(nil) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { locations.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            makeLabel(row: row)
        }

        private func makeLabel(row: Int) -> NSTextField {
            let label = NSTextField(labelWithString: "")
            let location = locations[row]
            let prefix = parent.root.path == "/" ? "/" : parent.root.path + "/"
            let path = location.path.hasPrefix(prefix) ? String(location.path.dropFirst(prefix.count)) : location.path
            let mark: String
            switch parent.changes[location] {
            case .added: mark = "A"; label.textColor = .systemGreen
            case .deleted: mark = "D"; label.textColor = .systemRed
            default: mark = "M"; label.textColor = .systemOrange
            }
            label.stringValue = "\(mark)  \(path)"
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = location.path
            return label
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView,
                  locations.indices.contains(table.selectedRow) else { return }
            parent.onPreview(locations[table.selectedRow])
        }

        @objc func openFile(_ table: NSTableView) {
            guard locations.indices.contains(table.clickedRow) else { return }
            parent.onOpen(locations[table.clickedRow])
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
