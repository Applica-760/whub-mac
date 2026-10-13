import Foundation

nonisolated enum CodexJSON {
    static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return string
    }
}
