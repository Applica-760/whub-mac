# WhubServer

WhubServerのAPIを実装・変更するときは、HTTP通信と実際の処理を分ける。APIの入力・応答の契約は [HTTP API一覧](../../../../docs/reference/api/README.md) を参照する。

## APIとServiceの責務

| 配置 | 責務 |
| --- | --- |
| `API/Routes.swift` | HTTPメソッド・パスをAPIの処理に対応づける |
| `API/<機能>/<機能>API.swift` | リクエストの解析・検証、処理の呼び出し、成功レスポンスの作成 |
| `API/<機能>/<機能>APIError.swift` | APIのエラーとHTTPステータス・エラーレスポンスの対応 |
| `Services/<機能>/` | APIから呼び出されるファイル操作やGit情報の取得などの処理 |

各機能のAPI層は、API本体とError型の2ファイルを基本とする。APIはHTTPの入力・出力を扱い、実際の処理はServiceなどの実行側に置く。ServiceのエラーはAPI層でHTTPレスポンスに変換する。

Filesは `FilesAPI` から `FilesService` を呼び、`FilesError` を `FilesAPIError` に変換する。Gitは `GitService` と監視処理を使い、Managerは `ServerManager` を使う。Agentは `Services/` を介さず、WhubAgentの `AgentRuntime` を呼ぶ。

既存のAgent APIでは、`AgentError` のステータスを `AgentAPIError` で決め、レスポンスの生成は `AgentAPI` で行う。

## ルーターの記法

`Routes.swift` では、エンドポイントを `git`・`files`・`manager`・`agent` のように機能ごとにまとめ、各グループの先頭に `// Files API` のようなコメントを置く。ルートにはメソッドとパスを記載し、処理は各APIに渡す。

## プラットフォームの依存

WhubServerはLinuxで動作するため、SwiftDataなどApple OS固有のフレームワークに依存させない。依存先を追加・変更するときも、Linuxで利用できることを確認する。

## 実装時の確認

- HTTPの解析・検証やレスポンスの作成をAPI層に置いているか。
- ファイル操作などの実際の処理をServiceや既存の実行側に置き、HTTP型に依存させていないか。
- エラーの種類、HTTPステータス、コード、メッセージをAPI層で対応づけているか。
- ルートを機能ごとにまとめ、グループをコメントで区切っているか。
- Apple OS固有のフレームワークに依存していないか。
- ルート、入力・応答の形式、サイズ上限、[WhubClient](../WhubClient) の呼び出しが一致しているか。
- 契約を変更した場合、HTTP API一覧と [WhubServerTests](../../Tests/WhubServerTests) を更新しているか。

## 関連文書

- [MacとLinuxの責務](../../../../docs/architecture/remote-development.md)
- [Serverの設定・更新・復旧](../../../../docs/operations/server-releases.md)
