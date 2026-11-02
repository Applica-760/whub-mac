import Foundation
import Synchronization
import Testing
@testable import whub

@Suite @MainActor
struct DiffCalculationTests {
    @Test func stopsRunningWorkAndStartsOnlyLatestRequest() async throws {
        let calculation = DiffCalculation<Int>()
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let first = Task {
            try await calculation.run {
                entered.withLock { $0 = true }
                release.wait()
                try Task.checkCancellation()
                return 1
            }
        }
        try await waitForGitTest { entered.withLock { $0 } }
        var secondRequested = false
        let secondRan = Mutex(false)
        let second = Task {
            secondRequested = true
            return try await calculation.run {
                secondRan.withLock { $0 = true }
                return 2
            }
        }
        try await waitForGitTest { secondRequested }
        var thirdRequested = false
        let third = Task {
            thirdRequested = true
            return try await calculation.run { 3 }
        }
        try await waitForGitTest { thirdRequested }
        #expect(!secondRan.withLock { $0 })
        release.signal()
        #expect(await first.result.failure is CancellationError)
        #expect(await second.result.failure is CancellationError)
        #expect(try await third.value == 3)
        #expect(!secondRan.withLock { $0 })
    }

    @Test func parentCancellationReachesRunningCalculation() async throws {
        let calculation = DiffCalculation<Int>()
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let parent = Task {
            try await calculation.run {
                entered.withLock { $0 = true }
                release.wait()
                try Task.checkCancellation()
                return 1
            }
        }
        try await waitForGitTest { entered.withLock { $0 } }
        parent.cancel()
        release.signal()
        #expect(await parent.result.failure is CancellationError)
        #expect(try await calculation.run { 2 } == 2)
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
