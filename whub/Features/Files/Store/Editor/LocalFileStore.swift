import Combine
import Foundation

final class LocalFileStore: ObservableObject {
    let fileURL: URL
    let document: EditContentStore
    @Published private(set) var diskMessage: String?
    @Published private(set) var diskRevision = 0
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    private let io: LocalFileIO
    private var savedData: Data?
    private var external: LocalFileIO.Content?
    private var documentChanges: AnyCancellable?
    private var readTask: Task<Void, Never>?
    private var needsRead = false
    private var generation = 0
    private var editRevision = 0
    private var isClosed = false

    var blocksFileOperation: Bool {
        document.hasUnsavedChanges || document.editorViews.hasMarkedText || isSaving
    }

    init(fileURL: URL, io: LocalFileIO = LocalFileIO()) {
        self.fileURL = fileURL
        self.io = io
        document = EditContentStore(content: .error(""), isEditable: true)
        document.isFileOperationLocked = true
        documentChanges = document.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        document.onContentChange = { [weak self] in
            guard let self else { return }
            editRevision += 1
            guard external != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, readTask == nil else { return }
                reconcileExternalContent()
            }
        }
        document.saveAction = { [weak self] in Task { await self?.saveWithConfirmation() } }
        document.canSave = { [weak self] in
            guard let self else { return false }
            return document.savedSource != nil && !isSaving && !isLoading && !isClosed
        }
        checkForExternalChanges()
    }

    nonisolated enum SaveError: LocalizedError {
        case changedOnDisk(Data)
        case unsupportedText
        case busy
        case editedWhileReading

        var errorDescription: String? {
            switch self {
            case .changedOnDisk: "ファイルが外部で変更されています。"
            case .unsupportedText: "UTF-8テキストとして読み込めません。編集内容は保持されています。"
            case .busy: "ファイルの読み込みまたは保存中です。"
            case .editedWhileReading: "読み込み中に編集されたため、最新内容の採用を中止しました。編集内容は保持されています。"
            }
        }
    }

    func confirmClose(choice: EditorDialogs.CloseChoice? = nil) async -> Bool {
        guard !isSaving else { return false }
        guard !document.editorViews.hasMarkedText else { EditorDialogs.beep(); return false }
        guard document.hasUnsavedChanges else { return true }
        switch choice ?? EditorDialogs.confirmClose(fileName: fileURL.lastPathComponent) {
        case .save:
            let saved = await saveWithConfirmation()
            return saved && !document.hasUnsavedChanges && !document.editorViews.hasMarkedText
        case .discard: return true
        case .cancel: return false
        }
    }

    @discardableResult
    func saveWithConfirmation() async -> Bool {
        guard !isSaving, !isLoading, !isClosed else { return false }
        guard !document.editorViews.hasMarkedText else { EditorDialogs.beep(); return false }
        var overwriteData: Data?
        do {
            while true {
                do {
                    try await save(overwriting: overwriteData)
                    return true
                } catch let LocalFileStore.SaveError.changedOnDisk(data) {
                    switch EditorDialogs.confirmOverwrite(fileName: fileURL.lastPathComponent) {
                    case .overwrite: overwriteData = data
                    case .adoptLatest:
                        try await adoptLatest()
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

    func save(overwriting diskData: Data? = nil) async throws {
        guard !isSaving, !isLoading, !isClosed else { throw SaveError.busy }
        guard case let .text(source) = document.content, let savedData else { throw SaveError.unsupportedText }
        beginSaving()
        defer { finishSaving() }
        let data = try await io.save(fileURL, source: source, savedSource: document.savedSource,
                                     savedData: savedData, overwriting: diskData)
        guard let data else { return }
        self.savedData = data
        external = nil
        diskMessage = nil
        // Later edits remain unsaved; only the source sent to disk becomes the baseline.
        document.markSaved(source: source)
        diskRevision += 1
    }

    func adoptLatest() async throws {
        guard !isSaving, !isLoading, !isClosed else { throw SaveError.busy }
        let revision = editRevision
        beginSaving()
        defer { finishSaving() }
        guard let content = try await io.read(fileURL), let source = content.source else { throw SaveError.unsupportedText }
        guard revision == editRevision, !document.editorViews.hasMarkedText, !isClosed else {
            throw SaveError.editedWhileReading
        }
        apply(data: content.data, source: source)
    }

    private func beginSaving() {
        isSaving = true
        generation += 1
        needsRead = needsRead || readTask != nil
    }

    private func finishSaving() {
        isSaving = false
        if needsRead { checkForExternalChanges() }
    }

    func checkForExternalChanges() {
        guard !isClosed else { return }
        needsRead = true
        guard readTask == nil, !isSaving else { return }
        readTask = Task { [weak self] in
            guard let self else { return }
            while needsRead, !isSaving, !isClosed, !Task.isCancelled {
                needsRead = false
                let generation = generation
                do {
                    let content = try await io.read(fileURL, comparedTo: savedData)
                    guard !Task.isCancelled, !isClosed, generation == self.generation else { continue }
                    if savedData == nil, let content {
                        savedData = content.data
                        if let source = content.source { document.replace(source: source) }
                        else { document.content = .binary }
                        diskMessage = nil
                    } else {
                        external = content
                        if content == nil { diskMessage = nil }
                    }
                } catch {
                    guard !Task.isCancelled, !isClosed, generation == self.generation else { continue }
                    external = nil
                    if savedData == nil { document.content = .error(error.localizedDescription) }
                    else { diskMessage = "ファイルを再読み込みできません：\(error.localizedDescription)" }
                }
                if isLoading {
                    isLoading = false
                    document.isFileOperationLocked = false
                }
                reconcileExternalContent()
            }
            readTask = nil
        }
    }

    private func reconcileExternalContent() {
        guard let external, !isSaving, !isClosed else { return }
        guard !document.hasUnsavedChanges else {
            diskMessage = "ファイルが外部で変更されています。編集内容は保持されています。本文で⌘Sを押すと「最新内容を採用」を選べます。"
            return
        }
        guard !document.editorViews.hasMarkedText else {
            diskMessage = "ファイルが外部で変更されています。入力確定後に再確認します。"
            return
        }
        guard let source = external.source else {
            diskMessage = "外部変更後のファイルをUTF-8として読み込めません。"
            return
        }
        apply(data: external.data, source: source)
    }

    func stop() {
        isClosed = true
        readTask?.cancel()
        external = nil
    }

    private func apply(data: Data, source: String) {
        savedData = data
        external = nil
        diskMessage = nil
        document.replace(source: source)
        diskRevision += 1
    }
}
