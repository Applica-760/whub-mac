import Foundation

extension CodexCommandsStore {
    func loadStatus(session: CodexStore) async -> CodexStatusSnapshot {
        let directory = session.directory
        let threadID = session.threadID
        let settings = session.settings
        let usage = session.tokenUsage
        var config: [String: Any]?
        var account: [String: Any]?
        var limits: [String: Any]?
        var failures: [CodexStatusFailure] = []
        do {
            let result = try await request("config/read", ["includeLayers": false, "cwd": directory], directory)
            config = result["config"] as? [String: Any]
            if config == nil { failures.append(.settings) }
        } catch { failures.append(.settings) }
        do {
            let result = try await request("account/read", ["refreshToken": false], directory)
            account = result["account"] as? [String: Any]
            if result["account"] == nil || (result["account"] is NSNull == false && account == nil) {
                failures.append(.account)
            }
        } catch { failures.append(.account) }
        if account?["type"] as? String == "chatgpt" {
            do { limits = try await request("account/rateLimits/read", [:], directory) }
            catch { failures.append(.rateLimits) }
        }
        return CodexStatusSnapshot(directory: directory, threadID: threadID, settings: settings,
                                  config: config, account: account, limits: limits, tokenUsage: usage, failures: failures)
    }
}
