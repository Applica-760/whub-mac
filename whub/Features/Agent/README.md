# Agent

GUI側の会話・下書き・接続状態を管理する。実行は[WhubPackage](../../../Packages/WhubPackage/README.md)のWhubAgent、タブ・通知・ページ表示は[AgentBook](../AgentBook/README.md)が担当する。

## 構成と責務

| ファイル | 責務 |
| --- | --- |
| `Store/AgentStore.swift` | 下書き・会話表示・接続状態、操作の送信と状態取得 |
| `Store/AgentExecutionTarget.swift` | LocalのRuntime呼び出しと、RemoteのHTTP通信の切り替え |
| `Store/AgentHistoryStore.swift` | 履歴一覧・追加取得カーソル・取得状態 |
| `Store/AgentSkillStore.swift` | スキル一覧・取得状態 |
| `Model/AgentModels.swift`・`AgentModelMapping.swift` | GUI用モデルとWhubAgent共通モデルの変換 |

## 接続と状態取得

`AgentBookTabStore`はAgentStoreを作り、History／Skill Storeへ渡す。補助StoreはAgentStore経由で取得し、接続を別に作らない。

AgentStoreは接続時の状態を取得し、revisionに基づいて更新を反映する。実行先のRuntimeがSessionを所有し、Codex固有の通信はWhubAgent内で扱う。

`disconnect()`は状態取得を停止する。LocalはSessionも終了し、Remoteは取得用データだけを解放して実行を継続する。終了済みStoreは使い回さない。

## 変更時に守る境界

- Viewからの操作・承認／質問回答はAgentStoreを通し、結果は共通状態から反映する。
- AppKit画像やローカルコマンドの表示はGUI側、Agent固有のRPC・実行処理はWhubAgent側に置く。
- 会話ID・Session ID・操作ID・出力IDを混同しない。操作完了と回答完了も分けて判断する。
- タブの用途・完了通知はAgentBook側に置く。境界を変えたら関連READMEも更新する。

通信・寿命は[MacとLinuxの責務](../../../docs/architecture/remote-development.md)、HTTPの契約は[API一覧](../../../docs/reference/api/README.md)を参照する。
