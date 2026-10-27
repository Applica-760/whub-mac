import AppKit
import SwiftUI
import WhubGit

struct RemoteTreeGitView<Content: View>: View {
    @ObservedObject var git: RemoteGitStore
    let content: ([FileLocation: GitChange]) -> Content
    @State private var usageID = UUID()
    @Environment(\.isRetainedPageActive) private var isActive

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = git.watchError {
                Text(error).foregroundStyle(.secondary).padding(.horizontal)
                Button("再試行") { git.retry() }.padding(.horizontal)
            } else if let error = git.errorMessage {
                Text(error).foregroundStyle(.secondary).padding(.horizontal)
            }
            content(git.fileChanges)
        }
        .onAppear { git.setUsage(id: usageID, listVisible: isActive, visibleDiffPaths: []) }
        .onChange(of: isActive) { _, active in git.setUsage(id: usageID, listVisible: active, visibleDiffPaths: []) }
        .onDisappear { git.setUsage(id: usageID, listVisible: false, visibleDiffPaths: []) }
    }
}

struct ExplorerTreeView: View {
    @ObservedObject var store: ExplorerStore
    @ObservedObject var gitStore: GitStore
    var remoteChanges: [FileLocation: GitChange] = [:]
    let focus: ExplorerFocusNavigation
    let onFilePreview: (FileLocation) -> Void
    let onFileOpen: (FileLocation) -> Void
    let onShowDiff: (FileLocation) -> Void
    var onAction: (ExplorerContextMenu.Action, FileLocation) -> Void = { _, _ in }
    var onCommitName: () throws -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = store.errorMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            } else {
                if let message = gitStore.errorMessage {
                    Text(message).foregroundStyle(.secondary).padding(.horizontal)
                }
                if let message = store.watchError {
                    Text(message).foregroundStyle(.orange).padding(.horizontal)
                }
                if let message = store.directoryErrorMessage {
                    Text(message).foregroundStyle(.secondary).padding(.horizontal)
                }
                if case .remote = store.selectedLocation {
                    RemoteFileTreeStatusView(states: store.remoteTree.states)
                }
                ExplorerOutlineView(
                    store: store, basePath: store.treeBasePath, gitChanges: gitStore.changes, remoteChanges: remoteChanges, focus: focus,
                    onFilePreview: onFilePreview, onFileOpen: onFileOpen, onShowDiff: onShowDiff, onAction: onAction, onCommitName: onCommitName
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var store: ExplorerStore
    let basePath: String?
    let gitChanges: [URL: GitChange]
    let remoteChanges: [FileLocation: GitChange]
    let focus: ExplorerFocusNavigation
    let onFilePreview: (FileLocation) -> Void
    let onFileOpen: (FileLocation) -> Void
    let onShowDiff: (FileLocation) -> Void
    var onAction: (ExplorerContextMenu.Action, FileLocation) -> Void = { _, _ in }
    var onCommitName: () throws -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onFilePreview: onFilePreview, onFileOpen: onFileOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = FileOutlineControl()
        outlineView.backgroundColor = .clear
        outlineView.store = store
        outlineView.onShowDiff = onShowDiff
        outlineView.onAction = onAction
        outlineView.onOpenSelection = { [weak coordinator = context.coordinator] in
            coordinator?.openSelection()
        }
        focus.attachList(outlineView)
        outlineView.onEdit = { [weak coordinator = context.coordinator] action, item in
            coordinator?.beginEditing(action, item: item)
        }
        context.coordinator.onCommitName = onCommitName
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.autoresizesOutlineColumn = true
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.intercellSpacing = .zero
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.openSelectedFile(_:))
        context.coordinator.outlineView = outlineView
        context.coordinator.update(basePath: basePath, gitChanges: gitChanges, remoteChanges: remoteChanges)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        focus.list = scrollView.documentView as? NSTableView
        (scrollView.documentView as? FileOutlineControl)?.onShowDiff = onShowDiff
        (scrollView.documentView as? FileOutlineControl)?.onAction = onAction
        context.coordinator.onCommitName = onCommitName
        context.coordinator.onFilePreview = onFilePreview
        context.coordinator.onFileOpen = onFileOpen
        context.coordinator.update(basePath: basePath, gitChanges: gitChanges, remoteChanges: remoteChanges)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        weak var outlineView: NSOutlineView?
        var onFilePreview: (FileLocation) -> Void
        var onFileOpen: (FileLocation) -> Void
        private let store: ExplorerStore
        private var renderedRevision: Int?
        private var renderedEditingItem: ExplorerItem?
        private var renderedRootLocation: FileLocation?
        private var isRestoring = false
        var onCommitName: () throws -> Void = {}
        private var nameEdit: ExplorerStore.NameEdit? { store.nameEdit }

        func beginEditing(_ operation: ExplorerStore.NameEdit.Operation, item: ExplorerItem) {
            guard let outlineView else { return }
            store.beginNameEditing(operation, item: item, parent: outlineView.parent(forItem: item) as? ExplorerItem)
            guard let edit = nameEdit else { return }
            updateNameEditingDisplay()
            let row = outlineView.row(forItem: edit.item)
            if row >= 0 { outlineView.scrollRowToVisible(row) }
            focusName()
        }

        private func focusName() {
            guard let outlineView, let edit = nameEdit else { return }
            let row = outlineView.row(forItem: edit.item)
            guard row >= 0, let field = (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { return }
            field.selectText(nil)
        }

        func commitName(_ name: String) throws {
            guard nameEdit != nil else { return }
            store.updateName(name)
            try onCommitName()
            updateNameEditingDisplay()
        }

        func cancelEditing() {
            guard nameEdit != nil else { return }
            store.cancelNameEditing()
            updateNameEditingDisplay()
        }

        private func updateNameEditingDisplay() {
            guard let outlineView, renderedEditingItem !== nameEdit?.item else { return }
            renderedEditingItem = nameEdit?.item
            isRestoring = true
            defer { isRestoring = false }
            if nameEdit == nil {
                renderedRevision = nil
                outlineView.window?.makeFirstResponder(outlineView)
            }
            outlineView.reloadData()
            if let parent = nameEdit?.parent { outlineView.expandItem(parent) }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            store.updateName(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelEditing()
                return true
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let field = control as? NSTextField else { return false }
            do { try commitName(field.stringValue) }
            catch {
                EditorDialogs.show(error: error)
                focusName()
            }
            return true
        }

        init(store: ExplorerStore, onFilePreview: @escaping (FileLocation) -> Void, onFileOpen: @escaping (FileLocation) -> Void) {
            self.store = store
            self.onFilePreview = onFilePreview
            self.onFileOpen = onFileOpen
        }

        func update(basePath: String?, gitChanges: [URL: GitChange], remoteChanges: [FileLocation: GitChange] = [:]) {
            guard let outlineView else { return }
            (outlineView as? FileOutlineControl)?.basePath = basePath
            let rootChanged = renderedRootLocation != store.treeLocation
            updateNameEditingDisplay()
            if nameEdit != nil { return }
            let expandedLocations = Set(store.cachedItems.filter { outlineView.isItemExpanded($0) }.map(\.location))
            let selectedLocations = outlineView.selectedRowIndexes.compactMap {
                (outlineView.item(atRow: $0) as? ExplorerItem)?.location
            }
            let clipView = outlineView.enclosingScrollView?.contentView
            let origin = clipView?.bounds.origin ?? .zero
            let topRow = outlineView.row(at: NSPoint(x: 0, y: origin.y + 1))
            let topLocation = (outlineView.item(atRow: topRow) as? ExplorerItem)?.location
            let topOffset = topRow >= 0 ? origin.y - outlineView.rect(ofRow: topRow).minY : 0

            _ = store.updateTree(gitChanges: gitChanges, remoteChanges: remoteChanges)
            guard renderedRevision != store.contentRevision else { return }
            renderedRevision = store.contentRevision
            renderedRootLocation = store.treeLocation
            isRestoring = true
            defer { isRestoring = false }
            outlineView.reloadData()
            if rootChanged {
                expandChangedDirectories(in: store.rootItems, outlineView: outlineView)
            } else {
                restoreExpansion(in: store.rootItems, locations: expandedLocations, outlineView: outlineView)
                var selection = IndexSet()
                var scrollOrigin = origin
                for row in 0..<outlineView.numberOfRows {
                    guard let item = outlineView.item(atRow: row) as? ExplorerItem else { continue }
                    if selectedLocations.contains(item.location) { selection.insert(row) }
                    if item.location == topLocation { scrollOrigin.y = outlineView.rect(ofRow: row).minY + topOffset }
                }
                outlineView.selectRowIndexes(selection, byExtendingSelection: false)
                if let clipView {
                    let bounds = NSRect(origin: scrollOrigin, size: clipView.bounds.size)
                    clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
                    outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
                }
            }
        }

        private func restoreExpansion(in items: [ExplorerItem], locations: Set<FileLocation>, outlineView: NSOutlineView) {
            for item in items where item.isDirectory {
                if locations.contains(item.location) { outlineView.expandItem(item) }
                if locations.contains(where: { $0.path.hasPrefix(item.location.path + "/") }) {
                    restoreExpansion(in: store.children(for: item), locations: locations, outlineView: outlineView)
                }
            }
        }

        private func expandChangedDirectories(in items: [ExplorerItem], outlineView: NSOutlineView) {
            for item in items where item.isDirectory && store.decorations[item.location] != nil {
                outlineView.expandItem(item)
                expandChangedDirectories(in: store.children(for: item), outlineView: outlineView)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            store.displayedChildren(for: item as? ExplorerItem).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            store.displayedChildren(for: item as? ExplorerItem)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? ExplorerItem else { return false }
            return item.isDirectory && item !== nameEdit?.item && !store.isUnavailable(item)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let item = item as? ExplorerItem else { return false }
            return !store.isUnavailable(item)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let item = item as? ExplorerItem else { return false }
            return !store.isUnavailable(item)
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard !isRestoring, let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
            store.expand(item)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard
                !isRestoring, nameEdit == nil,
                let outlineView = notification.object as? NSOutlineView,
                let item = outlineView.item(atRow: outlineView.selectedRow) as? ExplorerItem,
                !item.isDirectory
            else {
                return
            }
            onFilePreview(item.location)
        }

        @objc func openSelectedFile(_ sender: NSOutlineView) {
            guard nameEdit == nil, let item = sender.item(atRow: sender.clickedRow) as? ExplorerItem, !item.isDirectory else { return }
            onFileOpen(item.location)
        }

        func openSelection() {
            guard nameEdit == nil, let outlineView,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? ExplorerItem,
                  !store.isUnavailable(item) else { return }
            if item.isDirectory {
                if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) }
                else { outlineView.expandItem(item) }
            } else { onFileOpen(item.location) }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let item = item as? ExplorerItem else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("file")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? ExplorerItemView)
                ?? ExplorerItemView(identifier: identifier)
            let edit = nameEdit?.item === item ? nameEdit : nil
            let location = item.location.localURL.map { FileLocation.local($0.standardizedFileURL) } ?? item.location
            cell.update(item: item, change: store.decorations[location],
                        unavailable: store.isUnavailable(item), editingName: edit?.name, editingOperation: edit?.operation)
            cell.textField?.delegate = edit == nil ? nil : self
            return cell
        }

    }
}

