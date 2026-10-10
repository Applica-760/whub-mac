import AppKit
import WhubCore

final class ExplorerItemView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        imageView = icon

        let name = NSTextField(labelWithString: "")
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingTail
        name.usesSingleLineMode = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(name)
        textField = name

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(item: ExplorerItem, change: GitChange?, unavailable: Bool,
                editingName: String?, editingOperation: ExplorerStore.NameEdit.Operation?) {
        textField?.attributedStringValue = NSAttributedString(
            string: item.location.name,
            attributes: unavailable ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue] : [:]
        )
        toolTip = unavailable ? "上部のメニューからProjectまたはWorktreeを選択してください。" : nil
        textField?.textColor = switch change {
        case .added: .systemGreen
        case .modified, .deleted: .systemOrange
        case nil: item.location.name.hasPrefix(".") ? .secondaryLabelColor : .labelColor
        }
        if unavailable { textField?.textColor = .disabledControlTextColor }
        imageView?.alphaValue = unavailable ? 0.4 : 1
        if editingOperation == .newFolder {
            imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        } else if let url = item.location.localURL {
            imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            imageView?.image = NSImage(systemSymbolName: item.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil)
        }
        let editing = editingName != nil
        textField?.isEditable = editing
        textField?.isSelectable = editing
        textField?.isBezeled = editing
        textField?.drawsBackground = editing
        textField?.placeholderString = editingOperation?.title
        textField?.setAccessibilityLabel(editingOperation?.title)
        if let editingName {
            textField?.stringValue = editingName
            textField?.textColor = .labelColor
        }
    }
}
