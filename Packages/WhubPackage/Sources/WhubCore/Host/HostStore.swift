import Foundation
import SwiftData

public enum HostStoreError: LocalizedError {
    case nameRequired
    case duplicateName(String)
    case localHostExists
    case invalidBasePath
    case invalidServerURL
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
        case .invalidServerURL:
            "Server URL must use HTTP or HTTPS with a host, without credentials, a query or a fragment."
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
        identityFile: String,
        devServerURL: String? = nil,
        prodServerURL: String? = nil
    ) throws -> RemoteHost {
        let name = try validate(name: name, basePath: basePath)
        try SSH.validate(hostname: hostname, user: user, port: port)
        let devServerURL = try validateServerURL(devServerURL)
        let prodServerURL = try validateServerURL(prodServerURL)
        let host = RemoteHost(
            name: name,
            basePath: basePath,
            hostname: hostname,
            user: user,
            port: port,
            identityFile: identityFile,
            devServerURL: devServerURL,
            prodServerURL: prodServerURL
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
        identityFile: String,
        devServerURL: String? = nil,
        prodServerURL: String? = nil
    ) throws {
        let name = try validate(name: name, basePath: basePath, excluding: host)
        try SSH.validate(hostname: hostname, user: user, port: port)
        // Omitted values preserve URLs for callers that only edit SSH settings; an empty string clears them.
        let devServerURL = try validateServerURL(devServerURL ?? host.devServerURL)
        let prodServerURL = try validateServerURL(prodServerURL ?? host.prodServerURL)
        if host.hostname != hostname || host.user != user || host.port != port
            || host.identityFile != identityFile || host.basePath != basePath
            || host.devServerURL != devServerURL || host.prodServerURL != prodServerURL {
            NotificationCenter.default.post(name: Self.connectionInvalidated, object: host.persistentModelID)
        }
        host.name = name
        host.basePath = basePath
        host.hostname = hostname
        host.user = user
        host.port = port
        host.identityFile = identityFile
        host.devServerURL = devServerURL
        host.prodServerURL = prodServerURL
        try context.save()
    }

    private func validateServerURL(_ rawValue: String?) throws -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        guard let url = URL(string: value, encodingInvalidCharacters: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, ["http", "https"].contains(scheme.lowercased()),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw HostStoreError.invalidServerURL
        }
        return value
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
