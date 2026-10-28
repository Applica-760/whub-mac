# HTTP API

接続は[SSH経由](../../architecture/remote-development.md)。JSON本文には`Content-Type: application/json`を指定する。エラー形式は`{"error":{"code":"...","message":"..."}}`。疎通確認は`GET /ping`で200・`pong`を返す。

## Files

| Method | Endpoint | 用途・入力 | 応答・注意 |
| --- | --- | --- | --- |
| GET | `/files/list` | 一覧取得。query：絶対パスの`root`、配下の相対`path`（省略時は空） | 200：`name`・`kind`の配列。最大8 MiB。rootは要求側が指定 |
| GET | `/files/read` | 本文取得。query：`root`・空でない`path` | 200：`text`。UTF-8・最大1 MiB。シンボリックリンクは辿らない |
| PUT | `/files/write` | 既存ファイル保存。query：`root`・`path`。body：`expectedText`・`text` | 200：保存後の`text`。本文はUTF-8・最大1 MiB。現状とexpectedTextのバイト不一致は409。通信断で保存結果が不明な場合は再読込で確認 |
| POST | `/files/create-file` | 空ファイル作成。query：`root`・`path` | 204：成功。既存の名前は409 |
| POST | `/files/create-directory` | ディレクトリ作成。query：`root`・`path` | 204：成功。既存の名前は409 |
| POST | `/files/rename` | 同じディレクトリ内で改名。query：`root`・`path`。JSON body：`name` | 204：成功。既存の名前は409 |
| POST | `/files/trash` | ゴミ箱へ移動。query：`root`・`path` | 204：成功。Linuxでは `gio trash` を使用し、利用不可の場合は失敗 |

## Agent

| Method | Endpoint | 用途・入力 | 応答・注意 |
| --- | --- | --- | --- |
| POST | `/agent/sessions` | Session作成。body：`kind`・絶対パスの`directory` | 201：概要とLocation |
| GET | `/agent/sessions` | Session一覧 | 200：概要の配列。会話本文は含まない |
| GET | `/agent/sessions/{sessionID}` | Session概要 | 200：ID・revision・実行状態など。会話本文は含まない |
| DELETE | `/agent/sessions/{sessionID}` | Session終了 | 204：実行を停止しSessionを削除。通信切断時には呼ばない |
| POST | `/agent/sessions/{sessionID}/commands` | 操作IDと操作内容。送信・追加送信・中断・承認／質問回答・モデル変更・履歴再開 | 202：操作結果。同じSessionで同じID・内容なら再実行しない。異なる内容は409。状態内のcommandsでaccepted／completed／failedを確認し、回答完了は会話の状態で判断 |
| POST | `/agent/sessions/{sessionID}/snapshots` | 初回取得・再同期用の状態を固定 | 201：snapshot ID・revision・byteCount |
| GET | `/agent/sessions/{sessionID}/snapshots/{snapshotID}` | 固定状態のページ取得。query：`cursor`（既定0） | 200：Base64のdata・nextCursorなど。全ページ結合後にJSONを復号し、画像は別途取得 |
| GET | `/agent/sessions/{sessionID}/changes` | 差分取得。query：`snapshot`・`after`（取得済みrevision）・`cursor`（既定0） | 200：差分ページ。全ページ結合後にJSONを復号し、差分を順に適用。最大5秒待ち、変化なしは204。410／resyncRequiredなら新しいsnapshotから再取得 |
| DELETE | `/agent/sessions/{sessionID}/snapshots/{snapshotID}` | 取得用データの解放 | 204：Sessionや実行は終了しない |
| GET | `/agent/sessions/{sessionID}/images/{imageID}` | 画像の分割取得。query：`cursor`（既定0） | 200：mediaType・byteCount・Base64のdata・nextCursorなど |
| GET | `/agent/sessions/{sessionID}/models` | モデル選択肢の取得 | 200：モデル一覧 |
| GET | `/agent/sessions/{sessionID}/skills` | Skill一覧の取得 | 200：Skill一覧 |
| GET | `/agent/sessions/{sessionID}/status` | Agentの設定・使用量などの取得 | 200：状態表示用コンテンツ |
| GET | `/agent/sessions/{sessionID}/history` | 会話履歴の取得。query：続きの`cursor` | 200：履歴とnextCursor |

## Manager

| Method | Endpoint | 用途・入力 | 応答・注意 |
| --- | --- | --- | --- |
| POST | `/manager/fetch` | devのリモート情報取得。body：`{}` | 202：操作情報とLocation。prodは受付不可。checkout・稼働版は変えない |
| GET | `/manager/commits` | 最新の成功したFetchで保存したコミット一覧 | 200：接続先環境のコミット一覧 |
| POST | `/manager/builds` | 成果物のビルド。body：devは完全なSHAの`commit`、prodは`{}` | 202：操作情報とLocation。devは追加fetchなし、prodはfetch後のorigin/main。稼働版は変えない |
| GET | `/manager/builds` | 利用可能なビルド成果物の取得 | 200：接続先環境の成功したBuild成果物 |
| POST | `/manager/apply` | 成果物の適用。body：`buildID` | 202：操作情報とLocation。同環境のBuild成果物のみ。再ビルドせず適用 |
| POST | `/manager/restart` | currentの再起動。body：`{}` | 202：操作情報とLocation。current・previousは変更しない |
| POST | `/manager/updates` | 取得・ビルド・適用の一括実行。body：devは`ref`必須、prodは省略または`refs/remotes/origin/main` | 202：操作情報とLocation |
| GET | `/manager/updates` | 操作履歴の取得 | 200：接続先環境の履歴 |
| GET | `/manager/updates/{id}` | 操作の進捗・結果取得 | 200：status・errorCodeなど。POSTの202は受付であり、完了はこのstatusで判断 |
| GET | `/manager/updates/{id}/log` | ログ取得。query：バイト位置の`offset`（既定0） | 200：最大1 MiBのtextとnextOffset |
| GET | `/manager/status` | 稼働版・配置先・更新状態の取得 | 200：running・current・previous・共通ロックなど。更新中はrunningとcurrentが異なる場合がある |

ManagerのPOST本文は4 KiB以下、応答は8 MiB以下。操作はdev／prod共通で同時に1件とし、実行中の追加要求は409。設定・更新・復旧の手順は[WhubServerのリリース](../../operations/server-releases.md)を参照。
