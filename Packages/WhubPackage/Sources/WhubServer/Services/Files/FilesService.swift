import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct FilesService: Sendable {
    let root: String

    init(root: String) throws {
        guard root.hasPrefix("/"), !root.contains("\0"),
              !root.split(separator: "/").contains("..") else {
            throw FilesError.invalidPath
        }
        self.root = root
        let fd = try openTarget(path: "", directory: true)
        close(fd)
    }

    func openTarget(path: String, directory: Bool) throws -> Int32 {
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

}
