import Foundation
import Hummingbird

struct FilesAPI: Sendable {
    let service: FilesService
    private static let maxResponseBytes = 8 * 1_048_576

    func list(query: String?) async -> Response {
        do {
            let path = try Self.path(from: query)
            // Directory I/O must not block the HTTP event loop.
            let data = try await Task.detached {
                var data = Data("[".utf8)
                let encoder = JSONEncoder()
                try service.list(path: path) { entry in
                    let encoded = try encoder.encode(["name": entry.name, "kind": entry.kind])
                    let separatorBytes = data.count == 1 ? 0 : 1
                    guard data.count + separatorBytes + encoded.count + 1 <= Self.maxResponseBytes else {
                        throw FilesAPIError.listingTooLarge
                    }
                    if separatorBytes != 0 { data.append(0x2C) }
                    data.append(encoded)
                }
                data.append(0x5D)
                return data
            }.value
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: .init(bytes: data)))
        } catch let error as FilesAPIError {
            return error.response
        } catch let error as FilesError {
            return FilesAPIError(error).response
        } catch {
            return FilesAPIError.readFailed.response
        }
    }

    func readText(query: String?) async -> Response {
        do {
            let path = try Self.path(from: query)
            guard !path.isEmpty else { throw FilesAPIError.invalidPath }
            let text = try await Task.detached { try service.readText(path: path) }.value
            let data = try JSONEncoder().encode(["text": text])
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: .init(bytes: data)))
        } catch let error as FilesAPIError {
            return error.response
        } catch let error as FilesError {
            return FilesAPIError(error).response
        } catch {
            return FilesAPIError.readFailed.response
        }
    }

    private static func path(from query: String?) throws -> String {
        guard let query, !query.isEmpty else { return "" }
        let fields = query.split(separator: "&", omittingEmptySubsequences: false)
        guard fields.count == 1 else { throw FilesAPIError.invalidPath }
        let pair = fields[0].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        func decode(_ value: Substring) throws -> String {
            guard let decoded = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                throw FilesAPIError.invalidPath
            }
            return decoded
        }
        guard try decode(pair[0]) == "path" else { throw FilesAPIError.invalidPath }
        return try pair.count == 2 ? decode(pair[1]) : ""
    }

}
