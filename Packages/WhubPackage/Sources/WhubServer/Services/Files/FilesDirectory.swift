import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct FilesDirectory: Sendable {
    struct Entry: Sendable {
        let name: String
        let kind: String
    }

    let files: FilesService

    func list(path: String, onEntry: (Entry) throws -> Void) throws {
        let fd = try files.openTarget(path: path, directory: true)
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

    private func parentAndName(path: String) throws -> (Int32, String) {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(".."),
              let name = path.split(separator: "/", omittingEmptySubsequences: false).last,
              !name.isEmpty, name != "." else { throw FilesError.invalidPath }
        let directory = try files.openTarget(path: String(path.dropLast(name.count)), directory: true)
        return (directory, String(name))
    }

    func create(path: String, directory: Bool) throws {
        let (parent, name) = try parentAndName(path: path)
        defer { close(parent) }
        if directory {
            guard mkdirat(parent, name, mode_t(0o777)) == 0 else { throw FilesError.system(errno) }
        } else {
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o666))
            guard fd >= 0 else { throw FilesError.system(errno) }
            close(fd)
        }
    }

    func rename(path: String, name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw FilesError.invalidPath }
        let (parent, source) = try parentAndName(path: path)
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, source, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw FilesError.system(errno) }
        guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw FilesError.symlinkForbidden }
        if source == name { return }
        #if os(Linux)
        guard let symbol = dlsym(nil, "renameat2") else { throw FilesError.operationFailed }
        let renameExclusive = unsafeBitCast(symbol, to: (@convention(c) (Int32, UnsafePointer<CChar>, Int32, UnsafePointer<CChar>, UInt32) -> Int32).self)
        let result = source.withCString { old in name.withCString { new in renameExclusive(parent, old, parent, new, 1) } }
        #else
        let result = renameatx_np(parent, source, parent, name, UInt32(RENAME_EXCL))
        #endif
        guard result == 0 else { throw FilesError.system(errno) }
    }

    func trash(path: String) throws {
        let (parent, name) = try parentAndName(path: path)
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw FilesError.system(errno) }
        guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw FilesError.symlinkForbidden }
        let target = URL(fileURLWithPath: files.root, isDirectory: true).appendingPathComponent(path)
        #if os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gio", "trash", "--", target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { throw FilesError.operationFailed }
        guard process.terminationStatus == 0 else { throw FilesError.operationFailed }
        #else
        do { try FileManager.default.trashItem(at: target, resultingItemURL: nil) }
        catch { throw FilesError.operationFailed }
        #endif
    }

}
