import AppKit

final class ExplorerContextMenu: NSMenu {
    private let location: FileLocation
    private let onShowDiff: (FileLocation) -> Void

    init(location: FileLocation, isDirectory: Bool, basePath: String?, onShowDiff: @escaping (FileLocation) -> Void) {
        self.location = location
        self.onShowDiff = onShowDiff
        super.init(title: "")
        autoenablesItems = false
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
        let diff = NSMenuItem(title: "View Diffs", action: #selector(showDiff), keyEquivalent: "")
        diff.target = self
        diff.isEnabled = location.localURL != nil && !isDirectory
        addItem(diff)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func showDiff() { onShowDiff(location) }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
