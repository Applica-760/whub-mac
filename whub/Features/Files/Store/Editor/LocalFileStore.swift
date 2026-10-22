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

    var blocksFileOperation: Bool {
        document.hasUnsavedChanges || document.editorViews.hasMarkedText || isSaving
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let content: FileStore.Content
        do {
            let data = try Data(contentsOf: fileURL)
            savedData = data
            content = FileEncoding.decode(data).map(FileStore.Content.text) ?? .binary
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
        guard !document.editorViews.hasMarkedText else { EditorDialogs.beep(); return false }
        guard document.hasUnsavedChanges else { return true }
        switch EditorDialogs.confirmClose(fileName: fileURL.lastPathComponent) {
        case .save: return saveWithConfirmation() && !document.hasUnsavedChanges
        case .discard: return true
        case .cancel: return false
        }
    }

    @discardableResult
    func saveWithConfirmation() -> Bool {
        guard !isSaving else { return false }
        guard !document.editorViews.hasMarkedText else { EditorDialogs.beep(); return false }
        isSaving = true
        defer { isSaving = false }
        var overwriteData: Data?
        do {
            while true {
                do {
                    try save(overwriting: overwriteData)
                    return true
                } catch let LocalFileStore.SaveError.changedOnDisk(data) {
                    switch EditorDialogs.confirmOverwrite(fileName: fileURL.lastPathComponent) {
                    case .overwrite: overwriteData = data
                    case .adoptLatest:
                        try adoptLatest()
                        return true
                    case .cancel: return false
                    }
                }
            }
        } catch {
            EditorDialogs.show(error: error)
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
        let data = FileEncoding.encode(source, preserving: savedData)
        try data.write(to: target, options: .atomic)
        self.savedData = data
        diskMessage = nil
        document.markSaved(source: source)
        diskRevision += 1
    }

    func adoptLatest() throws {
        let data = try Data(contentsOf: fileURL)
        guard let source = FileEncoding.decode(data) else { throw SaveError.unsupportedText }
        apply(data: data, source: source)
    }

    func checkForExternalChanges() {
        do {
            let data = try Data(contentsOf: fileURL)
            guard data != savedData else { diskMessage = nil; return }
            guard !document.hasUnsavedChanges else {
                diskMessage = "ファイルが外部で変更されています。編集内容は保持されています。本文で⌘Sを押すと「最新内容を採用」を選べます。"
                return
            }
            guard !document.editorViews.hasMarkedText else {
                diskMessage = "ファイルが外部で変更されています。入力確定後に再確認します。"
                return
            }
            guard let source = FileEncoding.decode(data) else {
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
