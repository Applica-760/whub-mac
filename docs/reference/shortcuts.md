# キーボードショートカット

アプリが明示的に割り当てたキー操作の一覧。追加・変更時はこの表も更新する。

| ショートカット | 操作 | 実装のパスと位置 |
| --- | --- | --- |
| ⌃⌘F | フルスクリーンを切り替える | [whub/whubApp.swift:37](../../whub/whubApp.swift#L37) |
| ⇧⌘W | Workspace に移動する | [whub/whubApp.swift:41](../../whub/whubApp.swift#L41) |
| ⇧⌘B | Browser に移動する | [whub/whubApp.swift:43](../../whub/whubApp.swift#L43) |
| ⌘R | Browser の選択中ページを再読み込みする | [BrowserView.swift:77](../../whub/Features/Browser/BrowserView.swift#L77) |
| ⌘T | Browser でタブを追加する | [whub/Features/Browser/BrowserView.swift:30](../../whub/Features/Browser/BrowserView.swift#L30) |
| ⌘T | Terminal でセッションを追加し、入力先を新しいターミナルに移す | [whub/Features/Terminal/TerminalView.swift](../../whub/Features/Terminal/TerminalView.swift) |
| ⌘1〜⌘9 | ターミナルに入力先があるとき、番号に対応するタブへ移動する | [TerminalStore.swift](../../whub/Features/Terminal/TerminalStore.swift) |
| ⌘W | Browser / Terminal の選択中タブを閉じる。Workspace では表示直後または最後にクリックした Terminal ペインに作用。Terminal でコマンド実行中は確認する | [TabBar.swift](../../whub/Components/TabBar.swift)、[TerminalView.swift](../../whub/Features/Terminal/TerminalView.swift)、[WorkspaceView.swift](../../whub/Features/Workspace/WorkspaceView.swift) |
| ⌘W | File の選択中タブを閉じる。Workspace では最後にクリックした File ペインに作用。ウィンドウ終了には使用しない | [FileViewerView.swift](../../whub/Features/Files/Viewer/FileViewerView.swift)、[whubApp.swift](../../whub/whubApp.swift) |
