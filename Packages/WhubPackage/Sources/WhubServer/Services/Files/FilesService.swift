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
    private static let writeLock = NSLock()

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
        return try readText(fd: fd)
    }

    private func readText(fd: Int32) throws -> String {
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
        return try Self.decodeText(data)
    }

    private static func decodeText(_ data: Data) throws -> String {
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

    func writeText(path: String, expectedText: String, text: String) throws -> String {
        try Self.writeLock.withLock {
            let data = Data(text.utf8)
            _ = try Self.decodeText(data)
            _ = try Self.decodeText(Data(expectedText.utf8))
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                  !path.split(separator: "/").contains(".."),
                  let name = path.split(separator: "/", omittingEmptySubsequences: false).last,
                  !name.isEmpty, name != "." else { throw FilesError.invalidPath }
            let parent = String(path.dropLast(name.count))
            let directory = try openTarget(path: parent, directory: true)
            defer { close(directory) }
            let target = String(name)
            let original = openat(directory, target, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard original >= 0 else { throw FilesError.system(errno) }
            defer { close(original) }
            let current = try readText(fd: original)
            guard current.utf8.elementsEqual(expectedText.utf8) else { throw FilesError.conflict }
            var info = stat()
            guard fstat(original, &info) == 0 else { throw FilesError.system(errno) }
            let originalMetadata = try metadata(fd: original)
            let temporary = ".whub-save-" + UUID().uuidString
            let output = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard output >= 0 else { throw FilesError.writeFailed }
            defer {
                close(output)
                unlinkat(directory, temporary, 0)
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw FilesError.writeFailed }
                    offset += count
                }
            }
            // Preserve ownership and mode; refuse replacement if those cannot be retained.
            guard fchown(output, info.st_uid, info.st_gid) == 0,
                  fchmod(output, info.st_mode & 0o7777) == 0,
                  fsync(output) == 0 else { throw FilesError.writeFailed }
            var latest = stat()
            guard fstatat(directory, target, &latest, AT_SYMLINK_NOFOLLOW) == 0,
                  latest.st_dev == info.st_dev, latest.st_ino == info.st_ino,
                  latest.st_mode == info.st_mode, latest.st_uid == info.st_uid, latest.st_gid == info.st_gid,
                  lseek(original, 0, SEEK_SET) == 0 else { throw FilesError.conflict }
            guard try readText(fd: original).utf8.elementsEqual(expectedText.utf8) else { throw FilesError.conflict }
            guard try metadata(fd: original) == originalMetadata,
                  try metadata(fd: output) == originalMetadata else { throw FilesError.unsupportedMetadata }
            // shortcut: non-cooperating external writers can still race this final check and rename.
            guard renameat(directory, temporary, directory, target) == 0 else { throw FilesError.writeFailed }
            return text
        }
    }

    private func metadata(fd: Int32) throws -> [String: Data] {
        #if os(Linux)
        // Swift's Glibc module does not expose sys/xattr.h; use the libc functions directly.
        guard let listSymbol = dlsym(nil, "flistxattr"), let getSymbol = dlsym(nil, "fgetxattr") else {
            throw FilesError.unsupportedMetadata
        }
        let list = unsafeBitCast(listSymbol, to: (@convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int).self)
        let get = unsafeBitCast(getSymbol, to: (@convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutableRawPointer?, Int) -> Int).self)
        #else
        func list(_ fd: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
            flistxattr(fd, buffer, size, 0)
        }
        func get(_ fd: Int32, _ name: UnsafePointer<CChar>, _ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int {
            fgetxattr(fd, name, buffer, size, 0, 0)
        }
        #endif
        let size = list(fd, nil, 0)
        guard size >= 0, size <= Self.maxTextBytes else { throw FilesError.unsupportedMetadata }
        var names = [CChar](repeating: 0, count: size)
        guard list(fd, &names, size) == size else { throw FilesError.unsupportedMetadata }
        var result: [String: Data] = [:]
        for bytes in names.split(separator: 0) {
            guard let name = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                throw FilesError.unsupportedMetadata
            }
            let count = name.withCString { get(fd, $0, nil, 0) }
            guard count >= 0, count <= Self.maxTextBytes else { throw FilesError.unsupportedMetadata }
            var value = Data(count: count)
            let read = value.withUnsafeMutableBytes { buffer in
                name.withCString { get(fd, $0, buffer.baseAddress, buffer.count) }
            }
            guard read == count else { throw FilesError.unsupportedMetadata }
            result[name] = value
        }
        #if !os(Linux)
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // macOS reports ENOENT when this open file has no extended ACL.
            guard errno == ENOENT else { throw FilesError.unsupportedMetadata }
            return result
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { throw FilesError.unsupportedMetadata }
        defer { acl_free(text) }
        // Attribute names cannot contain NUL, so this key cannot collide with an actual attribute.
        result["\0acl"] = Data(String(cString: text).utf8)
        #endif
        return result
    }
}
