import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct FilesService: Sendable {
    struct Entry: Sendable {
        let name: String
        let kind: String
    }

    let root: String
    private static let maxTextBytes = 1_048_576

    init(root: String) throws {
        guard root.hasPrefix("/"), !root.contains("\0"),
              !root.split(separator: "/").contains("..") else {
            throw FilesError.invalidPath
        }
        self.root = root
        let fd = try openTarget(path: "", directory: true)
        close(fd)
    }

    private func openTarget(path: String, directory: Bool) throws -> Int32 {
        guard !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else {
            throw FilesError.invalidPath
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FilesError.system(errno) }
        do {
            let parts = (root + "/" + path).split(separator: "/").filter { $0 != "." }
            for (index, part) in parts.enumerated() {
                let name = String(part)
                var flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                if directory || index < parts.count - 1 { flags |= O_DIRECTORY }
                let child = openat(fd, name, flags)
                guard child >= 0 else {
                    let number = errno
                    var info = stat()
                    // O_DIRECTORY can report ENOTDIR for a symlink, on both platforms.
                    if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                       info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                        throw FilesError.symlinkForbidden
                    }
                    throw FilesError.system(number)
                }
                close(fd)
                fd = child
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    func list(path: String, onEntry: (Entry) throws -> Void) throws {
        let fd = try openTarget(path: path, directory: true)
        guard let directory = fdopendir(fd) else {
            let number = errno
            close(fd)
            throw FilesError.system(number)
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let child = readdir(directory) else {
                if errno != 0 { throw FilesError.system(errno) }
                break
            }
            let name = withUnsafePointer(to: &child.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: child.pointee.d_name)) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw FilesError.invalidPath }
            if [".", "..", ".git", ".DS_Store"].contains(name) { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw FilesError.system(errno)
            }
            let kind: String
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFLNK): kind = "symlink"
            case mode_t(S_IFDIR): kind = "directory"
            case mode_t(S_IFREG): kind = "file"
            default: kind = "other"
            }
            try onEntry(Entry(name: name, kind: kind))
        }
    }

    func readText(path: String) throws -> String {
        let fd = try openTarget(path: path, directory: false)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw FilesError.system(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw FilesError.notRegularFile
        }
        guard info.st_size <= Self.maxTextBytes else { throw FilesError.textTooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= Self.maxTextBytes {
            let count = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, min($0.count, Self.maxTextBytes + 1 - data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FilesError.system(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
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
