# キーボードショートカット

作用対象別の一覧。キーの追加・変更時に更新する。

## アプリ・ウィンドウ

| ショートカット | 操作 |
| --- | --- |
| ⌃⌘F | フルスクリーン切り替え |
| ⇧⌘A | AgentBookを開閉 |
| ⇧⌘H | 左ペインの前の機能へ移動（末尾へ循環） |
| ⇧⌘L | 左ペインの次の機能へ移動（先頭へ循環） |
| ⌘Q | 確認後、「終了」でアプリ終了 |

左ペインの順序は Editor → Browser → Terminal → Overview。ToolbarとNavigateメニューも左ペインを切り替える。Motionへの画面導線はない。

終了確認のEnterはキャンセル。アプリメニュー・Dockからの通常終了も同じ確認を使う。

実装：[whubApp.swift](../../whub/whubApp.swift)

## タブ

| ショートカット | 操作 | 作用対象 |
| --- | --- | --- |
| ⌘T | フォーカス中のFeatureに新規タブを作成（Fileメニューでも可） | Terminal / AgentBook / Browser |
| ⌘W | 選択タブを閉じる | File / Terminal / AgentBook / Browser |
| ⌘R | 選択ページを再読込 | Browser |
| ⌘1〜⌘9 | 番号のタブへ移動 | フォーカス中の File・Terminal・Browser・AgentBook（表示順） |

Terminal／Browserは最後の1タブを閉じると新しいタブに置き換える。Terminalはコマンド実行中、AgentBookは常に閉じる前に確認する。Fileの未保存タブは保存・破棄・キャンセルを選べる。

File／Terminal／Browserは同じ列内でドラッグして並べ替える。左右端では自動スクロールし、選択を維持する。Fileのプレビュータブは並べ替え確定時に通常タブになる。順序の保持は起動中のみ。中クリックでも閉じられる。

実装：[whubApp.swift](../../whub/whubApp.swift)、[TabBarContainer.swift](../../whub/Components/TabBarContainer.swift)、[EditorTabBarView.swift](../../whub/Features/Files/View/Editor/EditorTabBarView.swift)、[TerminalView.swift](../../whub/Features/Terminal/TerminalView.swift)、[BrowserView.swift](../../whub/Features/Browser/BrowserView.swift)、[AgentBookView.swift](../../whub/Features/AgentBook/View/AgentBookView.swift)、[AgentBookTabButton.swift](../../whub/Features/AgentBook/View/Controls/AgentBookTabButton.swift)

## AgentBookの入力・承認

| キー | 操作 | 作用対象 |
| --- | --- | --- |
| ⌘Enter | 送信（作業中は追加指示） | 入力欄 |
| ↑ / ↓ | 補完候補・会話・モデルの選択移動 | 候補表示中の入力欄 |
| Enter / Tab | 候補を確定（モデルはEnterのみ） | 候補表示中の入力欄 |
| Esc | 候補を閉じ、本文へフォーカス | 入力欄 |
| Enter / Esc | 実行・ファイル変更を承認 / 拒否 | 要求を表示中のAgentBook |

通常のEnterは改行。`/`はコマンド、`$`はスキル候補を表示する。承認キーは修飾キーなし。日本語変換中は無効。

実装：[AgentBookInputView.swift](../../whub/Features/AgentBook/View/Controls/AgentBookInputView.swift)、[AgentBookResponseView.swift](../../whub/Features/AgentBook/View/Exchange/AgentBookResponseView.swift)

## AgentBookの本文

本文クリックか入力欄のEscで有効になる。Book全体を1つの操作エリアとし、対象ページを内部で保持する。ページ枠・ページ番号は強調しない。

| キー | 操作 |
| --- | --- |
| H / ← | 前のページへ移動 |
| L / → | 次のページへ移動 |
| J / K | 中央ページを下／上へ約3行スクロール。端で停止。長押し可 |
| Space | 入力欄へ戻る。下書き・カーソル位置を保持。空白は入力しない |
| Esc | 本文フォーカスを維持。連打してもフルスクリーンを解除しない |

H・J・K・L・Space・Escは修飾キーなし。先頭・末尾で循環しない。入力欄では通常入力・カーソル移動となり、/はコマンド補完に使う。日本語変換中・ダイアログ表示中の本文操作は無効。Enter/Escの承認操作は維持する。HJKL長押し中もSpaceで入力欄、EscでBookへ切り替えられる。Bookで受けたキーのリピートは、切り替え後の入力欄へ流さない。

新しいやり取りは最新ページの上端を表示し、操作対象にする。生成中の追加入力は同じページに残る。回答更新だけでは読書中の過去ページへ割り込まない。各ページのスクロール位置は保持する。

実装：[AgentBookExchangeView.swift](../../whub/Features/AgentBook/View/Exchange/AgentBookExchangeView.swift)、[AgentBookInputView.swift](../../whub/Features/AgentBook/View/Controls/AgentBookInputView.swift)、[AgentBookTextView.swift](../../whub/Features/AgentBook/View/Exchange/Page/AgentBookTextView.swift)

## ファイル編集

エディタにフォーカスがあるとき有効。

| ショートカット | 操作 |
| --- | --- |
| ⌘S | 編集中のファイルを保存 |
| ⌘F | 検索欄を表示 |
| ⌘C / ⌘V / ⌘X | コピー / 貼り付け / 切り取り |
| ⌘A | 全選択 |
| ⌘Z | Undo |
| ⇧⌘Z | Redo |

保存対象はローカル・リモートの既存テキストファイル。

Editorの表示中は、⌘Dで選択中のファイルと差分を切り替える。Explorerでの名前入力中は無効。

実装：[EditorView.swift](../../whub/Features/Files/View/Editor/EditorView.swift)、[CodeEditorView.swift](../../whub/Features/Files/View/Editor/Text/CodeEditorView.swift)、[whubApp.swift](../../whub/whubApp.swift)。

## 左ナビゲーション

| ショートカット | 操作 |
| --- | --- |
| ⇧⌘D | 通常／Diff Explorerを切り替え（選択場所がない場合と名前入力中は無効） |
| ⇧⌘E | ExplorerとFeatureのフォーカスを往復（名前入力中は無効） |
| ⇧⌘R | Project / Worktree・ファイル一覧・Git状態を更新 |
| ⇧⌘K | 前のProject / Worktreeへ移動 |
| ⇧⌘J | 次のProject / Worktreeへ移動 |

実装：[whubApp.swift](../../whub/whubApp.swift)、[ExplorerPulldownView.swift](../../whub/Features/Files/View/Explorer/Menu/ExplorerPulldownView.swift)、[ExplorerView.swift](../../whub/Features/Files/View/Explorer/ExplorerView.swift)
