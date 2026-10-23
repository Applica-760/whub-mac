import Foundation
import WhubCore

@MainActor
func waitForEditorTest(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}
