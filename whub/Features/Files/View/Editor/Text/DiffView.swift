import AppKit
import SwiftUI
import WhubCore

nonisolated struct DiffLine: Sendable, Equatable {
    let number: Int?
    let source: String
    let change: GitChange?

    var displayText: String {
        let ending = source.hasSuffix("\r\n") ? 2 : (source.hasSuffix("\n") ? 1 : 0)
        return (source as NSString).substring(to: source.utf16.count - ending) + "\n"
    }
}

nonisolated struct DiffLayout: Sendable {
    let before: [DiffLine]
    let after: [DiffLine]

    init(before: String, after: String) {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var result = text.components(separatedBy: "\n")
            for index in 0..<(result.count - 1) { result[index] += "\n" }
            if result.last == "" { result.removeLast() }
            return result
        }
        let old = lines(before)
        let new = lines(after)
        var left: [DiffLine] = []
        var right: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        for hunk in Git.diff(from: before, to: after) {
            while oldIndex < hunk.oldLines.lowerBound {
                left.append(DiffLine(number: oldIndex + 1, source: old[oldIndex], change: nil))
                right.append(DiffLine(number: newIndex + 1, source: new[newIndex], change: nil))
                oldIndex += 1
                newIndex += 1
            }
            let modified = !hunk.oldLines.isEmpty && !hunk.newLines.isEmpty
            for offset in 0..<max(hunk.oldLines.count, hunk.newLines.count) {
                left.append(offset < hunk.oldLines.count
                    ? DiffLine(number: oldIndex + offset + 1, source: old[oldIndex + offset], change: modified ? .modified : .deleted)
                    : DiffLine(number: nil, source: "", change: nil))
                right.append(offset < hunk.newLines.count
                    ? DiffLine(number: newIndex + offset + 1, source: new[newIndex + offset], change: modified ? .modified : .added)
                    : DiffLine(number: nil, source: "", change: nil))
            }
            oldIndex = hunk.oldLines.upperBound
            newIndex = hunk.newLines.upperBound
        }
        while oldIndex < old.count {
            left.append(DiffLine(number: oldIndex + 1, source: old[oldIndex], change: nil))
            right.append(DiffLine(number: newIndex + 1, source: new[newIndex], change: nil))
            oldIndex += 1
            newIndex += 1
        }
        self.before = left
        self.after = right
    }

    static func copiedText(lines: [DiffLine], range: NSRange) -> String {
        var offset = 0
        var result = ""
        for line in lines {
            let length = line.displayText.utf16.count
            let selection = NSIntersectionRange(range, NSRange(location: offset, length: length))
            if line.number != nil, selection.length > 0 {
                let start = selection.location - offset
                let contentLength = length - 1
                let end = min(start + selection.length, contentLength)
                let original = line.source as NSString
                if start < end { result += original.substring(with: NSRange(location: start, length: end - start)) }
                if start + selection.length > contentLength { result += original.substring(from: contentLength) }
            }
            offset += length
        }
        return result
    }
}

struct DiffView: View {
    let before: String
    let after: String
    let fileURL: URL
    @State private var layout: DiffLayout?
    @State private var beforeFile = FileStore(source: "")
    @State private var afterFile = FileStore(source: "")
    @State private var scrolling = DiffScrollSync()

    private struct Source: Equatable { let before: String; let after: String }

    var body: some View {
        HStack(spacing: 0) {
            pane(title: "HEAD · コミット済み", file: beforeFile, lines: layout?.before, before: true)
            Divider()
            pane(title: "作業ツリー · 保存済み", file: afterFile, lines: layout?.after, before: false)
        }
        .background(Color(white: 0.07).opacity(0.75))
        .task(id: Source(before: before, after: after)) {
            let before = before
            let after = after
            let loaded = await Task.detached(priority: .utility) { DiffLayout(before: before, after: after) }.value
            guard !Task.isCancelled else { return }
            beforeFile.updateReadOnly(source: loaded.before.map(\.displayText).joined())
            afterFile.updateReadOnly(source: loaded.after.map(\.displayText).joined())
            layout = loaded
        }
        .onDisappear { scrolling.disconnect() }
    }

    private func pane(title: String, file: FileStore, lines: [DiffLine]?, before: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            if let lines {
                CodeEditorView(state: file, editorID: "diff", onEdit: {}, source: file.textStorage.string,
                               language: codeLanguages[fileURL.pathExtension.lowercased()], hunks: [], diffLines: lines,
                               onScrollView: { scrolling.attach($0, before: before) })
                    .accessibilityLabel(title)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class DiffScrollSync: NSObject {
    private weak var before: NSScrollView?
    private weak var after: NSScrollView?
    private var syncing = false

    func attach(_ scroll: NSScrollView, before isBefore: Bool) {
        if isBefore {
            guard before !== scroll else { return }
            before = scroll
        } else {
            guard after !== scroll else { return }
            after = scroll
        }
        NotificationCenter.default.removeObserver(self)
        for pane in [before, after].compactMap({ $0 }) {
            pane.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: pane.contentView)
        }
    }

    func disconnect() {
        NotificationCenter.default.removeObserver(self)
        before = nil
        after = nil
    }

    @objc private func scrolled(_ notification: Notification) {
        guard !syncing, let source = notification.object as? NSClipView,
              let target = source === before?.contentView ? after : before else { return }
        let y = source.bounds.origin.y
        guard target.contentView.bounds.origin.y != y else { return }
        syncing = true
        target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.origin.x, y: y))
        target.reflectScrolledClipView(target.contentView)
        syncing = false
    }
}
