import Foundation
import Hummingbird

struct FilesAPI: Sendable {
    private static let maxResponseBytes = 8 * 1_048_576

    enum Operation: Sendable { case createFile, createDirectory, rename, trash }

    func operate(_ request: Request, operation: Operation) async -> Response {
        do {
            let (root, path) = try Self.parameters(from: request.uri.query)
            let action: FilesService.Operation
            switch operation {
            case .createFile: action = .createFile
            case .createDirectory: action = .createDirectory
            case .trash: action = .trash
            case .rename:
                guard request.headers[.contentType]?.split(separator: ";").first?.lowercased() == "application/json" else {
                    throw FilesAPIError.invalidRequest
                }
                struct Body: Decodable { let name: String }
                do {
                    let body = try await request.body.collect(upTo: 4096)
                    action = .rename(try JSONDecoder().decode(Body.self, from: Data(body.readableBytesView)).name)
                } catch { throw FilesAPIError.invalidRequest }
            }
            try await Task.detached {
                try FilesService(root: root).perform(action, path: path)
            }.value
            return Response(status: .noContent)
        } catch let error as FilesAPIError {
            return error.response
        } catch let error as FilesError {
            return FilesAPIError(error).response
        } catch {
            return FilesAPIError.operationFailed.response
        }
    }

    func list(query: String?) async -> Response {
        do {
            let (root, path) = try Self.parameters(from: query)
            // Directory I/O must not block the HTTP event loop.
            let data = try await Task.detached {
                let service = try FilesService(root: root)
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
            let (root, path) = try Self.parameters(from: query)
            guard !path.isEmpty else { throw FilesAPIError.invalidPath }
            let text = try await Task.detached {
                try FilesService(root: root).readText(path: path)
            }.value
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

    func writeText(_ request: Request) async -> Response {
        do {
            let (root, path) = try Self.parameters(from: request.uri.query)
            guard !path.isEmpty else { throw FilesAPIError.invalidPath }
            guard request.headers[.contentType]?.split(separator: ";").first?.lowercased() == "application/json" else {
                throw FilesAPIError.invalidRequest
            }
            struct Body: Decodable, Sendable { let expectedText: String; let text: String }
            let body: Body
            do {
                // Two 1 MiB strings, allowing JSON's six-byte escaping of each input byte.
                let buffer = try await request.body.collect(upTo: 12 * 1_048_576 + 1024)
                body = try JSONDecoder().decode(Body.self, from: Data(buffer.readableBytesView))
            } catch { throw FilesAPIError.invalidRequest }
            let text = try await Task.detached {
                try FilesService(root: root).writeText(path: path, expectedText: body.expectedText, text: body.text)
            }.value
            let data = try JSONEncoder().encode(["text": text])
            return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                            body: .init(byteBuffer: .init(bytes: data)))
        } catch let error as FilesAPIError {
            return error.response
        } catch let error as FilesError {
            return FilesAPIError(error).response
        } catch {
            return FilesAPIError.writeFailed.response
        }
    }

    private static func parameters(from query: String?) throws -> (root: String, path: String) {
        guard let query, !query.isEmpty else { throw FilesAPIError.invalidPath }
        var values: [String: String] = [:]
        func decode(_ value: Substring) throws -> String {
            guard let decoded = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                throw FilesAPIError.invalidPath
            }
            return decoded
        }
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw FilesAPIError.invalidPath }
            let name = try decode(pair[0])
            guard ["root", "path"].contains(name), values[name] == nil else {
                throw FilesAPIError.invalidPath
            }
            values[name] = try decode(pair[1])
        }
        guard let root = values["root"] else { throw FilesAPIError.invalidPath }
        return (root, values["path"] ?? "")
    }
}