private final class FileOutlineControl: NSOutlineView {
    var basePath: String?
    weak var store: ExplorerStore?
    var onShowDiff: (FileLocation) -> Void = { _ in }
    var onAction: (ExplorerContextMenu.Action, FileLocation) -> Void = { _, _ in }

    var onEdit: (ExplorerStore.NameEdit.Operation, ExplorerItem) -> Void = { _, _ in }
    var onOpenSelection: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if store?.nameEdit == nil,
           handleExplorerNavigation(event, canSelect: { row in
               guard let item = self.item(atRow: row) as? ExplorerItem else { return false }
               return self.store?.isUnavailable(item) != true
           }, open: onOpenSelection) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = item(atRow: row) as? ExplorerItem else { return nil }

        return ExplorerContextMenu(location: item.location, isDirectory: item.isDirectory,
                                   basePath: basePath, allowsActions: store?.isUnavailable(item) != true,
                                   onEdit: { [weak self] operation in self?.onEdit(operation, item) },
                                   onAction: onAction, onShowDiff: onShowDiff)
    }

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard
            row >= 0,
            let item = item(atRow: row) as? ExplorerItem,
            item.isDirectory
        else {
            super.mouseDown(with: event)
            return
        }

        if (view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.isEditable == true {
            super.mouseDown(with: event)
            return
        }
        guard store?.isUnavailable(item) != true else { return }
        window?.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if isItemExpanded(item) {
            collapseItem(item)
        } else {
            expandItem(item)
        }
    }
}

extension NSTableView {
    func handleExplorerNavigation(_ event: NSEvent, canSelect: (Int) -> Bool = { _ in true },
                                  open: () -> Void) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        if event.keyCode == 36 || event.keyCode == 76 {
            open()
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard key == "j" || key == "k" else { return false }
        let offset = key == "j" ? 1 : -1
        var row = selectedRow >= 0 ? selectedRow + offset : (offset > 0 ? 0 : numberOfRows - 1)
        while row >= 0 && row < numberOfRows {
            if canSelect(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                scrollRowToVisible(row)
                break
            }
            row += offset
        }
        return true
    }
}

struct RemoteFileTreeStatusView: View {
    let states: [String: RemoteTreeStore.State]

    var body: some View {
        ForEach(states.keys.sorted(), id: \.self) { path in
            switch states[path] {
            case .loading:
                Text("\(path.isEmpty ? "ルート" : path)：取得中…")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            case let .failed(message):
                Text("\(path.isEmpty ? "ルート" : path)：\(message) — リロードで再取得")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            default: EmptyView()
            }
        }
    }
}
