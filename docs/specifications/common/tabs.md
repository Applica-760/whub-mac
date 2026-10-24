## 機能要件

### 選択とフォーカス

#### TAB-F-001：Cmd＋数字でタブを選択する
- 前提：対象Featureがアクティブで、指定番号のタブがある
- 操作：Cmd＋1〜9のいずれかを押す
- 期待結果：表示順で該当する番号のタブが選択される
- 対応テスト：未照合

#### TAB-F-002：FileEditorの切替先へ入力フォーカスを移す
- 前提：複数のFileEditorタブがあり、切替先に編集可能な本文がある
- 操作：別のタブを選択する
- 期待結果：切替先の本文に入力フォーカスが移り、そのカーソル位置から編集できる
- 対応テスト：未照合

#### TAB-F-003：Terminalの切替先へ入力フォーカスを移す
- 前提：複数のTerminalタブがある
- 操作：別のタブを選択する
- 期待結果：切替先のTerminalへ入力フォーカスが移り、文字を入力できる
- 対応テスト：未照合

#### TAB-F-004：Browserの切替先でJKスクロールを使えるようにする
- 前提：複数のBrowserタブがあり、切替先にスクロール可能なWebページがある
- 操作：別のタブを選択する
- 期待結果：切替先のWebコンテンツへフォーカスが移り、クリックせずにJ・Kでスクロールできる
- 対応テスト：未照合

#### TAB-F-005：AgentBookの切替先の入力欄へフォーカスを移す
- 前提：複数のAgentBookタブがある
- 操作：別のタブを選択する
- 期待結果：切替先の入力欄へフォーカスが移り、文字を入力できる
- 対応テスト：未照合

### 非表示タブの保持

#### TAB-F-006：タブを切り替えても既存の状態を保持する
- 前提：対象Featureのタブに表示内容・入力内容・セッション等の状態がある
- 操作：別のタブを選択して元のタブを非表示にし、その後戻る
- 期待結果：非表示中も状態を保持し、戻るとその状態を引き続き利用できる。切替だけを理由にViewやセッションを作り直したり、既存内容を読み込み直したりしない
- 対応テスト：`whubTests/Components/RetainedPageContainerTests.swift / RetainedPageContainerTests.sessionViewsSurviveSwitchesAndClosedTabsAreRemoved()`（部分対応：共通部品のView・入力・カーソル保持。各Featureの実セッション・再読込は未検証）

「いちいち再描画しない」は、この再利用を指す。状態変化に必要な描画更新は許容する。

### CmdWで閉じる

#### TAB-F-007：複数あるタブから選択中のタブを閉じる
- 前提：対象Featureにタブが2枚以上あり、そのうち1枚を選択している
- 操作：CmdWを押す
- 期待結果：選択中のタブが閉じ、残ったタブが選択される。他のタブの状態は保持する
- 対応テスト：`whubTests/Features/Browser/View/BrowserViewTests.swift / BrowserViewTests.commandWClosesSelectedBrowserTabAndReplacesLast()`、`whubTests/Features/Terminal/View/TerminalViewTests.swift / TerminalViewTests.commandWClosesSelectedTerminalTabAndFocusesReplacement()`（部分対応：2枚のBrowser／TerminalでCmdWを送信し、選択中タブの除去と残ったタブの選択・状態保持を検証。FileEditor／AgentBookは未照合）

#### TAB-F-008：FileEditorの最後のタブを閉じる
- 前提：FileEditorタブが1枚ある
- 操作：CmdWを押す
- 期待結果：そのタブが閉じ、FileEditorのタブが0枚になる
- 対応テスト：未照合

#### TAB-F-009：Browserの最後のタブを新規タブに置き換える
- 前提：Browserタブが1枚ある
- 操作：CmdWを押す
- 期待結果：元のタブが閉じ、新しいBrowserタブ1枚に置き換わる。新規タブが選択される
- 対応テスト：`whubTests/Features/Browser/View/BrowserViewTests.swift / BrowserViewTests.commandWClosesSelectedBrowserTabAndReplacesLast()`（表示ViewへCmdWを送信し、元のタブの除去、異なるID・WebPageを持つ新規タブ1枚への置換と選択を検証。実画面の目視確認は含まない）

#### TAB-F-010：Terminalの最後のタブを新規タブに置き換える
- 前提：Terminalタブが1枚ある
- 操作：CmdWを押す
- 期待結果：元のタブが閉じ、新しいTerminalセッションのタブ1枚に置き換わる。新規タブへ入力フォーカスが移る
- 対応テスト：`whubTests/Features/Terminal/View/TerminalViewTests.swift / TerminalViewTests.commandWClosesSelectedTerminalTabAndFocusesReplacement()`（表示ViewへCmdWを送信し、元のタブの除去、新しいセッション・Terminal Viewを持つ1枚への置換、入力フォーカスと文字入力を検証。テストでは子プロセスを起動しないTerminalを注入するため、実シェルの起動・終了と実行中コマンドの終了確認ダイアログは未検証）

#### TAB-F-011：AgentBookの最後のタブを新規タブに置き換える
- 前提：AgentBookタブが1枚ある
- 操作：CmdWを押す
- 期待結果：元のタブが閉じ、新しい会話のタブ1枚に置き換わる。新規タブの入力欄へフォーカスが移る
- 対応テスト：未照合

## 非機能要件

現時点で独立した要件は定義していない。

## 設計上の保証

TAB-F-006には、状態保持を実現するためのView・セッションの再利用も含む。詳細と対応テストは同項目を参照。
