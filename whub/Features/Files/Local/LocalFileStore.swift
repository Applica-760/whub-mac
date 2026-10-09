import AppKit
import Combine
import Foundation

final class LocalFileStore: ObservableObject {
    let fileURL: URL
    let document: FileStore
    @Published private(set) var diskMessage: String?
    @Published private(set) var diskRevision = 0
    private var savedData: Data?
    private(set) var isSaving = false
    private var documentChanges: AnyCancellable?

    init(fileURL: URL) {
        self.fileURL = fileURL
        let content: FileStore.Content
        do {
            let data = try Data(contentsOf: fileURL)
            savedData = data
            content = String(data: data, encoding: .utf8).map(FileStore.Content.text) ?? .binary
        } catch {
            content = .error(error.localizedDescription)
        }
        document = FileStore(content: content, isEditable: true)
        documentChanges = document.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        document.onContentChange = { [weak self] in
            guard self?.diskMessage != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.checkForExternalChanges() }
        }
        document.saveAction = { [weak self] in self?.saveWithConfirmation() }
        document.canSave = { [weak self] in
            guard let self else { return false }
            return document.savedSource != nil && !isSaving
        }
    }

    enum SaveError: LocalizedError {
        case changedOnDisk(Data)
        case unsupportedText

        var errorDescription: String? {
            switch self {
            case .changedOnDisk: "ファイルが外部で変更されています。"
            case .unsupportedText: "UTF-8テキストとして読み込めません。編集内容は保持されています。"
            }
        }
    }

    func confirmClose() -> Bool {
        guard !isSaving else { return false }
        guard !document.editorViews.values.contains(where: {
            ($0.documentView as? NSTextView)?.hasMarkedText() == true
        }) else { NSSound.beep(); return false }
        guard document.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "\(fileURL.lastPathComponent)の変更を保存しますか？"
        alert.informativeText = "保存せずに閉じると、編集内容は失われます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存せずに閉じる").keyEquivalent = ""
        alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveWithConfirmation() && !document.hasUnsavedChanges
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    @discardableResult
    func saveWithConfirmation() -> Bool {
        guard !isSaving else { return false }
        guard !document.editorViews.values.contains(where: {
            ($0.documentView as? NSTextView)?.hasMarkedText() == true
        }) else { NSSound.beep(); return false }
        isSaving = true
        defer { isSaving = false }
        var overwriteData: Data?
        do {
            while true {
                do {
                    try save(overwriting: overwriteData)
                    return true
                } catch let LocalFileStore.SaveError.changedOnDisk(data) {
                    let alert = NSAlert()
                    alert.messageText = "ファイルが外部で変更されています"
                    alert.informativeText = "\(fileURL.lastPathComponent)の編集内容を上書き保存するか、ディスクの最新内容を採用してください。"
                    alert.addButton(withTitle: "上書き")
                    alert.addButton(withTitle: "最新内容を採用")
                    alert.addButton(withTitle: "キャンセル")
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: overwriteData = data
                    case .alertSecondButtonReturn:
                        try adoptLatest()
                        return true
                    default: return false
                    }
                }
            }
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }


    func save(overwriting diskData: Data? = nil) throws {
        guard case let .text(source) = document.content, let savedData else { throw SaveError.unsupportedText }
        let target = fileURL.resolvingSymlinksInPath()
        let current = try Data(contentsOf: target)
        guard current == (diskData ?? savedData) else { throw SaveError.changedOnDisk(current) }
        guard source != document.savedSource || diskData != nil else { return }
        guard FileManager.default.isWritableFile(atPath: target.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var output = source
        let original = String(data: savedData, encoding: .utf8) ?? ""
        let withoutCRLF = original.replacingOccurrences(of: "\r\n", with: "")
        let lineEnding: String? = if original.contains("\r\n") && !withoutCRLF.contains("\r") && !withoutCRLF.contains("\n") {
            "\r\n"
        } else if !original.contains("\n") && original.contains("\r") {
            "\r"
        } else if !original.contains("\r") {
            "\n"
        } else {
            nil
        }
        if let lineEnding {
            output = source.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: lineEnding)
        }
        var data = Data(output.utf8)
        if savedData.starts(with: [0xef, 0xbb, 0xbf]) { data.insert(contentsOf: [0xef, 0xbb, 0xbf], at: 0) }
        try data.write(to: target, options: .atomic)
        self.savedData = data
        diskMessage = nil
        document.markSaved(source: source)
        diskRevision += 1
    }

    func adoptLatest() throws {
        let data = try Data(contentsOf: fileURL)
        guard let source = String(data: data, encoding: .utf8) else { throw SaveError.unsupportedText }
        apply(data: data, source: source)
    }

    func checkForExternalChanges() {
        do {
            let data = try Data(contentsOf: fileURL)
            guard data != savedData else { diskMessage = nil; return }
            guard !document.hasUnsavedChanges else {
                diskMessage = "ファイルが外部で変更されています。未保存の編集内容は保持されています。"
                return
            }
            guard !document.editorViews.values.contains(where: {
                ($0.documentView as? NSTextView)?.hasMarkedText() == true
            }) else {
                diskMessage = "ファイルが外部で変更されています。入力確定後に再確認します。"
                return
            }
            guard let source = String(data: data, encoding: .utf8) else {
                diskMessage = "外部変更後のファイルをUTF-8として読み込めません。"
                return
            }
            apply(data: data, source: source)
        } catch {
            diskMessage = "ファイルを再読み込みできません：\(error.localizedDescription)"
        }
    }

    private func apply(data: Data, source: String) {
        savedData = data
        diskMessage = nil
        document.replace(source: source)
        diskRevision += 1
    }
}
