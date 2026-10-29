# WhubClient

WhubServerのHTTP APIをアプリから呼び出す。HTTPの詳細はClientに置き、画面・接続先の管理はアプリ側が担当する。Serverとの契約は [HTTP API一覧](../../../../docs/reference/api/README.md) を参照する。

## 構成と責務

| 配置 | 責務 |
| --- | --- |
| `WhubClient.swift` | 接続先URL、HTTPリクエスト、応答サイズ・ステータス・エラーの共通処理 |
| `API/Files/FilesAPI.swift` | Files APIの入力・応答とパスの検証 |
| `API/Git/GitAPI.swift` | Git APIの入力・応答と変更監視 |
| `API/Manager/ManagerAPI.swift` | Server管理APIの入力・応答 |
| `API/Agent/` | Agent APIの入力・応答と、取得したSession状態の同期 |

アプリは `client.files` や `client.git` を通して操作する。SSH接続とClientの生成はアプリ側の `RemoteServerStore` が担当する。

## APIの記法

- 機能別のAPIは `API/<機能>/<機能>API.swift` に置き、`WhubClient` を通して公開する。
- HTTP通信は共通の `request`／`response` を使う。単一の成功ステータスには `request`、複数の成功ステータスを区別する場合は `response` を使う。
- JSON応答のデコードには共通の `decode` を使う。入力・応答モデルと機能固有の検証は各APIに置き、戻り値はServerの契約と利用目的に合わせて決める。
- 通信エラーは共通の `WhubClientError` で扱う。Serverが返すエラーはステータス・コード・メッセージを保持する。

## 実装時の確認

- メソッド、パス、入力・応答、成功ステータスがServerの契約と一致しているか。
- HTTP通信や共通エラー処理をアプリ側に重複させていないか。
- 必要な入力検証と、JSONモデルまたはバイト列の変換を各APIに置いているか。
- 応答の8 MiB上限と、機能固有のタイムアウトや複数の成功ステータスを確認したか。
- Serverとの通信テストと [HTTP API一覧](../../../../docs/reference/api/README.md) を変更内容に合わせたか。

ClientはLinuxでもビルドする。SwiftDataなどApple OS固有のフレームワークに依存させない。
