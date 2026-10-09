import CoreServices
import Foundation

final class LocalFileWatcher {
    enum Event {
        case changed([String])
        case rescan
    }

    enum StartError: LocalizedError {
        case failed

        var errorDescription: String? { "ファイル変更の監視を開始できません。" }
    }

    private var eventStream: FSEventStreamRef?
    private var watchedPaths: Set<String> = []
    private let onChange: (Event) -> Void

    init(onChange: @escaping (Event) -> Void) {
        self.onChange = onChange
    }

    deinit {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
    }

    // Accepts directory paths; returns whether the active monitoring targets changed.
    @discardableResult
    func start(paths: Set<String>) throws -> Bool {
        let paths = Set(paths.flatMap { path in
            let url = URL(fileURLWithPath: path)
            return [url.standardizedFileURL, url.resolvingSymlinksInPath()].map { url in
                var directory = url
                while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
                    directory.deleteLastPathComponent()
                }
                return directory.path
            }
        })
        guard paths != watchedPaths else { return false }
        stop()
        guard !paths.isEmpty else { return true }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<LocalFileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            )
            let rescan = (0..<count).contains { flags[$0] & rescanFlags != 0 }
            MainActor.assumeIsolated {
                watcher.onChange(rescan ? .rescan : .changed(paths))
            }
        }, &context, Array(paths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags)
        else { throw StartError.failed }

        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw StartError.failed
        }
        eventStream = stream
        watchedPaths = paths
        return true
    }

    func stop() {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
        watchedPaths = []
    }
}
