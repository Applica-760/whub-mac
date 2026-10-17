import Combine
import Foundation
import WhubClient

@MainActor
final class RemoteFileStore: ObservableObject {
    enum State {
        case loading
        case loaded(FileStore)
        case failed(String)
        case disconnected
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?
    private(set) var document: FileStore?
    private let name: String
    private struct Request {
        let connection: (() -> ObjectIdentifier?)?
        let read: () async throws -> String
        let write: (String, String) async throws -> String
    }
    private var request: Request?
    private var sessionID: ObjectIdentifier?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var documentChanges: AnyCancellable?
    private var savedText: String?
    private var pendingSave: (source: String, text: String)?

    init(location: FileLocation, root: FileLocation?,
         connection: (() -> ObjectIdentifier?)?,
         write: @escaping @MainActor (String, String, String, String) async throws -> String,
         read: @escaping @MainActor (FileLocation, String, String) async throws -> String) {
        name = location.name
        guard case let .remote(hostID, path) = location,
              let root, case let .remote(rootHostID, rootPath) = root, rootHostID == hostID else {
            state = .failed("閲覧ルートが不正です。")
            return
        }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else {
            state = .failed("閲覧ルートの外にあるファイルは取得できません。")
            return
        }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(".."),
              !path.contains("\0"), !rootPath.split(separator: "/").contains(".."), rootPath.hasPrefix("/") else {
            state = .failed("閲覧ルートと相対パスが不正です。")
            return
        }
        request = Request(connection: connection, read: { try await read(location, rootPath, relative) },
                          write: { expected, text in try await write(rootPath, relative, expected, text) })
        refresh()
    }

    var hasUnsavedChanges: Bool {
        guard let document, let savedSource = document.savedSource,
              case let .text(source) = document.content else { return false }
        return !source.utf8.elementsEqual(savedSource.utf8)
    }

    var needsCloseConfirmation: Bool {
        isSaving || pendingSave != nil || hasUnsavedChanges
            || document?.editorViews.hasMarkedText == true
    }

    var canSave: Bool {
        guard let request, document != nil,
              !isSaving, job == nil, pendingSave == nil else { return false }
        return request.connection == nil || request.connection?() != nil
    }

    func synchronizeConnection() {
        guard let connection = request?.connection else { return }
        if connection() != sessionID { refresh() }
    }

    func refresh() {
        guard let request, !isSaving else { return }
        job?.cancel()
        job = nil
        let generation = UUID()
        self.generation = generation
        let sessionID = request.connection?()
        self.sessionID = sessionID
        if request.connection != nil && sessionID == nil {
            state = .disconnected
            return
        }
        state = .loading
        job = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await request.read()) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            guard request.connection?() == sessionID else {
                self.refresh()
                return
            }
            switch result {
            case let .success(text):
                if let document = self.document {
                    if let pending = pendingSave, text.utf8.elementsEqual(pending.text.utf8) {
                        savedText = text
                        document.markSaved(source: pending.source)
                        message = nil
                        pendingSave = nil
                    } else if hasUnsavedChanges || document.editorViews.hasMarkedText || pendingSave != nil {
                        if savedText?.utf8.elementsEqual(text.utf8) == true {
                            pendingSave = nil
                            message = nil
                        } else {
                            message = "ファイルが外部で変更されています。編集内容は保持されています。"
                        }
                    } else {
                        if savedText?.utf8.elementsEqual(text.utf8) != true { document.replace(source: text) }
                        savedText = text
                        message = nil
                    }
                } else {
                    let document = FileStore(content: .text(text), isEditable: true)
                    self.document = document
                    savedText = text
                    documentChanges = document.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                    document.saveAction = { [weak self] in Task { await self?.save() } }
                    document.canSave = { [weak self] in self?.canSave == true }
                }
                state = .loaded(self.document!)
            case let .failure(error):
                state = .failed(error.localizedDescription)
            }
            job = nil
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard canSave, let request, let document,
              let savedText, case let .text(source) = document.content else { return false }
        guard !document.editorViews.hasMarkedText else { EditorDialogs.beep(); return false }
        guard hasUnsavedChanges else { return true }
        isSaving = true
        defer {
            isSaving = false
            if request.connection?() != sessionID { refresh() }
        }
        let session = request.connection?()
        let output = Self.output(source: source, original: savedText)
        pendingSave = (source, output)
        message = nil
        do {
            let text = try await request.write(savedText, output)
            guard request.connection?() == session else { throw SaveError.unconfirmed }
            guard text.utf8.elementsEqual(output.utf8) else { throw SaveError.unconfirmed }
            self.savedText = text
            pendingSave = nil
            document.markSaved(source: source)
            state = .loaded(document)
            return true
        } catch {
            // A transport failure may arrive after the server committed; reconcile on the next read.
            if let error = error as? WhubClientError, case .api = error { pendingSave = nil }
            message = error.localizedDescription + (pendingSave == nil
                ? " 編集内容は保持されています。" : " 保存結果が不明です。リロードで確認してください。編集内容は保持されています。")
            return false
        }
    }

    func confirmClose(choice: EditorDialogs.CloseChoice? = nil) async -> Bool {
        guard !isSaving else { return false }
        guard let document else { return true }
        guard !document.editorViews.hasMarkedText else { EditorDialogs.beep(); return false }
        guard hasUnsavedChanges || pendingSave != nil else { return true }
        switch choice ?? EditorDialogs.confirmClose(fileName: name) {
        case .save: return await save() && !hasUnsavedChanges
        case .discard: return true
        case .cancel: return false
        }
    }

    private enum SaveError: LocalizedError {
        case unconfirmed
        var errorDescription: String? { "保存結果を確認できません。" }
    }

    private static func output(source: String, original: String) -> String {
        var output = source
        let withoutCRLF = original.replacingOccurrences(of: "\r\n", with: "")
        let lineEnding: String? = if original.contains("\r\n") && !withoutCRLF.contains("\r") && !withoutCRLF.contains("\n") {
            "\r\n"
        } else if !original.contains("\n") && original.contains("\r") {
            "\r"
        } else if !original.contains("\r") {
            "\n"
        } else { nil }
        if let lineEnding {
            output = output.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: lineEnding)
        }
        if original.hasPrefix("\u{FEFF}"), !output.hasPrefix("\u{FEFF}") { output = "\u{FEFF}" + output }
        return output
    }

    func close() {
        job?.cancel()
        job = nil
        generation = UUID()
        request = nil
        sessionID = nil
    }
}
