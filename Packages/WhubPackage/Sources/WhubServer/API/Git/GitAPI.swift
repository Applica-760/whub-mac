import Foundation
import Hummingbird

struct GitAPI: Sendable {
    private static let maxResponseBytes = 8 * 1_048_576

    private let service = GitService()
    #if os(Linux)
    let watches: LinuxGitWatchStore

    init(watches: LinuxGitWatchStore = LinuxGitWatchStore()) {
        self.watches = watches
    }
    #endif

    func startWatch(query: String?) async -> Response {
        #if os(Linux)
        do {
            let (root, _) = try Self.parameters(from: query, requiresPath: false)
            return try Self.response(await watches.start(root: root))
        } catch { return GitAPIError.response(for: error) }
        #else
        return Response(status: .notImplemented)
        #endif
    }

    func waitWatch(id: String, query: String?) async throws -> Response {
        #if os(Linux)
        do {
            guard let id = UUID(uuidString: id), let query, query.hasPrefix("after="),
                  let revision = UInt64(query.dropFirst(6)) else { throw FilesAPIError.invalidRequest }
            if let revision = try await watches.wait(id: id, after: revision) {
                return try Self.response(["revision": revision])
            }
            return Response(status: .noContent, headers: [.cacheControl: "no-store"])
        } catch is CancellationError { throw CancellationError() }
        catch { return GitAPIError.response(for: error) }
        #else
        return Response(status: .notImplemented)
        #endif
    }

    func stopWatch(id: String) async -> Response {
        #if os(Linux)
        do {
            guard let id = UUID(uuidString: id) else { throw FilesAPIError.invalidRequest }
            try await watches.stop(id: id)
            return Response(status: .noContent, headers: [.cacheControl: "no-store"])
        } catch { return GitAPIError.response(for: error) }
        #else
        return Response(status: .notImplemented)
        #endif
    }

    func changes(query: String?) async -> Response {
        do {
            let (root, _) = try Self.parameters(from: query, requiresPath: false)
            return try Self.response(await service.changes(root: root))
        } catch { return GitAPIError.response(for: error) }
    }

    func diff(query: String?) async -> Response {
        do {
            let (root, path) = try Self.parameters(from: query, requiresPath: true)
            return try Self.response(await service.diff(root: root, path: path))
        } catch { return GitAPIError.response(for: error) }
    }

    private static func parameters(from query: String?, requiresPath: Bool) throws -> (String, String) {
        guard let query, !query.isEmpty else { throw FilesAPIError.invalidPath }
        var values: [String: String] = [:]
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let name = pair[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = pair[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  ["root", "path"].contains(name), values[name] == nil else { throw FilesAPIError.invalidPath }
            values[name] = value
        }
        guard let root = values["root"], root.hasPrefix("/"), !root.contains("\0"),
              !root.split(separator: "/").contains("..") else { throw FilesAPIError.invalidPath }
        let path = values["path"] ?? ""
        guard (!requiresPath && path.isEmpty) || (requiresPath && !path.isEmpty && !path.hasPrefix("/") &&
              !path.contains("\0") && !path.split(separator: "/").contains("..") &&
              path.split(separator: "/").contains(where: { $0 != "." })) else { throw FilesAPIError.invalidPath }
        return (root, path)
    }

    private static func response<T: Encodable>(_ value: T) throws -> Response {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maxResponseBytes else { throw FilesAPIError.listingTooLarge }
        return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                        body: .init(byteBuffer: .init(bytes: data)))
    }

}
