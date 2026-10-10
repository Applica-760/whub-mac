import AppKit
import SwiftUI
import WhubCore

struct ExplorerTreeView: View {
    @ObservedObject var store: ExplorerStore
    @ObservedObject var gitStore: GitStore
    let onFilePreview: (FileLocation) -> Void
    let onFileOpen: (FileLocation) -> Void
    let onShowDiff: (FileLocation) -> Void

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
                    store: store, basePath: store.treeBasePath, gitChanges: gitStore.changes,
                    onFilePreview: onFilePreview, onFileOpen: onFileOpen, onShowDiff: onShowDiff
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
    let onFilePreview: (FileLocation) -> Void
    let onFileOpen: (FileLocation) -> Void
    let onShowDiff: (FileLocation) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onFilePreview: onFilePreview, onFileOpen: onFileOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = FileOutlineControl()
        outlineView.store = store
        outlineView.onShowDiff = onShowDiff
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
        context.coordinator.update(basePath: basePath, gitChanges: gitChanges)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.documentView as? FileOutlineControl)?.onShowDiff = onShowDiff
        context.coordinator.onFilePreview = onFilePreview
        context.coordinator.onFileOpen = onFileOpen
        context.coordinator.update(basePath: basePath, gitChanges: gitChanges)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outlineView: NSOutlineView?
        var onFilePreview: (FileLocation) -> Void
        var onFileOpen: (FileLocation) -> Void
        private let store: ExplorerStore
        private var renderedRevision: Int?
        private var renderedRootLocation: FileLocation?
        private var isRestoring = false

        init(store: ExplorerStore, onFilePreview: @escaping (FileLocation) -> Void, onFileOpen: @escaping (FileLocation) -> Void) {
            self.store = store
            self.onFilePreview = onFilePreview
            self.onFileOpen = onFileOpen
        }

        func update(basePath: String?, gitChanges: [URL: GitChange]) {
            guard let outlineView else { return }
            (outlineView as? FileOutlineControl)?.basePath = basePath
            let rootChanged = renderedRootLocation != store.treeLocation
            let expandedLocations = Set(store.cachedItems.filter { outlineView.isItemExpanded($0) }.map(\.location))
            let selectedLocations = outlineView.selectedRowIndexes.compactMap {
                (outlineView.item(atRow: $0) as? ExplorerItem)?.location
            }
            let clipView = outlineView.enclosingScrollView?.contentView
            let origin = clipView?.bounds.origin ?? .zero
            let topRow = outlineView.row(at: NSPoint(x: 0, y: origin.y + 1))
            let topLocation = (outlineView.item(atRow: topRow) as? ExplorerItem)?.location
            let topOffset = topRow >= 0 ? origin.y - outlineView.rect(ofRow: topRow).minY : 0

            _ = store.updateTree(gitChanges: gitChanges)
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
            for item in items where item.isDirectory && item.location.localURL.flatMap({ store.decorations[$0.standardizedFileURL] }) != nil {
                outlineView.expandItem(item)
                expandChangedDirectories(in: store.children(for: item), outlineView: outlineView)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            store.children(for: item as? ExplorerItem).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            store.children(for: item as? ExplorerItem)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? ExplorerItem else { return false }
            return item.isDirectory && !store.isUnavailable(item)
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
            guard !isRestoring, let item = notification.userInfo?["NSObject"] as? ExplorerItem,
                  case .remote = item.location else { return }
            store.remoteTree.loadChildren(of: item)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard
                !isRestoring,
                let outlineView = notification.object as? NSOutlineView,
                let item = outlineView.item(atRow: outlineView.selectedRow) as? ExplorerItem,
                !item.isDirectory
            else {
                return
            }
            onFilePreview(item.location)
        }

        @objc func openSelectedFile(_ sender: NSOutlineView) {
            guard let item = sender.item(atRow: sender.clickedRow) as? ExplorerItem, !item.isDirectory else { return }
            onFileOpen(item.location)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let item = item as? ExplorerItem else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("file")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? makeCell(identifier: identifier)
            let unavailable = store.isUnavailable(item)
            cell.textField?.attributedStringValue = NSAttributedString(
                string: item.location.name,
                attributes: unavailable ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue] : [:]
            )
            cell.toolTip = unavailable ? "上部のメニューからProjectまたはWorktreeを選択してください。" : nil
            cell.textField?.textColor = switch item.location.localURL.flatMap({ store.decorations[$0.standardizedFileURL] }) {
            case .added: .systemGreen
            case .modified, .deleted: .systemOrange
            case nil: item.location.name.hasPrefix(".") ? .secondaryLabelColor : .labelColor
            }
            if unavailable { cell.textField?.textColor = .disabledControlTextColor }
            cell.imageView?.alphaValue = unavailable ? 0.4 : 1
            if let url = item.location.localURL {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                cell.imageView?.image = NSImage(systemSymbolName: item.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil)
            }
            return cell
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.usesSingleLineMode = true
            textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}

private final class FileOutlineControl: NSOutlineView {
    var basePath: String?
    weak var store: ExplorerStore?
    var onShowDiff: (FileLocation) -> Void = { _ in }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = item(atRow: row) as? ExplorerItem else { return nil }

        return ExplorerContextMenu(location: item.location, isDirectory: item.isDirectory,
                                   basePath: basePath, onShowDiff: onShowDiff)
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

        guard store?.isUnavailable(item) != true else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if isItemExpanded(item) {
            collapseItem(item)
        } else {
            expandItem(item)
        }
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
