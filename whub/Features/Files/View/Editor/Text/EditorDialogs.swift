import AppKit

enum EditorDialogs {
    enum CloseChoice { case save, discard, cancel }
    enum OverwriteChoice { case overwrite, adoptLatest, cancel }

    static func confirmClose(fileName: String) -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "\(fileName)の変更を保存しますか？"
        alert.informativeText = "保存せずに閉じると、編集内容は失われます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存せずに閉じる").keyEquivalent = ""
        alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    static func confirmOverwrite(fileName: String) -> OverwriteChoice {
        let alert = NSAlert()
        alert.messageText = "ファイルが外部で変更されています"
        alert.informativeText = "\(fileName)の編集内容を上書き保存するか、ディスクの最新内容を採用してください。"
        alert.addButton(withTitle: "上書き")
        alert.addButton(withTitle: "最新内容を採用")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .adoptLatest
        default: return .cancel
        }
    }

    static func show(error: Error) {
        NSAlert(error: error).runModal()
    }

    static func beep() {
        NSSound.beep()
    }
}
