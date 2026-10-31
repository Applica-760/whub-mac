import AppKit

final class ExplorerContextMenu: NSMenu {
    enum Action {
        case trash
        case openInBrowser
        case showPreview
    }

    fileprivate enum Item {
        case newFile
        case newFolder
        case copyPath
        case copyRelativePath
        case showDiff
        case rename
        case trash
        case openInBrowser
        case showPreview

        var label: String {
            switch self {
            case .newFile: "New File"
            case .newFolder: "New Folder"
            case .copyPath: "Copy path"
            case .copyRelativePath: "Copy relative path"
            case .showDiff: "View Diffs"
            case .rename: "Rename"
            case .trash: "Move to Trash"
            case .openInBrowser: "Open in Browser"
            case .showPreview: "Show Preview"
            }
        }

        var selector: Selector {
            switch self {
            case .newFile: #selector(ExplorerContextMenu.createFile)
            case .newFolder: #selector(ExplorerContextMenu.createFolder)
            case .copyPath: #selector(ExplorerContextMenu.copyAbsolutePath)
            case .copyRelativePath: #selector(ExplorerContextMenu.copyRelativePath)
            case .showDiff: #selector(ExplorerContextMenu.showDiff)
            case .rename: #selector(ExplorerContextMenu.rename)
            case .trash: #selector(ExplorerContextMenu.trash)
            case .openInBrowser: #selector(ExplorerContextMenu.openInBrowser)
            case .showPreview: #selector(ExplorerContextMenu.showPreview)
            }
        }
    }

    private let onEdit: (ExplorerStore.NameEdit.Operation) -> Void
    private let onAction: (Action, FileLocation) -> Void
    private let location: FileLocation
    private let onShowDiff: (FileLocation) -> Void
    private let relativePath: String?

    init(location: FileLocation, isDirectory: Bool, basePath: String?, allowsActions: Bool = true,
         allowsFileOperations: Bool = true, createsOnly: Bool = false,
         onEdit: @escaping (ExplorerStore.NameEdit.Operation) -> Void = { _ in },
         onAction: @escaping (Action, FileLocation) -> Void = { _, _ in },
         onShowDiff: @escaping (FileLocation) -> Void) {
        self.onEdit = onEdit
        self.onAction = onAction
        self.location = location
        self.onShowDiff = onShowDiff
        if let basePath {
            let base = URL(fileURLWithPath: basePath, isDirectory: true).standardizedFileURL.path
            let prefix = base == "/" ? "/" : base + "/"
            relativePath = location.path.hasPrefix(prefix) ? String(location.path.dropFirst(prefix.count)) : nil
        } else {
            relativePath = nil
        }
        super.init(title: "")
        autoenablesItems = false
        let localActions = allowsActions && allowsFileOperations
        if localActions {
            add(.newFile)
            add(.newFolder)
            if createsOnly { return }
            addItem(.separator())
        }
        add(.copyPath)
        add(.copyRelativePath, enabled: relativePath != nil)
        addItem(.separator())
        add(.showDiff, enabled: !isDirectory)
        if localActions {
            add(.rename)
            add(.trash)
        }
        if allowsActions {
            if location.localURL != nil, !isDirectory, ["html", "htm"].contains((location.path as NSString).pathExtension.lowercased()) {
                add(.openInBrowser)
            } else if !isDirectory, EditorStore.supportsMarkdownPreview(location) {
                add(.showPreview)
            }
        }
    }

    private func add(_ entry: Item, enabled: Bool = true) {
        let item = NSMenuItem(title: entry.label, action: entry.selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        addItem(item)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func createFile() { onEdit(.newFile) }

    @objc private func createFolder() { onEdit(.newFolder) }

    @objc private func copyAbsolutePath() { copyPath(location.path) }

    @objc private func copyRelativePath() { copyPath(relativePath) }

    @objc private func showDiff() { onShowDiff(location) }

    @objc private func rename() { onEdit(.rename) }

    @objc private func trash() { onAction(.trash, location) }

    @objc private func openInBrowser() { onAction(.openInBrowser, location) }

    @objc private func showPreview() { onAction(.showPreview, location) }

    private func copyPath(_ path: String?) {
        guard let path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

extension ExplorerStore.NameEdit.Operation {
    var title: String {
        switch self {
        case .newFile: ExplorerContextMenu.Item.newFile.label
        case .newFolder: ExplorerContextMenu.Item.newFolder.label
        case .rename: ExplorerContextMenu.Item.rename.label
        }
    }
}
