# キーボードショートカット

アプリが明示的に割り当てたキー操作の一覧。追加・変更時はこの表も更新する。

| ショートカット | 操作 | 実装のパスと位置 |
| --- | --- | --- |
| ⌃⌘F | フルスクリーンを切り替える | [whub/whubApp.swift](../../whub/whubApp.swift) |
| ⇧⌘W | 現在のウィンドウを閉じる | [whubApp.swift](../../whub/whubApp.swift) |
| ⇧⌘B | Browser に移動する | [whub/whubApp.swift](../../whub/whubApp.swift) |
| ⇧⌘R | 左ナビゲーションのファイル一覧・Git状態とファイル表示を再読み込みする | [whub/whubApp.swift](../../whub/whubApp.swift) |
| ⇧⌘↑ | 選択中のProject / Worktreeから一覧の一つ上へ移動する（先頭で停止） | [whubApp.swift](../../whub/whubApp.swift)、[ProjectNavigation.swift](../../whub/Features/Files/Explorer/ProjectNavigation.swift) |
| ⇧⌘↓ | 選択中のProject / Worktreeから一覧の一つ下へ移動する（末尾で停止） | [whubApp.swift](../../whub/whubApp.swift)、[ProjectNavigation.swift](../../whub/Features/Files/Explorer/ProjectNavigation.swift) |
| ⌘R | Browser の選択中ページを再読み込みする | [BrowserView.swift:77](../../whub/Features/Browser/BrowserView.swift#L77) |
| ⌘T | Browser でタブを追加する | [whub/Features/Browser/BrowserView.swift:30](../../whub/Features/Browser/BrowserView.swift#L30) |
| ⌘T | Terminal でセッションを追加し、入力先を新しいターミナルに移す | [whub/Features/Terminal/TerminalView.swift](../../whub/Features/Terminal/TerminalView.swift) |
| ⌘1〜⌘9 | ターミナルに入力先があるとき、番号に対応するタブへ移動する | [TerminalStore.swift](../../whub/Features/Terminal/TerminalStore.swift) |
| ⌘W | Browser / Terminal の選択中タブを閉じる。Workspace では表示直後または最後にクリックした Terminal ペインに作用。Terminal でコマンド実行中は確認する | [TabBar.swift](../../whub/Components/TabBar.swift)、[TerminalView.swift](../../whub/Features/Terminal/TerminalView.swift)、[WorkspaceView.swift](../../whub/Features/Workspace/WorkspaceView.swift) |
| ⌘W | File の選択中タブを閉じる。Workspace では最後にクリックした File ペインに作用。ウィンドウ終了には使用しない | [FileViewerView.swift](../../whub/Features/Files/Viewer/FileViewerView.swift)、[whubApp.swift](../../whub/whubApp.swift) |
