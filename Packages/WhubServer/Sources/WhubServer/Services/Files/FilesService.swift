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

    init(root: String) throws {
        guard root.hasPrefix("/"), !root.contains("\0"),
              !root.split(separator: "/").contains("..") else {
            throw FilesError.invalidPath
        }
        self.root = root
        let fd = try openDirectory(path: "")
        close(fd)
    }

    private func openDirectory(path: String) throws -> Int32 {
        guard !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else {
            throw FilesError.invalidPath
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FilesError.system(errno) }
        do {
            for part in (root + "/" + path).split(separator: "/") where part != "." {
                let name = String(part)
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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
        let fd = try openDirectory(path: path)
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
}
