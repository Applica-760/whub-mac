## 機能要件

### 選択とフォーカス

#### TAB-F-001：Cmd＋数字でタブを選択する
- 前提：対象Featureがアクティブで、指定番号のタブがある
- 操作：Cmd＋1〜9のいずれかを押す
- 期待結果：表示順で該当する番号のタブが選択される
- 対応テスト：`whubTests/Features/Files/View/EditorViewTests.swift / EditorViewTests.tabShortcutsPreserveEditorStateAndCloseSelectedTabs()`、`whubTests/Features/Terminal/View/TerminalViewTests.swift / TerminalViewTests.numberKeysSwitchTerminalFocusAndRetainSessions()`、`whubTests/Features/Browser/View/BrowserViewTests.swift / BrowserViewTests.numberKeysSelectBrowserTabsInDisplayOrder()`、`whubTests/Features/AgentBook/View/AgentBookViewTests.swift / AgentBookViewTests.numberShortcutsSwitchInputAndRetainAgentSessions()`（各FeatureのCmd＋1〜9と表示順に対応する選択を検証。AgentBookは実際のメニュー内容Viewへキーイベントを送り、アプリ全体のメニューバーへの接続は含めない）

#### TAB-F-002：FileEditorの切替先へ入力フォーカスを移す
- 前提：複数のFileEditorタブがあり、切替先に編集可能な本文がある
- 操作：別のタブを選択する
- 期待結果：切替先の本文に入力フォーカスが移り、そのカーソル位置から編集できる
- 対応テスト：`whubTests/Features/Files/View/EditorViewTests.swift / EditorViewTests.tabShortcutsPreserveEditorStateAndCloseSelectedTabs()`（同一FileEditor内のタブをキー操作で切り替え、切替先の入力フォーカス・カーソル位置・文字入力を検証）

#### TAB-F-003：Terminalの切替先へ入力フォーカスを移す
- 前提：複数のTerminalタブがある
- 操作：別のタブを選択する
- 期待結果：切替先のTerminalへ入力フォーカスが移り、文字を入力できる
- 対応テスト：`whubTests/Features/Terminal/View/TerminalViewTests.swift / TerminalViewTests.numberKeysSwitchTerminalFocusAndRetainSessions()`（同一Terminal内でタブを切り替え、切替先の入力フォーカスと文字入力を検証。子プロセスを起動しないTerminalを使用）

#### TAB-F-004：Browserの切替先でJKスクロールを使えるようにする
- 前提：複数のBrowserタブがあり、切替先にスクロール可能なWebページがある
- 操作：別のタブを選択する
- 期待結果：切替先のWebコンテンツへフォーカスが移り、クリックせずにJ・Kでスクロールできる
- 対応テスト：`whubTests/Features/Browser/View/BrowserViewTests.swift / BrowserViewTests.switchingBrowserTabsRestoresFocusScrollAndPageState()`（ローカルHTMLを表示する2タブ間で切り替え、WebコンテンツへのフォーカスとクリックなしのJ・Kによるスクロールを検証）

#### TAB-F-005：AgentBookの切替先の入力欄へフォーカスを移す
- 前提：複数のAgentBookタブがある
- 操作：別のタブを選択する
- 期待結果：切替先の入力欄へフォーカスが移り、文字を入力できる
- 対応テスト：`whubTests/Features/AgentBook/View/AgentBookViewTests.swift / AgentBookViewTests.numberShortcutsSwitchInputAndRetainAgentSessions()`（切替先の入力欄へのフォーカスと文字入力を検証。接続はテスト用Adapter）

### 非表示タブの保持

