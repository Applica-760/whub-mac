import Foundation

enum ClaudeCodeStatusFailure: String {
    case status = "Status"
    case context = "Context window"
    case usage = "Rate limits"
}

struct ClaudeCodeStatusSnapshot {
    let status: [String: Any]?
    let settings: [String: Any]
    let permissionMode: String?
    let context: [String: Any]?
    let usage: [String: Any]?
    let failures: [ClaudeCodeStatusFailure]
}

extension ClaudeCodeMapping {
    static func statusText(_ snapshot: ClaudeCodeStatusSnapshot, timeZone: TimeZone = .current) -> String {
        var rows: [(String, String)] = []
        for section in snapshot.status?["sections"] as? [[String: Any]] ?? [] {
            for row in section["rows"] as? [[String: Any]] ?? [] {
                guard let label = row["label"] as? String, label != "Peer address",
                      let value = row["value"] as? String, !value.isEmpty else { continue }
                rows.append((label, value.replacingOccurrences(of: "\n", with: " ")))
            }
        }
        if let effort = snapshot.settings["effort"] as? String { rows.append(("Effort", effort)) }
        if let mode = snapshot.permissionMode { rows.append(("Permission mode", mode)) }
        if let used = (snapshot.context?["totalTokens"] as? NSNumber)?.doubleValue,
           let window = (snapshot.context?["maxTokens"] as? NSNumber)?.doubleValue, window > 0, used.isFinite, window.isFinite {
            let remaining = max(0, min(100, (1 - used / window) * 100))
            rows.append(("Context window", "\(Int(remaining))% left (\(used.formatted(.number.precision(.fractionLength(0)))) used / \(window.formatted(.number.precision(.fractionLength(0)))))"))
        }
        if let usage = snapshot.usage {
            let limits = usage["rate_limits"] as? [String: Any]
            if usage["rate_limits_available"] as? Bool == true, let limits {
                let parser = ISO8601DateFormatter()
                parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let formatter = DateFormatter()
                formatter.timeZone = timeZone
                formatter.dateFormat = "MM/dd HH:mm z"
                for (key, label) in [("five_hour", "5h limit"), ("seven_day", "Weekly limit"),
                                     ("seven_day_opus", "Weekly Opus limit"), ("seven_day_sonnet", "Weekly Sonnet limit")] {
                    guard let window = limits[key] as? [String: Any],
                          let used = (window["utilization"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
                    let remaining = max(0, min(100, 100 - used))
                    let filled = Int(remaining / 5)
                    var text = "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled) + "] \(Int(remaining))% left"
                    if let resets = (window["resets_at"] as? String).flatMap(parser.date) {
                        text += " (resets \(formatter.string(from: resets)))"
                    }
                    rows.append((label, text))
                }
            }
            if !rows.contains(where: { $0.0.contains("limit") }) { rows.append(("Rate limits", "Not available")) }
            if let cost = ((usage["session"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue, cost.isFinite {
                rows.append(("Session cost", String(format: "$%.4f", cost)))
            }
        }
        for failure in snapshot.failures { rows.append((failure.rawValue, "Unable to retrieve")) }
        let width = rows.map { $0.0.count }.max() ?? 0
        return rows.map { $0.0 + ":" + String(repeating: " ", count: width - $0.0.count + 2) + $0.1 }.joined(separator: "\n")
    }
}
