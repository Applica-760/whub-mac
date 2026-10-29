import AppKit
import UniformTypeIdentifiers
import WhubGit

final class ExplorerItemView: NSTableCellView {
    private static let iconSize: CGFloat = 16
    private static let nameSpacing: CGFloat = 4

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
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.nameSpacing),
            name.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    var requiredWidth: CGFloat {
        Self.iconSize + Self.nameSpacing + (textField?.intrinsicContentSize.width ?? 0)
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
        imageView?.contentTintColor = nil
        if editingOperation == .newFolder {
            imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        } else if !item.isDirectory {
            imageView?.image = NSWorkspace.shared.icon(for: .data)
        } else if let url = item.location.localURL {
            imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            imageView?.image = NSWorkspace.shared.icon(for: .folder)
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
