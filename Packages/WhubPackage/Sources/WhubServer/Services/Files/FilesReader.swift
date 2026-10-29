import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct FilesReader: Sendable {
    let files: FilesService
    static let maxTextBytes = 1_048_576
    static let maxImageBytes = 8 * 1_048_576

    func readImage(path: String) throws -> Data {
        let fd = try files.openTarget(path: path, directory: false)
        defer { close(fd) }
        return try readData(fd: fd, limit: Self.maxImageBytes, tooLarge: .imageTooLarge)
    }

    func readText(path: String) throws -> String {
        let fd = try files.openTarget(path: path, directory: false)
        defer { close(fd) }
        return try readText(fd: fd)
    }

    func readText(fd: Int32) throws -> String {
        try Self.decodeText(readData(fd: fd, limit: Self.maxTextBytes, tooLarge: .textTooLarge))
    }

    private func readData(fd: Int32, limit: Int, tooLarge: FilesError) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw FilesError.system(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw FilesError.notRegularFile
        }
        guard info.st_size <= limit else { throw tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, min($0.count, limit + 1 - data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FilesError.system(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limit else { throw tooLarge }
        return data
    }

    static func decodeText(_ data: Data) throws -> String {
        guard data.count <= Self.maxTextBytes else { throw FilesError.textTooLarge }
        // Match the existing Python control-byte heuristic for binary detection.
        guard !data.contains(where: { $0 <= 8 || $0 == 11 || (14...31).contains($0) || $0 == 127 }) else {
            throw FilesError.binaryFile
        }
        let text = String(decoding: data, as: UTF8.self)
        // Reject repaired UTF-8 while preserving a leading BOM on macOS 14 as well.
        guard text.utf8.elementsEqual(data) else { throw FilesError.invalidUTF8 }
        return text
    }

}
