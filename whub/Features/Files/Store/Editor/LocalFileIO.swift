import Foundation

/// Blocking disk work stays off the UI and is ordered per open file.
nonisolated final class LocalFileIO: Sendable {
    struct Content: Sendable {
        let data: Data
        let source: String?
    }

    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "whub.local-file", qos: .userInitiated)) {
        self.queue = queue
    }

    func read(_ url: URL, comparedTo savedData: Data? = nil) async throws -> Content? {
        try await perform {
            let data = try Data(contentsOf: url)
            if data == savedData { return nil }
            return Content(data: data, source: FileEncoding.decode(data))
        }
    }

    func save(_ url: URL, source: String, savedSource: String?, savedData: Data,
              overwriting diskData: Data?) async throws -> Data? {
        try await perform {
            let target = url.resolvingSymlinksInPath()
            let current = try Data(contentsOf: target)
            guard current == (diskData ?? savedData) else { throw LocalFileStore.SaveError.changedOnDisk(current) }
            guard source != savedSource || diskData != nil else { return nil }
            guard FileManager.default.isWritableFile(atPath: target.path) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let data = FileEncoding.encode(source, preserving: savedData)
            try data.write(to: target, options: .atomic)
            return data
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
