import Combine
import Foundation

@MainActor
final class CodexCommandsStore: ObservableObject {
    let request: (String, [String: Any], String) async throws -> [String: Any]
    var generationID = UUID()
    @Published private(set) var skills: [CodexSkill] = []
    @Published private(set) var skillError: String?
    @Published private(set) var isLoadingSkills = false
    private var skillsRequestID = UUID()
    private var skillsDirectory = ""
    @Published private(set) var recentThreads: [CodexRecentThread] = []
    @Published private(set) var isLoadingThreads = false
    @Published private(set) var threadListError: String?
    @Published private(set) var nextThreadCursor: String?

    @Published var models: [CodexModel] = []
    @Published var isLoadingModels = false
    @Published var modelError: String?
    @Published var configuredModel: String?
    @Published var configuredEffort: String?
    @Published private(set) var isLoadingStatus = false

    init(request: @escaping (String, [String: Any], String) async throws -> [String: Any]) {
        self.request = request
    }

    func invalidate() {
        generationID = UUID()
        isLoadingThreads = false
        isLoadingSkills = false
        isLoadingModels = false
        isLoadingStatus = false
        modelError = nil
        configuredModel = nil
        configuredEffort = nil
    }

    func loadRecentThreads(directory: String, more: Bool = false) async {
        guard !isLoadingThreads, !more || nextThreadCursor != nil else { return }
        let generation = generationID
        isLoadingThreads = true
        threadListError = nil
        defer { if generation == generationID { isLoadingThreads = false } }
        do {
            var params: [String: Any] = ["limit": 20, "sortKey": "updated_at", "sortDirection": "desc",
                                        "sourceKinds": ["cli", "appServer", "vscode"], "archived": false]
            if more { params["cursor"] = nextThreadCursor }
            let result = try await request("thread/list", params, directory)
            guard generation == generationID else { return }
            guard let data = result["data"] as? [[String: Any]] else {
                throw CodexError(message: "会話一覧を読み込めませんでした。")
            }
            let threads = try data.map(CodexRecentThread.init)
            var seen = Set(more ? recentThreads.map(\.id) : [])
            let additions = threads.filter { seen.insert($0.id).inserted }
            recentThreads = (more ? recentThreads : []) + additions
            nextThreadCursor = result["nextCursor"] as? String
        } catch {
            if generation == generationID { threadListError = error.localizedDescription }
        }
    }

    @discardableResult
    func loadSkills(directory: String, forceReload: Bool = false) async -> CodexCommandOutput {
        let cwd = directory
        let requestID = UUID()
        skillsRequestID = requestID
        guard !cwd.isEmpty else { return .missingDirectory }
        let generation = generationID
        isLoadingSkills = true
        if skillsDirectory != cwd { skills = [] }
        skillError = nil
        defer { if generation == generationID && skillsRequestID == requestID { isLoadingSkills = false } }
        do {
            let result = try await request("skills/list", ["cwds": [cwd], "forceReload": forceReload], cwd)
            guard generation == generationID && skillsRequestID == requestID else { return .directoryChanged }
            let entries = result["data"] as? [[String: Any]] ?? []
            skills = entries.flatMap { $0["skills"] as? [[String: Any]] ?? [] }.compactMap {
                guard $0["enabled"] as? Bool != false,
                      let name = $0["name"] as? String, let path = $0["path"] as? String else { return nil }
                return CodexSkill(name: name, description: $0["description"] as? String ?? "", path: path)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            skillsDirectory = cwd
            let errors = entries.flatMap { $0["errors"] as? [[String: Any]] ?? [] }
            if !errors.isEmpty { skillError = CodexJSON.pretty(errors) }
            return .json(result)
        } catch {
            if generation == generationID && skillsRequestID == requestID { skillError = error.localizedDescription }
            return .text(error.localizedDescription)
        }
    }

    func runCommand(_ command: CodexCommand, session: CodexStore) async {
        let generation = generationID
        let output: CodexCommandOutput
        switch command {
        case .model:
            await loadModels(directory: session.directory)
            return
        case .resume:
            await loadRecentThreads(directory: session.directory)
            return
        case .new:
            session.reset()
            return
        case .stop:
            let wasBusy = session.isBusy
            await session.interrupt()
            if !wasBusy { output = .noRunningTask }
            else if session.isStopping { output = .stopRequested }
            else if let error = session.errorMessage { output = .text(error) }
            else { output = .stopped }
        case .skills:
            output = await loadSkills(directory: session.directory, forceReload: true)
        case .status:
            guard !isLoadingStatus else { return }
            isLoadingStatus = true
            output = .status(await loadStatus(session: session))
            if generation == generationID { isLoadingStatus = false }
        }
        guard generation == generationID else { return }
        session.appendCommandOutput(command, output)
    }

}
