import Foundation

@MainActor
final class DiffCalculation<Value: Sendable> {
    private var revision = 0
    private var task: Task<Value, Error>?

    func cancel() {
        revision += 1
        task?.cancel()
    }

    func run(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        cancel()
        let revision = revision
        // Wait for cancellation to finish before starting another CPU-bound calculation.
        if let task { _ = await task.result }
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try operation()
        }
        self.task = task
        defer {
            if self.revision == revision { self.task = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    deinit { task?.cancel() }
}
