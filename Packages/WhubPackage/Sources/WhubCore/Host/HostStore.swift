import Foundation
import SwiftData

public enum HostStoreError: LocalizedError {
    case nameRequired
    case duplicateName(String)
    case localHostExists
    case invalidBasePath
    case hasProjects(String)

    public var errorDescription: String? {
        switch self {
        case .nameRequired:
            "Host name is required."
        case let .duplicateName(name):
            "A host named \(name) already exists."
        case .localHostExists:
            "A local host already exists."
        case .invalidBasePath:
            "Base path must be absolute."
        case let .hasProjects(name):
            "Host \(name) has projects."
        }
    }
}

@MainActor
public struct HostStore {
    static let connectionInvalidated = Notification.Name("WhubCore.HostConnectionInvalidated")
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func fetchHosts() throws -> [Host] {
        try context.fetch(FetchDescriptor(sortBy: [SortDescriptor(\Host.name)]))
    }

    @discardableResult
    public func addLocal(name: String, basePath: String) throws -> LocalHost {
        let name = try validate(name: name, basePath: basePath, allowLocal: true)
        guard try !fetchHosts().contains(where: { $0 is LocalHost }) else {
            throw HostStoreError.localHostExists
        }
        let host = LocalHost(name: name, basePath: basePath)
        context.insert(host)
        try context.save()
        return host
    }

    @discardableResult
    public func addRemote(
        name: String,
        basePath: String,
        hostname: String,
        user: String,
        port: Int = 22,
        identityFile: String
    ) throws -> RemoteHost {
        let name = try validate(name: name, basePath: basePath)
        try SSH.validate(hostname: hostname, user: user, port: port)
        let host = RemoteHost(
            name: name,
            basePath: basePath,
            hostname: hostname,
            user: user,
            port: port,
            identityFile: identityFile
        )
        context.insert(host)
        try context.save()
        return host
    }

    public func editLocal(_ host: LocalHost, name: String, basePath: String) throws {
        let name = try validate(name: name, basePath: basePath, excluding: host, allowLocal: true)
        host.name = name
        host.basePath = basePath
        try context.save()
    }

    public func editRemote(
        _ host: RemoteHost,
        name: String,
        basePath: String,
        hostname: String,
        user: String,
        port: Int,
        identityFile: String
    ) throws {
        let name = try validate(name: name, basePath: basePath, excluding: host)
        try SSH.validate(hostname: hostname, user: user, port: port)
        if host.hostname != hostname || host.user != user || host.port != port
            || host.identityFile != identityFile || host.basePath != basePath {
            NotificationCenter.default.post(name: Self.connectionInvalidated, object: host.persistentModelID)
        }
        host.name = name
        host.basePath = basePath
        host.hostname = hostname
        host.user = user
        host.port = port
        host.identityFile = identityFile
        try context.save()
    }

    @discardableResult
    private func validate(
        name rawName: String,
        basePath: String,
        excluding host: Host? = nil,
        allowLocal: Bool = false
    ) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostStoreError.nameRequired }
        guard (basePath as NSString).isAbsolutePath else { throw HostStoreError.invalidBasePath }
        guard (allowLocal || name != "local"), try !fetchHosts().contains(where: {
            $0.name == name && $0.persistentModelID != host?.persistentModelID
        }) else {
            throw HostStoreError.duplicateName(name)
        }
        return name
    }

    public func delete(_ host: Host) throws {
        let projects = try context.fetch(FetchDescriptor<Project>())
        guard !projects.contains(where: { $0.host.persistentModelID == host.persistentModelID }) else {
            throw HostStoreError.hasProjects(host.name)
        }
        NotificationCenter.default.post(name: Self.connectionInvalidated, object: host.persistentModelID)
        context.delete(host)
        try context.save()
    }
}
