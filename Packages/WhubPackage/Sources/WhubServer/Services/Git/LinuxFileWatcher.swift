#if os(Linux)
import Foundation
import Glibc

final class LinuxFileWatcher: @unchecked Sendable {
    enum Event: Equatable {
        case changed
        case rescan
    }

    struct SystemError: Error {
        let operation: String
        let code: Int32
    }

    private let descriptor: Int32
    private var directories: [Int32: URL] = [:]
    private let worktree: URL?
    private let managementDirectories: Set<URL>
    private let trackedDirectories: Set<String>
    private static let mask = UInt32(IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE |
                                     IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF)

    init(roots: Set<URL>, worktree: URL? = nil, managementDirectories: Set<URL> = []) throws {
        self.worktree = worktree?.standardizedFileURL
        self.managementDirectories = Set(managementDirectories.map(\.standardizedFileURL))
        if let worktree {
            let index = try Self.git(["ls-files", "--cached", "-z"], at: worktree)
            guard index.status == 0 else { throw SystemError(operation: "git ls-files", code: index.status) }
            let head = try Self.git(["rev-parse", "--verify", "--quiet", "HEAD"], at: worktree)
            var files = index.data
            if head.status == 0 {
                let tree = try Self.git(["ls-tree", "-r", "--name-only", "-z", "HEAD"], at: worktree)
                guard tree.status == 0 else { throw SystemError(operation: "git ls-tree", code: tree.status) }
                files.append(tree.data)
            } else if head.status != 1 {
                throw SystemError(operation: "git rev-parse", code: head.status)
            }
            var tracked: Set<String> = []
            for path in files.split(separator: 0) {
                guard let name = String(data: path, encoding: .utf8) else {
                    throw SystemError(operation: "git path encoding", code: EINVAL)
                }
                var parent = (name as NSString).deletingLastPathComponent
                while !parent.isEmpty && parent != "." {
                    tracked.insert(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            trackedDirectories = tracked
        } else {
            trackedDirectories = []
        }
        descriptor = inotify_init1(Int32(IN_CLOEXEC | IN_NONBLOCK))
        guard descriptor >= 0 else { throw SystemError(operation: "inotify_init1", code: errno) }
        do {
            for root in roots { try addDirectoryTree(root) }
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit { close(descriptor) }

    // One consumer reads events; nil means the timeout elapsed.
    func nextEvent(timeoutMilliseconds: Int32) throws -> Event? {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&item, 1, timeoutMilliseconds)
        if ready == 0 { return nil }
        guard ready > 0 else { throw SystemError(operation: "poll", code: errno) }
        guard item.revents & Int16(POLLIN) != 0 else {
            throw SystemError(operation: "poll", code: EIO)
        }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { throw SystemError(operation: "read", code: errno) }
        var offset = 0
        var result: Event?
        while offset + MemoryLayout<inotify_event>.size <= count {
            let event = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: inotify_event.self) }
            let nameStart = offset + MemoryLayout<inotify_event>.size
            let end = nameStart + Int(event.len)
            guard end <= count else { throw SystemError(operation: "inotify event", code: EIO) }
            let name = String(decoding: bytes[nameStart..<end].prefix { $0 != 0 }, as: UTF8.self)
            if event.mask & UInt32(IN_Q_OVERFLOW) != 0 {
                result = .rescan
            } else if event.mask & UInt32(IN_IGNORED) != 0 {
                directories.removeValue(forKey: event.wd)
            } else if event.mask & Self.mask != 0 {
                if event.mask & UInt32(IN_ISDIR) != 0,
                   event.mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0,
                   let parent = directories[event.wd], !name.isEmpty {
                    try addDirectoryTree(parent.appendingPathComponent(name, isDirectory: true))
                }
                let parent = directories[event.wd]
                let path = parent?.appendingPathComponent(name).standardizedFileURL
                let rulesChanged = name == ".gitignore" || managementDirectories.contains { directory in
                    path == directory.appendingPathComponent("index") ||
                    path == directory.appendingPathComponent("HEAD") ||
                    path == directory.appendingPathComponent("info/exclude") ||
                    path == directory.appendingPathComponent("config")
                }
                if rulesChanged || event.mask & UInt32(IN_DELETE_SELF | IN_MOVE_SELF) != 0 ||
                    (event.mask & UInt32(IN_ISDIR) != 0 && event.mask & UInt32(IN_DELETE | IN_MOVED_FROM) != 0) {
                    result = .rescan
                } else if result == nil {
                    result = .changed
                }
            }
            offset = end
        }
        return result
    }

    private func addDirectoryTree(_ root: URL) throws {
        let manager = FileManager.default
        var pending = [root]
        while let directory = pending.popLast() {
            if try shouldIgnore(directory) { continue }
            let wd = inotify_add_watch(descriptor, directory.path, Self.mask | UInt32(IN_ONLYDIR | IN_DONT_FOLLOW))
            guard wd >= 0 else { throw SystemError(operation: "inotify_add_watch", code: errno) }
            directories[wd] = directory
            for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true { pending.append(child) }
            }
        }
    }

    private func shouldIgnore(_ directory: URL) throws -> Bool {
        guard let worktree else { return false }
        let path = directory.standardizedFileURL.path
        let prefix = worktree.path == "/" ? "/" : worktree.path + "/"
        guard path.hasPrefix(prefix), !managementDirectories.contains(where: {
            path == $0.path || path.hasPrefix($0.path + "/")
        }) else { return false }
        let relative = String(path.dropFirst(prefix.count))
        guard !trackedDirectories.contains(relative) else { return false }
        let result = try Self.git(["check-ignore", "-q", "--no-index", "--", relative + "/"], at: worktree)
        switch result.status {
        case 0: return true
        case 1: return false
        default: throw SystemError(operation: "git check-ignore", code: result.status)
        }
    }

    private static func git(_ arguments: [String], at directory: URL) throws -> (data: Data, status: Int32) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }
}
#endif
