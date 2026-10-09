import Combine
import Foundation
import WhubCore

@MainActor
final class GitStore: ObservableObject {
    @Published private(set) var changes: [URL: GitChange] = [:]
    @Published private(set) var rootURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var diffChanges: [URL: GitChange] = [:]
    @Published private(set) var diffError: String?
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var isRepository = false
    private var diffEnabled = false
    private(set) var managementDirectories: Set<URL> = []
    var onManagementDirectoriesChange: (() -> Void)?
    private var requestID = 0
    private var refreshTask: Task<Void, Never>?

    func setRoot(_ url: URL?) {
        if rootURL != url {
            reset()
            rootURL = url
        }
        errorMessage = nil
    }

    func reset() {
        requestID += 1
        rootURL = nil
        managementDirectories = []
        changes = [:]
        errorMessage = nil
        diffChanges = [:]
        diffError = nil
        isLoadingDiff = false
        isRepository = false
    }

    func stop() {
        requestID += 1
        rootURL = nil
        onManagementDirectoriesChange = nil
        isLoadingDiff = false
    }

    func setDiffEnabled(_ enabled: Bool) {
        guard diffEnabled != enabled else { return }
        diffEnabled = enabled
        if !enabled { diffChanges = [:]; diffError = nil; isLoadingDiff = false }
        refresh()
    }

    func managesStatus(for fileURL: URL) -> Bool {
        guard let rootURL else { return false }
        let roots = [rootURL.standardizedFileURL.path, rootURL.resolvingSymlinksInPath().path]
        let paths = [fileURL.standardizedFileURL.path, fileURL.resolvingSymlinksInPath().path]
        return paths.contains { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } }
    }

    func refresh() {
        guard rootURL != nil else { return }
        if diffEnabled { isLoadingDiff = true }
        requestID += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in await self?.load() }
    }

    private func load() async {
        defer { refreshTask = nil }
        while let url = rootURL {
            let requestID = requestID
            func isCurrent() -> Bool { rootURL == url && self.requestID == requestID }
            do {
                let directories = try await Git.managementDirectories(at: url)
                guard isCurrent() else { continue }
                managementDirectories = directories
                onManagementDirectoriesChange?()
                let loaded = try await Git.changes(at: url)
                guard isCurrent() else { continue }
                changes = loaded
                errorMessage = nil
                isRepository = true
                if diffEnabled {
                    do {
                        let diffs = try await Git.fileChanges(at: url)
                        guard isCurrent() else { continue }
                        diffChanges = diffs
                        diffError = nil
                    } catch {
                        guard isCurrent() else { continue }
                        diffChanges = [:]
                        diffError = error.localizedDescription
                    }
                }
            } catch GitError.notRepository {
                guard isCurrent() else { continue }
                managementDirectories = []
                onManagementDirectoriesChange?()
                changes = [:]
                errorMessage = nil
                diffChanges = [:]
                diffError = nil
                isRepository = false
            } catch {
                guard isCurrent() else { continue }
                changes = [:]
                errorMessage = error.localizedDescription
                diffChanges = [:]
                diffError = error.localizedDescription
            }
            isLoadingDiff = false
            break
        }
    }

    func refreshStatus(for fileURL: URL) async throws {
        guard !managesStatus(for: fileURL) else { return }
        do {
            let loaded = try await Git.changes(at: fileURL.deletingLastPathComponent())
            guard !Task.isCancelled else { return }
            if !managesStatus(for: fileURL) {
                changes[fileURL.standardizedFileURL] = loaded[fileURL.standardizedFileURL]
            }
        } catch GitError.notRepository {
            clearStatus(for: fileURL)
            throw GitError.notRepository
        }
    }

    func clearStatus(for fileURL: URL) {
        guard !Task.isCancelled, !managesStatus(for: fileURL) else { return }
        changes.removeValue(forKey: fileURL.standardizedFileURL)
    }
}

@MainActor
final class GitLineStore: ObservableObject {
    struct Baseline: Equatable {
        let fileURL: URL
        let source: String
    }

    @Published private(set) var baseline: Baseline?
    @Published private(set) var errorMessage: String?
    @Published private var hunks: [LineDiffHunk] = []
    private var diffSource: String?

    func hunks(for fileURL: URL, source: String) -> [LineDiffHunk] {
        baseline?.fileURL == fileURL && diffSource == source ? hunks : []
    }

    func load(fileURL: URL, gitStore: GitStore) async {
        baseline = nil
        diffSource = nil
        hunks = []
        errorMessage = nil
        do {
            let loaded = try await Git.baselineText(at: fileURL)
            guard !Task.isCancelled else { return }
            if let loaded { baseline = Baseline(fileURL: fileURL, source: loaded) }
            try await gitStore.refreshStatus(for: fileURL)
        } catch GitError.notRepository {
            gitStore.clearStatus(for: fileURL)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func update(source: String) async {
        guard let baseline else { return }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        let calculation = Task.detached(priority: .utility) {
            Git.diff(from: baseline.source, to: source)
        }
        let loaded = await calculation.value
        guard !Task.isCancelled, self.baseline == baseline else { return }
        diffSource = source
        hunks = loaded
    }
}
