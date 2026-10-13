import Foundation

enum CodexCommand: String, CaseIterable {
    case new = "/new"
    case stop = "/stop"
    case skills = "/skills"
    case status = "/status"
    case model = "/model"
    case resume = "/resume"
}

struct CodexSkill: Identifiable {
    let name: String
    let description: String
    let path: String
    var id: String { path }
    func isMentioned(in text: String) -> Bool {
        let pattern = "(?<!\\S)\\$" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_-])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

enum CodexStatusFailure {
    case settings, account, rateLimits
}

struct CodexStatusSnapshot {
    let directory: String
    let threadID: String?
    let settings: [String: Any]
    let config: [String: Any]?
    let account: [String: Any]?
    let limits: [String: Any]?
    let tokenUsage: [String: Any]?
    let failures: [CodexStatusFailure]
}

enum CodexCommandOutput {
    case text(String)
    case json([String: Any])
    case status(CodexStatusSnapshot)
    case newConversation
    case modelChanged(name: String, effort: String)
    case stopRequested, stopped, noRunningTask
    case missingDirectory, directoryChanged
}
