import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct FilesWriter: Sendable {
    let files: FilesService
    private static let writeLock = NSLock()

    func writeText(path: String, expectedText: String, text: String) throws -> String {
        try Self.writeLock.withLock {
            let data = Data(text.utf8)
            _ = try FilesReader.decodeText(data)
            _ = try FilesReader.decodeText(Data(expectedText.utf8))
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                  !path.split(separator: "/").contains(".."),
                  let name = path.split(separator: "/", omittingEmptySubsequences: false).last,
                  !name.isEmpty, name != "." else { throw FilesError.invalidPath }
            let parent = String(path.dropLast(name.count))
            let directory = try files.openTarget(path: parent, directory: true)
            defer { close(directory) }
            let target = String(name)
            let original = openat(directory, target, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard original >= 0 else { throw FilesError.system(errno) }
            defer { close(original) }
            let current = try FilesReader(files: files).readText(fd: original)
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
            guard try FilesReader(files: files).readText(fd: original).utf8.elementsEqual(expectedText.utf8) else { throw FilesError.conflict }
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
        guard size >= 0, size <= FilesReader.maxTextBytes else { throw FilesError.unsupportedMetadata }
        var names = [CChar](repeating: 0, count: size)
        guard list(fd, &names, size) == size else { throw FilesError.unsupportedMetadata }
        var result: [String: Data] = [:]
        for bytes in names.split(separator: 0) {
            guard let name = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                throw FilesError.unsupportedMetadata
            }
            let count = name.withCString { get(fd, $0, nil, 0) }
            guard count >= 0, count <= FilesReader.maxTextBytes else { throw FilesError.unsupportedMetadata }
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
