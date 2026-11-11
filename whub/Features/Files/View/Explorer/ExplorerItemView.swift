import AppKit
import UniformTypeIdentifiers
import WhubGit

final class ExplorerItemView: NSTableCellView {
    private(set) var nameField: NSTextField?
    let disclosureImage = NSImageView()
    private static let disclosureWidth: CGFloat = 16
    private static let iconSize: CGFloat = 16
    private static let nameSpacing: CGFloat = 4

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        disclosureImage.translatesAutoresizingMaskIntoConstraints = false
        disclosureImage.contentTintColor = .secondaryLabelColor
        disclosureImage.setAccessibilityElement(false)
        addSubview(disclosureImage)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        imageView = icon

        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingTail
        name.usesSingleLineMode = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(name)
        nameField = name

        NSLayoutConstraint.activate([
            disclosureImage.leadingAnchor.constraint(equalTo: leadingAnchor),
            disclosureImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureImage.widthAnchor.constraint(equalToConstant: Self.disclosureWidth),
            disclosureImage.heightAnchor.constraint(equalToConstant: Self.iconSize),
            icon.leadingAnchor.constraint(equalTo: disclosureImage.trailingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.nameSpacing),
            name.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    var requiredWidth: CGFloat {
        Self.disclosureWidth + Self.iconSize + Self.nameSpacing + (nameField?.intrinsicContentSize.width ?? 0)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateDisclosure(expandable: Bool, expanded: Bool) {
        disclosureImage.image = expandable
            ? NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            : nil
    }

    func update(item: ExplorerItem, change: GitChange?, unavailable: Bool,
                editingName: String?, editingOperation: ExplorerStore.NameEdit.Operation?) {
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
        if unavailable { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        nameField?.attributedStringValue = NSAttributedString(string: item.location.name, attributes: attributes)
        toolTip = unavailable ? "上部のメニューからProjectまたはWorktreeを選択してください。" : nil
        nameField?.textColor = switch change {
        case .added: .systemGreen
        case .modified, .deleted: .systemOrange
        case nil: item.location.name.hasPrefix(".") ? .secondaryLabelColor : .labelColor
        }
        if unavailable { nameField?.textColor = .disabledControlTextColor }
        imageView?.alphaValue = unavailable ? 0.4 : 1
        imageView?.contentTintColor = nil
        if editingOperation == .newFolder {
            imageView?.image = NSWorkspace.shared.icon(for: .folder)
        } else if !item.isDirectory {
            imageView?.image = NSWorkspace.shared.icon(for: .data)
        } else if let url = item.location.localURL {
            imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            imageView?.image = NSWorkspace.shared.icon(for: .folder)
        }
        let editing = editingName != nil
        nameField?.isEditable = editing
        nameField?.isSelectable = editing
        nameField?.isBezeled = editing
        nameField?.drawsBackground = editing
        nameField?.placeholderString = editingOperation?.title
        nameField?.setAccessibilityLabel(editingOperation?.title)
        if let editingName {
            nameField?.stringValue = editingName
            nameField?.textColor = .labelColor
        }
    }
}
