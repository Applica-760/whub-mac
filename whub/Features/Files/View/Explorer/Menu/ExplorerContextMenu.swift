import AppKit

final class ExplorerContextMenu: NSMenu {
    enum Action: String {
        case trash = "Move to Trash"
        case openInBrowser = "Open in Browser"
    }

    private let onEdit: (ExplorerStore.NameEdit.Operation) -> Void
    private let onAction: (Action, FileLocation) -> Void
    private let location: FileLocation
    private let onShowDiff: (FileLocation) -> Void

    init(location: FileLocation, isDirectory: Bool, basePath: String?, allowsActions: Bool = true,
         onEdit: @escaping (ExplorerStore.NameEdit.Operation) -> Void = { _ in },
         onAction: @escaping (Action, FileLocation) -> Void = { _, _ in },
         onShowDiff: @escaping (FileLocation) -> Void) {
        self.onEdit = onEdit
        self.onAction = onAction
        self.location = location
        self.onShowDiff = onShowDiff
        super.init(title: "")
        autoenablesItems = false
        let localActions = location.localURL != nil && allowsActions
        if localActions {
            addNameAction(.newFile)
            addNameAction(.newFolder)
            addItem(.separator())
        }
        let absolute = NSMenuItem(title: "Copy path", action: #selector(copyPath(_:)), keyEquivalent: "")
        absolute.target = self
        absolute.representedObject = location.path
        addItem(absolute)
        let relative = NSMenuItem(title: "Copy relative path", action: #selector(copyPath(_:)), keyEquivalent: "")
        relative.target = self
        if let basePath {
            let base = URL(fileURLWithPath: basePath, isDirectory: true).standardizedFileURL.path
            let prefix = base == "/" ? "/" : base + "/"
            relative.representedObject = location.path.hasPrefix(prefix) ? String(location.path.dropFirst(prefix.count)) : nil
        }
        relative.isEnabled = relative.representedObject != nil
        addItem(relative)
        addItem(.separator())
        let diff = NSMenuItem(title: "View Diffs", action: #selector(showDiff), keyEquivalent: "")
        diff.target = self
        diff.isEnabled = location.localURL != nil && !isDirectory
        addItem(diff)
        if localActions {
            addNameAction(.rename)
            addAction(.trash)
            if !isDirectory, ["html", "htm"].contains((location.path as NSString).pathExtension.lowercased()) {
                addAction(.openInBrowser)
            }
        }
    }

    private func addNameAction(_ operation: ExplorerStore.NameEdit.Operation) {
        let item = NSMenuItem(title: operation.title, action: #selector(editName(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = operation
        addItem(item)
    }

    @objc private func editName(_ sender: NSMenuItem) {
        guard let operation = sender.representedObject as? ExplorerStore.NameEdit.Operation else { return }
        onEdit(operation)
    }

    private func addAction(_ action: Action) {
        let item = NSMenuItem(title: action.rawValue, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        addItem(item)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let action = Action(rawValue: value) else { return }
        onAction(action, location)
    }

    @objc private func showDiff() { onShowDiff(location) }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

extension ExplorerStore.NameEdit.Operation {
    var title: String {
        switch self {
        case .newFile: "New File"
        case .newFolder: "New Folder"
        case .rename: "Rename"
        }
    }
}
