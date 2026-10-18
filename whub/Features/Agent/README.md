# Agent

エージェントとの会話・接続・実行状態を管理する。[AgentBook](../AgentBook/README.md) が持つタブ・通知・ページ表示とは分ける。

## 構成と責務

主要な境界に関係するファイルを示す。`…` は省略部分。

```text
Agent/
├── README.md
├── Model/
│   ├── AgentModels.swift          // 入力・出力・実行状態・承認／質問の共通モデル
│   ├── AgentHistory.swift         // 履歴一覧・再開時の会話データ
│   └── AgentModelOption.swift     // エージェントに依存しないモデル選択肢
├── Store/
│   ├── AgentStore.swift           // 下書き・会話・接続／実行状態を保持し、Sessionを操作
│   │                              // AgentKind・AgentEvent・AgentSessionもここに定義
│   ├── AgentHistoryStore.swift    // 履歴一覧・追加取得カーソル・取得状態を保持
│   └── AgentSkillStore.swift      // スキル一覧・取得状態を保持
└── Codex/
    ├── CodexAgentClient.swift     // CLIプロセス・標準入出力・RPC応答待ちを管理
    ├── CodexAgentJSON.swift       // CodexのJSONを扱う補助処理
    ├── Model/                    // Codex固有の応答・実行・モデル情報
    │   └── …
    └── Store/
        ├── CodexAgentSession.swift
        │                          // thread／turn・保留要求を管理し、AgentSessionを実装
        ├── CodexAgentMapping.swift
        │                          // Codexの入出力・要求と、Agentの共通モデルを変換
        └── CodexAgentStatus.swift // Codexの設定・使用量などから状態表示用の内容を生成
```

## 同じSessionを共有し、接続の開始・終了はAgentStoreが担当する

`AgentBookTabStore` は、1つの `AgentSession` を `AgentStore`・`AgentHistoryStore`・`AgentSkillStore` に渡す。履歴・スキル用StoreはそのSessionで取得するだけで、別の接続を作らない。

`AgentStore` は生成時に `events` を購読し、`disconnect()` で購読とSessionを終了する。終了済みStoreを新しい会話に使い回さず、タブ側でStore一式を置き換える。

## 変更時に守る境界

- Codex固有のRPC名・JSON形式・差分イベントの処理は `Codex/` に置く。AgentBookへは共通モデルで渡す。`AgentKind.makeSession()` のClaude Codeは現状 `nil` で、通信実装はない。
- `AgentEvent.output` は、同じ出力IDの「最新内容全体」を渡す契約。AgentStoreはIDが一致する出力を置き換えるため、追記分だけを渡すと以前の内容が失われる。
- `conversationIDChanged` は実行の開始・完了と独立した通知。会話ID、個々の実行ID、出力ID、RPC要求IDを同じ識別子として扱わない。
- 承認・質問への回答は `AgentStore.respond` を通す。Viewで会話の要求状態を直接書き換えず、Sessionから返るイベントで確定させる。
- 会話の下書き・実行状態はAgentStore、タブの用途・完了通知はAgentBook側に置く。境界やイベント契約を変えたら、関連するREADMEも更新する。