#### TAB-F-006：タブを切り替えても既存の状態を保持する
- 前提：対象Featureのタブに表示内容・入力内容・セッション等の状態がある
- 操作：別のタブを選択して元のタブを非表示にし、その後戻る
- 期待結果：非表示中も状態を保持し、戻るとその状態を引き続き利用できる。切替だけを理由にViewやセッションを作り直したり、既存内容を読み込み直したりしない
- 対応テスト：`whubTests/Components/RetainedPageContainerTests.swift / RetainedPageContainerTests.sessionViewsSurviveSwitchesAndClosedTabsAreRemoved()`、`whubTests/Features/Files/View/EditorViewTests.swift / EditorViewTests.tabShortcutsPreserveEditorStateAndCloseSelectedTabs()`、`whubTests/Features/Terminal/View/TerminalViewTests.swift / TerminalViewTests.numberKeysSwitchTerminalFocusAndRetainSessions()`、`whubTests/Features/Browser/View/BrowserViewTests.swift / BrowserViewTests.switchingBrowserTabsRestoresFocusScrollAndPageState()`、`whubTests/Features/AgentBook/View/AgentBookViewTests.swift / AgentBookViewTests.numberShortcutsSwitchInputAndRetainAgentSessions()`（共通部品のView・入力・カーソル保持に加え、FileEditorの同じ文書・入力Viewと未保存編集、Terminalの同じセッション・View・出力、Browserの同じWebView・DOM入力・スクロール位置、AgentBookの同じタブ・入力View・下書き・接続回数を検証。実シェルと外部Agentサービスの接続は含まない）

「いちいち再描画しない」は、この再利用を指す。状態変化に必要な描画更新は許容する。

### CmdWで閉じる

#### TAB-F-007：複数あるタブから選択中のタブを閉じる
- 前提：対象Featureにタブが2枚以上あり、そのうち1枚を選択している
- 操作：CmdWを押す
- 期待結果：選択中のタブが閉じ、残ったタブが選択される。他のタブの状態は保持する
- 対応テスト：`whubTests/Features/Files/View/EditorViewTests.swift / EditorViewTests.tabShortcutsPreserveEditorStateAndCloseSelectedTabs()`、`whubTests/Features/Browser/View/BrowserViewTests.swift / BrowserViewTests.commandWClosesSelectedBrowserTabAndReplacesLast()`、`whubTests/Features/Terminal/View/TerminalViewTests.swift / TerminalViewTests.commandWClosesSelectedTerminalTabAndFocusesReplacement()`、`whubTests/Features/AgentBook/View/AgentBookViewTests.swift / AgentBookViewTests.commandWConfirmsCloseAndFocusesRemainingAgentTab()`（各FeatureでCmdWによる選択中タブの除去、残ったタブの選択と状態保持を検証。AgentBookでは既存の確認ダイアログを承認する。FileEditorは閉じる対象に未保存変更がない場合）

#### TAB-F-008：FileEditorの最後のタブを閉じる
- 前提：FileEditorタブが1枚ある
- 操作：CmdWを押す
- 期待結果：そのタブが閉じ、FileEditorのタブが0枚になる
- 対応テスト：`whubTests/Features/Files/View/EditorViewTests.swift / EditorViewTests.tabShortcutsPreserveEditorStateAndCloseSelectedTabs()`、`whubTests/Features/Files/Store/EditorStoreTests.swift / EditorStoreTests.localEditingAndTabs()`（ViewのCmdWとStoreのcloseそれぞれで最後のタブが0枚になることを検証。保存済みファイルを使用し、未保存変更の確認ダイアログは含まない）

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
- 対応テスト：`whubTests/Features/AgentBook/View/AgentBookViewTests.swift / AgentBookViewTests.commandWConfirmsCloseAndFocusesRemainingAgentTab()`、`whubTests/Features/AgentBook/Store/AgentBookStoreTests.swift / AgentBookStoreTests.newConversationReplacesOnlyItsOwnStateAndLastTabRemains()`（CmdW後の既存確認ダイアログを承認し、新規会話1枚への置換・入力欄フォーカス・文字入力を検証。Store単独でも最後のタブの置換を検証。接続はテスト用Adapter）

## 非機能要件

現時点で独立した要件は定義していない。

## 設計上の保証

TAB-F-006には、状態保持を実現するためのView・セッションの再利用も含む。詳細と対応テストは同項目を参照。
