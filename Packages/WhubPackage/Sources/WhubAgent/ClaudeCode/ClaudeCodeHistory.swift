import Foundation

enum ClaudeCodeHistory {
    private static let pageSize = 20
    private static let summaryBytes = 65_536

    static func page(directory: String, cursor: String?) throws -> AgentHistoryPage {
        var index = 0
        if let cursor {
            guard let value = Int(cursor), value >= 0 else { throw AgentError(.invalidInput, "会話一覧の取得位置が不正です。") }
            index = value
        }
        let files = try sessionFiles(directory: directory)
        var entries: [AgentHistoryEntry] = []
        while index < files.count, entries.count < pageSize {
            let file = files[index]
            index += 1
            let records = try summaryRecords(file.url)
            if let entry = ClaudeCodeMapping.historyEntry(id: file.id, directory: directory, updatedAt: file.updatedAt,
                                                          head: records.head, tail: records.tail) {
                entries.append(entry)
            }
        }
        return AgentHistoryPage(entries: entries, nextCursor: index < files.count ? String(index) : nil)
    }

    static func exchanges(sessionID: String, directory: String) throws -> [AgentExchange] {
        guard UUID(uuidString: sessionID) != nil else { throw AgentError(.invalidInput, "会話IDが不正です。") }
        let url = projectDirectory(directory).appendingPathComponent(sessionID + ".jsonl")
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw AgentError(.notFound, "会話の履歴ファイルが見つかりません: \(sessionID)")
        }
        return try ClaudeCodeMapping.exchanges(conversation(records(data)))
    }

    private static func projectDirectory(_ directory: String) -> URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let name = String(decoding: directory.utf16.map { unit in
            (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) ? unit : 45
        }, as: UTF16.self)
        return base.appendingPathComponent("projects").appendingPathComponent(name)
    }

    private static func sessionFiles(directory: String) throws -> [(id: String, url: URL, updatedAt: Date)] {
        let folder = projectDirectory(directory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
            .compactMap { url -> (id: String, url: URL, updatedAt: Date)? in
                let id = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "jsonl", UUID(uuidString: id) != nil else { return nil }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, let updatedAt = values.contentModificationDate else { return nil }
                return (id, url, updatedAt)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func summaryRecords(_ url: URL) throws -> (head: [[String: Any]], tail: [[String: Any]]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = records(try handle.read(upToCount: summaryBytes) ?? Data())
        guard size > UInt64(summaryBytes) else { return (head, head) }
        try handle.seek(toOffset: size - UInt64(summaryBytes))
        return (head, records(try handle.read(upToCount: summaryBytes) ?? Data()))
    }

    private static func records(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    private static func conversation(_ records: [[String: Any]]) -> [[String: Any]] {
        let types: Set = ["user", "assistant", "progress", "system", "attachment"]
        let entries = records.filter { $0["uuid"] is String && types.contains($0["type"] as? String ?? "") }
        func id(_ index: Int) -> String { entries[index]["uuid"] as? String ?? "" }
        func isMessage(_ index: Int) -> Bool { ["user", "assistant"].contains(entries[index]["type"] as? String) }
        func isMain(_ index: Int) -> Bool { entries[index]["isSidechain"] as? Bool != true && entries[index]["teamName"] == nil }
        func messageID(_ index: Int) -> String? {
            entries[index]["type"] as? String == "assistant" ? (entries[index]["message"] as? [String: Any])?["id"] as? String : nil
        }
        func blocks(_ index: Int, _ type: String, _ key: String) -> [String] {
            ((entries[index]["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == type }.compactMap { $0[key] as? String }
        }

        var byID: [String: Int] = [:]
        var byMessage: [String: [Int]] = [:]
        var resultsByTool: [String: [Int]] = [:]
        for index in entries.indices {
            byID[id(index)] = index
            guard isMain(index) else { continue }
            if let messageID = messageID(index) { byMessage[messageID, default: []].append(index) }
            if entries[index]["type"] as? String == "user" {
                for tool in blocks(index, "tool_result", "tool_use_id") { resultsByTool[tool, default: []].append(index) }
            }
        }
        func parent(_ index: Int) -> Int? { (entries[index]["parentUuid"] as? String).flatMap { byID[$0] } }

        let parents = Set(entries.compactMap { $0["parentUuid"] as? String })
        var candidates: [Int] = []
        for terminal in entries.indices where !parents.contains(id(terminal)) {
            var current: Int? = terminal
            var visited = Set<Int>()
            while let index = current, visited.insert(index).inserted {
                if isMessage(index) {
                    candidates.append(index)
                    break
                }
                current = parent(index)
            }
        }
        let preferred = candidates.filter { isMain($0) && entries[$0]["isMeta"] as? Bool != true }
        guard let leaf = (preferred.isEmpty ? candidates : preferred).max() else { return [] }

        var chain: [Int] = []
        var included = Set<Int>()
        var current: Int? = leaf
        while let index = current, included.insert(index).inserted {
            chain.append(index)
            current = parent(index)
        }
        chain.reverse()

        var result: [[String: Any]] = []
        for (position, index) in chain.enumerated() {
            result.append(entries[index])
            guard let response = messageID(index),
                  position + 1 == chain.count || messageID(chain[position + 1]) != response,
                  let group = byMessage[response] else { continue }
            let tools = group.flatMap { blocks($0, "tool_use", "id") }
            let missing = group + tools.flatMap { resultsByTool[$0] ?? [] }
            for recovered in missing where included.insert(recovered).inserted { result.append(entries[recovered]) }
        }
        return result
    }
}
