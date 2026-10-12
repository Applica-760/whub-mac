import Foundation

// Field order and remaining-quota notation follow Codex CLI's status/card.rs.
enum CodexStatus {
    static func codeBlock(_ text: String) -> String {
        let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + text + "\n" + fence
    }

    static func render(directory: String, threadID: String?, settings: [String: Any],
                       config: [String: Any]?, account: [String: Any]?, limits: [String: Any]?,
                       tokenUsage: [String: Any]?, failures: [String],
                       timeZone: TimeZone = .current) -> String {
        var rows: [(String, String)] = []
        func value(_ source: [String: Any]?, _ key: String) -> String? {
            guard let text = source?[key] as? String, !text.isEmpty else { return nil }
            return text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        let active = threadID != nil
        let model = active ? value(settings, "model") : value(config, "model")
        let effort = active ? value(settings, "effort") : value(config, "model_reasoning_effort")
        rows.append(("Model", (model ?? "Not available") + (effort.map { " (reasoning \($0))" } ?? "")))
        if let provider = active ? value(settings, "modelProvider") : value(config, "model_provider") {
            rows.append(("Model provider", provider))
        }
        rows.append(("Directory", directory))
        let sandbox = active ? value(settings["sandboxPolicy"] as? [String: Any], "type") : value(config, "sandbox_mode")
        let policy = active ? value(settings, "approvalPolicy") : value(config, "approval_policy")
        let reviewer = active ? value(settings, "approvalsReviewer") : value(config, "approvals_reviewer")
        rows.append(("Permissions", [sandbox, policy, reviewer].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Not available"))
        if let sources = settings["instructionSources"] as? [String] {
            rows.append(("Agents.md", sources.isEmpty ? "<none>" : sources.joined(separator: ", ")))
        }
        if let tier = active ? value(settings, "serviceTier") : value(config, "service_tier") {
            rows.append(("Service tier", tier))
        }
        switch account?["type"] as? String {
        case "apiKey": rows.append(("Account", "API key configured"))
        case "chatgpt":
            rows.append(("Account", [value(account, "email"), value(account, "planType")].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "ChatGPT"))
        default: rows.append(("Account", failures.contains("Account") ? "Unavailable" : "Not signed in"))
        }
        rows.append(("Session", threadID ?? "Not started"))
        if !active { rows.append(("Settings", "Configured defaults; session not started")) }
        if let last = tokenUsage?["last"] as? [String: Any],
           let used = (last["totalTokens"] as? NSNumber)?.doubleValue,
           let window = (tokenUsage?["modelContextWindow"] as? NSNumber)?.doubleValue, window > 0, used.isFinite, window.isFinite {
            let remaining = max(0, min(100, (1 - used / window) * 100))
            rows.append(("Context window", "\(Int(remaining))% left (\(used.formatted(.number.precision(.fractionLength(0)))) used / \(window.formatted(.number.precision(.fractionLength(0)))))"))
        }
        if account?["type"] as? String == "apiKey" {
            rows.append(("Rate limits", "Not available for API key authentication"))
        } else if let limits {
            let buckets = limits["rateLimitsByLimitId"] as? [String: [String: Any]]
            let snapshots: [(String, [String: Any])] = buckets?.sorted { $0.key < $1.key }
                ?? (limits["rateLimits"] as? [String: Any]).map { [("", $0)] } ?? []
            for (id, snapshot) in snapshots {
                for key in ["primary", "secondary"] {
                    guard let window = snapshot[key] as? [String: Any],
                          let used = (window["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite,
                          let minutes = window["windowDurationMins"] as? Int, minutes > 0 else { continue }
                    let label = minutes == 10080 ? "Weekly limit" : minutes % 60 == 0 ? "\(minutes / 60)h limit" : "\(minutes)m limit"
                    let remaining = max(0, min(100, 100 - used))
                    let filled = Int(remaining / 5)
                    var text = "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled) + "] \(Int(remaining))% left"
                    if let resets = (window["resetsAt"] as? NSNumber)?.doubleValue, resets.isFinite {
                        let formatter = DateFormatter()
                        formatter.timeZone = timeZone
                        formatter.dateFormat = "MM/dd HH:mm z"
                        text += " (resets \(formatter.string(from: Date(timeIntervalSince1970: resets))))"
                    }
                    rows.append(((snapshots.count > 1 ? (value(snapshot, "limitName") ?? id) + " · " : "") + label, text))
                }
                if let credits = snapshot["credits"] as? [String: Any] {
                    if credits["unlimited"] as? Bool == true { rows.append(("Credits", "Unlimited")) }
                    else if let balance = value(credits, "balance") { rows.append(("Credits", balance)) }
                    else if let available = credits["hasCredits"] as? Bool { rows.append(("Credits", available ? "Available" : "Unavailable")) }
                }
            }
            if !rows.contains(where: { $0.0.contains("limit") }) { rows.append(("Rate limits", "Not available")) }
        } else {
            rows.append(("Rate limits", "Not available"))
        }
        for field in failures { rows.append((field, "Unable to retrieve")) }
        let width = rows.map { $0.0.count }.max() ?? 0
        return rows.map { $0.0 + ":" + String(repeating: " ", count: width - $0.0.count + 2) + $0.1 }.joined(separator: "\n")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension CodexCommandsStore {
    func statusText(session: CodexStore) async -> String {
        let directory = session.directory
        let threadID = session.threadID
        let settings = session.settings
        let usage = session.tokenUsage
        var config: [String: Any]?
        var account: [String: Any]?
        var limits: [String: Any]?
        var failures: [String] = []
        do {
            let result = try await request("config/read", ["includeLayers": false, "cwd": directory], directory)
            config = result["config"] as? [String: Any]
            if config == nil { failures.append("Settings") }
        } catch { failures.append("Settings") }
        do {
            let result = try await request("account/read", ["refreshToken": false], directory)
            account = result["account"] as? [String: Any]
            if result["account"] == nil || (result["account"] is NSNull == false && account == nil) {
                failures.append("Account")
            }
        } catch { failures.append("Account") }
        if account?["type"] as? String == "chatgpt" {
            do { limits = try await request("account/rateLimits/read", [:], directory) }
            catch { failures.append("Rate limits") }
        }
        return CodexStatus.render(directory: directory, threadID: threadID, settings: settings,
                                  config: config, account: account, limits: limits, tokenUsage: usage, failures: failures)
    }
}
