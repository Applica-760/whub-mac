# キーボードショートカット

作用対象ごとの一覧。追加・変更時はこの文書も更新する。

## アプリ・ウィンドウ

| ショートカット | 操作 |
| --- | --- |
| ⌃⌘F | フルスクリーンを切り替える |
| ⇧⌘H | 一つ前のページに移動する（末尾へ循環） |
| ⇧⌘L | 一つ後のページに移動する（先頭へ循環） |
| ⌘Q | 確認アラートを表示し、「終了」を選んだ場合にアプリを終了する |

ページの順序は File → Terminal → AgentBook → Browser → Overview → Motion。

終了確認では Enter の既定動作はキャンセル。アプリメニューや Dock からの通常終了でも同じ確認を表示する。

実装：[whubApp.swift](../../whub/whubApp.swift)

## タブ

| ショートカット | 操作 | 作用対象 |
| --- | --- | --- |
| ⌘T | 表示中のページに新規タブを作る（Fileメニューからも実行可能） | Terminal / AgentBook / Browser |
| ⌘W | 選択中のタブを閉じる | File / Terminal / AgentBook / Browser |
| ⌘R | 選択中のページを再読み込みする | Browser |
| ⌘1〜⌘9 | 番号に対応するタブに移動する | フォーカス中の File・Terminal・Browser、AgentBookページ（表示順） |

TerminalとBrowserは最後の1タブを閉じられない。Terminalでコマンド実行中のタブを閉じる場合と、AgentBookのタブを閉じる場合は確認を表示する。Fileの未保存タブを閉じる場合は、保存・破棄・キャンセルを選べる。

File・Terminal・Browserのタブは同じ列内でドラッグして並べ替えられる。左右端では自動スクロールする。選択は維持し、Fileのプレビュータブは並べ替え確定時に通常タブへ昇格する。順序は起動中のみ保持する。タブの中クリックでも閉じられる。

実装：[whubApp.swift](../../whub/whubApp.swift)、[TabBarContainer.swift](../../whub/Components/TabBarContainer.swift)、[EditorTabBarView.swift](../../whub/Features/Files/View/Editor/EditorTabBarView.swift)、[TerminalView.swift](../../whub/Features/Terminal/TerminalView.swift)、[BrowserView.swift](../../whub/Features/Browser/BrowserView.swift)、[CodexView.swift](../../whub/Features/Codex/View/CodexView.swift)

## AgentBookの入力・承認

| キー | 操作 | 作用対象 |
| --- | --- | --- |
| ⌘Enter | 入力内容を送信する（作業中は追加指示として送る） | 入力欄 |
| ↑ / ↓ | 補完候補・会話・モデルの選択を移動する | 候補表示中の入力欄 |
| Enter / Tab | 選択中の候補を確定する（モデル選択はEnterのみ） | 候補表示中の入力欄 |
| Esc | 候補を閉じて本文へフォーカスを移す | 入力欄 |
| Enter / Esc | 実行・ファイル変更の要求を承認 / 拒否する | 要求を表示中のAgentBook |

通常のEnterは改行する。入力欄の `/` でコマンド、`$` でスキルの候補を表示する。承認キーは修飾キーなしで使用し、日本語変換中は作用しない。

実装：[CodexInputView.swift](../../whub/Features/Codex/View/Commands/CodexInputView.swift)、[CodexBookFocus.swift](../../whub/Features/Codex/View/Layout/CodexBookFocus.swift)

## AgentBookの本文

本文をクリックしてフォーカスを移した後に有効。ページをめくっても続けて操作できる。

| キー | 操作 |
| --- | --- |
| H / ← | 前の見開きへ移動する |
| L / → | 次の見開きへ移動する |
| / | 入力欄へ戻る。下書きとカーソル位置を保持し、このキーの文字は入力しない |

H・L・/は修飾キーなしで使用する。先頭・末尾では循環しない。入力欄では通常の文字入力・カーソル移動として扱い、入力欄内の/は既存のコマンド補完に使う。日本語変換中・ダイアログ表示中は本文操作を行わない。Enter/Escによる既存の承認操作は変更しない。

実装：[CodexBookFocus.swift](../../whub/Features/Codex/View/Layout/CodexBookFocus.swift)、[CodexBookTextView.swift](../../whub/Features/Codex/View/Layout/CodexBookTextView.swift)

## ファイル編集

エディタにフォーカスがあるときに作用する。

| ショートカット | 操作 |
| --- | --- |
| ⌘S | 編集中のファイルを保存する |
| ⌘F | 検索欄を表示する |
| ⌘C / ⌘V / ⌘X | コピー / 貼り付け / 切り取り |
| ⌘A | 全選択する |
| ⌘Z | Undo |
| ⇧⌘Z | Redo |

SSH接続先のファイルは読み取り専用。保存はローカルのテキストファイルが対象。

実装：[CodeEditorView.swift](../../whub/Features/Files/View/Editor/Text/CodeEditorView.swift)、[whubApp.swift](../../whub/whubApp.swift)。

## 左ナビゲーション

| ショートカット | 操作 |
| --- | --- |
| ⇧⌘R | Project / Worktree の一覧、ファイル一覧、Git 状態を更新する |
| ⇧⌘K | 一つ前の Project / Worktree に移動する |
| ⇧⌘J | 一つ後の Project / Worktree に移動する |

実装：[whubApp.swift](../../whub/whubApp.swift)、[ExplorerPulldownView.swift](../../whub/Features/Files/View/Explorer/Menu/ExplorerPulldownView.swift)、[ExplorerView.swift](../../whub/Features/Files/View/Explorer/ExplorerView.swift)
