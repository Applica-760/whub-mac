import Foundation
import SwiftData

public enum HostStoreError: LocalizedError {
    case nameRequired
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .nameRequired:
            "Host name is required."
        case let .duplicateName(name):
            "A host named \(name) already exists."
        }
    }
}

@MainActor
public struct HostStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func fetchHosts() throws -> [Host] {
        try context.fetch(FetchDescriptor(sortBy: [SortDescriptor(\Host.name)]))
    }

    @discardableResult
    public func add(
        name: String,
        hostname: String,
        user: String,
        port: Int = 22,
        identityFile: String,
        mountRoot: String
    ) throws -> Host {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostStoreError.nameRequired }
        guard try !fetchHosts().contains(where: { $0.name == name }) else {
            throw HostStoreError.duplicateName(name)
        }

        let host = Host(
            name: name,
            hostname: hostname,
            user: user,
            port: port,
            identityFile: identityFile,
            mountRoot: mountRoot
        )
        context.insert(host)
        try context.save()
        return host
    }
}
