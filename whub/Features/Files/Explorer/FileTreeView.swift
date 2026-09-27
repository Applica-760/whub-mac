import AppKit
import SwiftUI
import WhubCore

private let hiddenFileNames = [".git", ".DS_Store"]

struct FileTreeView: NSViewRepresentable {
    let rootURL: URL?
    let basePath: String?
    let gitChanges: [URL: GitChange]
    let refreshID: Int
    let onFilePreview: (URL) -> Void
    let onFileOpen: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFilePreview: onFilePreview, onFileOpen: onFileOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = FileOutlineControl()
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
        context.coordinator.update(rootURL: rootURL, basePath: basePath, gitChanges: gitChanges, refreshID: refreshID)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.onFilePreview = onFilePreview
        context.coordinator.onFileOpen = onFileOpen
        context.coordinator.update(rootURL: rootURL, basePath: basePath, gitChanges: gitChanges, refreshID: refreshID)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outlineView: NSOutlineView?
        var onFilePreview: (URL) -> Void
        var onFileOpen: (URL) -> Void
        private var rootURL: URL?
        private var rootItems: [FileItem] = []
        private var itemsByURL: [URL: FileItem] = [:]
        private var decorations: [URL: GitChange] = [:]
        private var refreshID = -1

        init(onFilePreview: @escaping (URL) -> Void, onFileOpen: @escaping (URL) -> Void) {
            self.onFilePreview = onFilePreview
            self.onFileOpen = onFileOpen
        }

        func update(rootURL: URL?, basePath: String?, gitChanges: [URL: GitChange], refreshID: Int) {
            (outlineView as? FileOutlineControl)?.basePath = basePath
            let rootChanged = self.rootURL != rootURL
            let refreshed = self.refreshID != refreshID
            let nextDecorations = Self.decorations(for: gitChanges, under: rootURL)
            guard rootChanged || refreshed || decorations != nextDecorations else { return }
            if rootChanged { itemsByURL.removeAll() }
            self.rootURL = rootURL
            self.refreshID = refreshID
            decorations = nextDecorations
            if rootChanged || refreshed {
                for item in itemsByURL.values { item.children = nil }
                rootItems = rootURL.map(directoryContents) ?? []
            }
            outlineView?.reloadData()
            if let outlineView {
                expandChangedDirectories(in: rootItems, outlineView: outlineView)
            }
        }

        private func expandChangedDirectories(in items: [FileItem], outlineView: NSOutlineView) {
            for item in items where item.isDirectory && decorations[item.url.standardizedFileURL] != nil {
                outlineView.expandItem(item)
                expandChangedDirectories(in: children(for: item), outlineView: outlineView)
            }
        }

        private static func decorations(for gitChanges: [URL: GitChange], under rootURL: URL?) -> [URL: GitChange] {
            guard let rootURL else { return [:] }
            let root = rootURL.standardizedFileURL
            var result = gitChanges
            for (url, change) in gitChanges {
                var parent = url.deletingLastPathComponent()
                while parent == root || parent.path.hasPrefix(root.path + "/") {
                    let current = result[parent]
                    result[parent] = (current == nil || current == .added) && change == .added ? .added : .modified
                    if parent == root { break }
                    parent = parent.deletingLastPathComponent()
                }
            }
            return result
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(for: item as? FileItem).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(for: item as? FileItem)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileItem)?.isDirectory == true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard
                let outlineView = notification.object as? NSOutlineView,
                let item = outlineView.item(atRow: outlineView.selectedRow) as? FileItem,
                !item.isDirectory
            else {
                return
            }
            onFilePreview(item.url)
        }

        @objc func openSelectedFile(_ sender: NSOutlineView) {
            guard let item = sender.item(atRow: sender.clickedRow) as? FileItem, !item.isDirectory else { return }
            onFileOpen(item.url)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let item = item as? FileItem else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("file")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? makeCell(identifier: identifier)
            cell.textField?.stringValue = item.url.lastPathComponent
            cell.textField?.textColor = switch decorations[item.url.standardizedFileURL] {
            case .added: .systemGreen
            case .modified, .deleted: .systemOrange
            case nil: item.url.lastPathComponent.hasPrefix(".") ? .secondaryLabelColor : .labelColor
            }
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            return cell
        }

        private func children(for item: FileItem?) -> [FileItem] {
            guard let item else { return rootItems }
            guard item.isDirectory else { return [] }
            if let children = item.children { return children }
            let children = directoryContents(at: item.url)
            item.children = children
            return children
        }

        private func directoryContents(at url: URL) -> [FileItem] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            return urls
                .filter { !hiddenFileNames.contains($0.lastPathComponent) }
                .map { url in
                    let key = url.standardizedFileURL
                    let item = FileItem(url: url)
                    if let existing = itemsByURL[key], existing.isDirectory == item.isDirectory {
                        return existing
                    }
                    itemsByURL[key] = item
                    return item
                }
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = item(atRow: row) as? FileItem else { return nil }

        let path = item.url.standardizedFileURL.path
        let menu = NSMenu()
        let absolute = NSMenuItem(title: "Copy path", action: #selector(copyPath(_:)), keyEquivalent: "")
        absolute.target = self
        absolute.representedObject = path
        menu.addItem(absolute)

        let relative = NSMenuItem(title: "Copy relative path", action: #selector(copyPath(_:)), keyEquivalent: "")
        relative.target = self
        if let basePath {
            let base = URL(fileURLWithPath: basePath, isDirectory: true).standardizedFileURL.path
            let prefix = base == "/" ? "/" : base + "/"
            relative.representedObject = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
        relative.isEnabled = relative.representedObject != nil
        menu.addItem(relative)
        return menu
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard
            row >= 0,
            let item = item(atRow: row) as? FileItem,
            item.isDirectory
        else {
            super.mouseDown(with: event)
            return
        }

        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if isItemExpanded(item) {
            collapseItem(item)
        } else {
            expandItem(item)
        }
    }
}

private final class FileItem: NSObject {
    let url: URL
    let isDirectory: Bool
    var children: [FileItem]?

    init(url: URL) {
        self.url = url
        isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
