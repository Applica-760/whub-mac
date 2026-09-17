import Foundation
import Observation
import SwiftData
import WhubCore

@MainActor
@Observable
final class ProjectCreationController {
    enum ResourceType: String, CaseIterable, Identifiable {
        case local = "Local"
        case remote = "Remote"

        var id: Self { self }
    }

    var name = ""
    var workspacePath = ""
    var resourceType = ResourceType.local
    var localPath = ""
    var hostID: PersistentIdentifier?
    var remotePath = ""
    var gitURL = ""
    var statusEnabled = true
    var errorMessage = ""
    var showsError = false

    func canAdd(hosts: [WhubCore.Host]) -> Bool {
        guard hasText(name), hasText(workspacePath) else { return false }

        switch resourceType {
        case .local:
            return hasText(localPath)
        case .remote:
            return selectedHost(in: hosts) != nil && hasText(remotePath)
        }
    }

    @discardableResult
    func add(context: ModelContext, hosts: [WhubCore.Host]) -> Bool {
        let resource: Resource

        switch resourceType {
        case .local:
            resource = LocalResource(
                workspacePath: workspacePath,
                localPath: localPath,
                gitURL: optionalValue(gitURL),
                statusEnabled: statusEnabled
            )
        case .remote:
            guard let host = selectedHost(in: hosts) else { return false }
            resource = RemoteResource(
                workspacePath: workspacePath,
                remotePath: remotePath,
                host: host,
                gitURL: optionalValue(gitURL),
                statusEnabled: statusEnabled
            )
        }

        do {
            try ProjectStore(context: context).add(name: name, resource: resource)
            return true
        } catch {
            errorMessage = error.localizedDescription
            showsError = true
            return false
        }
    }

    private func selectedHost(in hosts: [WhubCore.Host]) -> WhubCore.Host? {
        hosts.first { $0.persistentModelID == hostID }
    }

    private func optionalValue(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
