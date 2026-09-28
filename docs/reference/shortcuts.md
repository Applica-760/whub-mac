# キーボードショートカット

作用対象ごとの一覧。追加・変更時はこの文書も更新する。

## アプリ・ウィンドウ

| ショートカット | 操作 |
| --- | --- |
| ⌃⌘F | フルスクリーンを切り替える |
| ⇧⌘W | Workspace に移動する |
| ⇧⌘B | Browser に移動する |

実装：[whubApp.swift](../../whub/whubApp.swift)

## タブ

| ショートカット | 操作 | 作用対象 |
| --- | --- | --- |
| ⌘T | タブを追加する | Browser では Browser、Workspace では Terminal |
| ⌘W | 選択中のタブを閉じる | Browser / Workspace の File・Terminal |
| ⌘R | 選択中のページを再読み込みする | Browser |
| ⌘1〜⌘9 | 番号に対応するタブに移動する | Terminal にフォーカスがあるとき |

実装：[FileTab.swift](../../whub/Features/Files/Viewer/FileTab.swift)、[TabBar.swift](../../whub/Components/TabBar.swift)、[WorkspaceView.swift](../../whub/Features/Workspace/WorkspaceView.swift)、[TerminalView.swift](../../whub/Features/Terminal/TerminalView.swift)、[BrowserView.swift](../../whub/Features/Browser/BrowserView.swift)、[TerminalStore.swift](../../whub/Features/Terminal/TerminalStore.swift)

## ファイル編集

エディタにフォーカスがあるときに作用する。

| ショートカット | 操作 |
| --- | --- |
| ⌘S | 編集中のファイルを保存する |
| ⌘C / ⌘V / ⌘X | コピー / 貼り付け / 切り取り |
| ⌘A | 全選択する |
| ⌘Z | Undo |
| ⇧⌘Z | Redo |

実装：[CodeViewerView.swift](../../whub/Features/Files/Viewer/Code/CodeViewerView.swift)、[whubApp.swift](../../whub/whubApp.swift)。

## 左ナビゲーション

| ショートカット | 操作 |
| --- | --- |
| ⇧⌘R | Project / Worktree の一覧、ファイル一覧、Git 状態を更新する |
| ⇧⌘↑ | 一つ前の Project / Worktree に移動する |
| ⇧⌘↓ | 一つ後の Project / Worktree に移動する |

実装：[whubApp.swift](../../whub/whubApp.swift)、[ProjectNavigation.swift](../../whub/Features/Files/Explorer/ProjectNavigation.swift)、[FileExplorerView.swift](../../whub/Features/Files/Explorer/FileExplorerView.swift)
