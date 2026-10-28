# WhubServerのリリース

`Services/Manager/`直下の5ファイルで更新を扱う。`ServerManager`は進行、`ServerSource`はGit操作、`ServerBuild`はコンパイル・成果物作成、`ServerReleases`は保管・dev／prod切り替え・再起動・旧版復元、`ServerOperationStore`は要求・状態・履歴・ログ・ロックの保存を担当する。Manager APIで受け付け、同じ実行ファイルの別プロセスで完遂する。常駐Serverのsystemd初回登録は別途行う。

初回は「呼び出す前の準備」「HTTPから更新する」、中断・失敗時は「履歴を確認する」「中断後は手動で復旧する」を読む。

## 呼び出す前の準備

Linux上のSwift・Git・systemd userサービスが必要。更新は対象Serverとは別のプロセス・サービスで実行する。同じサービスでは再起動時に更新処理も停止する。

- cleanなGit checkoutに`origin`を設定する。Buildはdetached checkoutへ切り替え、元ブランチには戻さない。更新中の編集は禁止。
- 保存先はcheckout外の絶対パスとし、dev／prodで共用する。同じcheckoutでBuildを並行実行しない。
- dev／prodのsystemd userサービスを事前登録する。`ExecStart`は各環境の`current/whub-server`の絶対パス。シェル・ラッパーを挟まず、Server自身をMainPIDにする。
- 待受は`127.0.0.1`か`::1`。他の`WHUB_SERVER_HOST`は起動拒否。`WHUB_SERVER_PORT`は環境別に分け、health URLは同じloopbackの`/ping`にする。Macは既存SSHのポート転送で接続する。
- systemdの起動・停止タイムアウトは有限値にする。更新は`systemd-run --user`で常駐Serverから独立した一時サービスとして起動する。ログアウト後・OS再起動後の常駐設定は後続作業。
- systemd 254以降を使う。起動引数の環境変数展開を無効にする`--expand-environment=no`を使用する（[systemdの公式文書](https://github.com/systemd/systemd/blob/v254/man/systemd-run.xml)）。

Files APIの閲覧ルートはMacが保持する。`/files/list`・`/files/read`の`root`は絶対パス、`path`は配下の相対パス（省略時は空）。`WHUB_SERVER_ROOT`は使わない。

## ゴミ箱からの復元

Linuxでは `gio trash --list` でゴミ箱内のURIを確認し、復元先の絶対パスを指定する。

```sh
gio move --no-target-directory 'trash:///対象のURI' '/元のディレクトリ/ファイル名'
```

`gio move` は復元先が存在すると上書きするため、実行前に復元先が存在しないことを確認する。対象環境では `gio trash --restore` が日本語を含む元パスを正しく復元できないことを確認した。

## Manager APIを有効にする

HTTP起動は`whub-server`。サービスに次の環境変数を設定する。Files／Manager APIは両方必須で、設定不足なら起動を拒否する。

| 環境変数 | 値 |
| --- | --- |
| `WHUB_SERVER_ENVIRONMENT` | `dev`または`prod`。更新先はこの環境に固定 |
| `WHUB_MANAGER_ROOT` | 共通の保存先の絶対パス。例：`/home/user/Developer/.whub/server` |
| `WHUB_MANAGER_SOURCE` | ビルド元Git checkoutの絶対パス |
| `WHUB_MANAGER_SWIFT` | Swift実行ファイルの絶対パス |
| `WHUB_MANAGER_SERVICE` | このServerを管理するsystemd userサービス名 |
| `WHUB_MANAGER_HEALTH_URL` | このServerの`/ping`へ直接接続するURL |

認証はSSHを使い、Manager APIのトークンは使わない。HTTPポートは外部公開しない。同じLinux内のプロセスからはアクセスできる。

移行時は`WHUB_SERVER_HOST=127.0.0.1`、health URLを`http://127.0.0.1:<port>/ping`にし、`WHUB_MANAGER_TOKEN`を削除する。MacのDev／Prod URLは`http://127.0.0.1:<port>`。これはMac自身ではなくSSH接続先Linuxのアドレスを指す。旧Serverはトークン認証が必要なため、新しい管理画面の利用前に更新する。

## HTTPから更新する

| メソッド・パス | 結果 |
| --- | --- |
| `POST /manager/fetch` | devのリモート情報を取得する。checkoutや稼働版は変えない |
| `GET /manager/commits` | この環境の最新の成功したFetchで保存したコミット一覧を返す |
| `POST /manager/builds` | ビルド成果物を保存する。稼働版は変えない |
| `GET /manager/builds` | この環境の成功したBuildのうち、利用可能な成果物を返す |
| `POST /manager/apply` | 選択済みのビルド成果物へ切り替える |
| `POST /manager/restart` | 現在のcurrentを再起動する |
| `POST /manager/updates` | 従来の取得・ビルド・適用を一括で実行する |
| `GET /manager/updates` | この環境の更新履歴を開始日時順に返す |
| `GET /manager/updates/<id>` | 更新1件の状態・結果・エラーを返す |
| `GET /manager/updates/<id>/log?offset=0` | 指定位置から最大1 MiBのログと`nextOffset`を返す |
| `GET /manager/status` | 稼働版、current・previous、同環境の更新情報と共通ロックの有無を返す |

POSTは202・操作ID・Location（`/manager/updates/<id>`）を返す。履歴・状態・ログは同じ操作IDで取得する。

POSTは`Content-Type: application/json`、本文4 KiB以下、値は文字列。表にないフィールド、任意の環境・パス・サービス名・コマンドは指定できない。

| 操作 | devの本文 | prodの本文 |
| --- | --- | --- |
| Fetch | `{}` | 受付不可。Build時に取得する |
| Build | `{"commit":"<完全なcommit SHA>"}` | `{}`。fetch後の最新`origin/main`を自動選択 |
| Apply | `{"buildID":"<build ID>"}` | `{"buildID":"<build ID>"}` |
| Restart | `{}` | `{}` |
| 従来の一括更新 | `{"ref":"refs/remotes/origin/feature/example"}`など | `{}`または`{"ref":"refs/remotes/origin/main"}` |

devはFetch → コミット選択 → Build → 成果物選択 → Apply。Buildは追加fetchせず、指定した完全なSHAを使う。prodはBuild → 成果物選択 → Apply。mainが進んでも選択済みの成果物を適用する。Apply対象は同じ環境で単独のBuildが成功した成果物のみ。一括更新は取得・ビルド・適用まで行う。

### HTTP処理の役割

`Routes.swift`はパスを`ManagerAPI.Action`へ対応づける。更新は`.start(ServerOperation)`、参照は履歴・ログ・状態などのActionを使う。

- `handle`：クエリ検証・Action振り分け・HTTPエラー変換。クエリはログの`offset`のみ。
- `acceptOperation`：許可フィールドを決め、要求を`ServerManager.start`へ渡す。202とLocationを返す。
- `readValidatedJSONFields`：Content-Type・本文サイズ・文字列値・許可フィールドを検証し、辞書を返す。必須値・環境制約・commit・成果物はServiceが検証する。
- `makeJSONResponse`：JSON化と日時のミリ秒表現、8 MiBの応答上限、Content-Type・no-storeを設定する。

Files APIはパス制約・書き込み条件が異なるため、Manager専用処理と共通化しない。`/ping`はプレーンテキストの`pong`を返す。

### 受付後の確認

更新はdev／prod共通で同時に1件。受付時に共通ロック・要求・`queued`状態を保存する。追加要求は409、不正入力は400、対象なし・別環境のIDは404、操作プロセスの起動未確認は503。受付後のビルド・起動確認の失敗は操作状態に記録する。エラー形式は`{"error":{"code":"...","message":"..."}}`。履歴・結果・ログは最大8 MiBで、超過時は413。

受付後はLocationを問い合わせる。切り替え時の接続断後も同じ更新IDを使う。202は受付であり完了ではない。応答を受信できなかった場合は、再要求の前に履歴を確認する。

ログは`text`・`nextOffset`を返す。次回は`offset=<nextOffset>`を指定する。offsetは元ログのバイト位置。末尾ではtextが空になる。UTF-8の途中で分割すると置換文字になる場合がある。

`status.running`は起動時に実行ファイル隣の`build.json`から読んだ版。メタデータがなければ省略する。`current`は配置先で、更新中は稼働版と異なる場合がある。`locked`はdev／prod共通。履歴・ログ・個別更新は接続先環境のみ返す。

## 同じ実行ファイルから更新プロセスを起動する

受付時に自身を`updates/<id>/runner`へコピーし、`systemd-run --user --collect --service-type=exec`で次を起動する。

```text
<root>/updates/<id>/runner update <root> <id>
```

`runner`は`whub-server`のコピー。引数なしでHTTP起動、`update <root> <id>`で保存済み要求を実行して終了する。コピー元が更新されても処理は継続する。完了時にrunnerを削除し、失敗時は非0で終了する。

一時サービス名は`whub-update-<id>.service`。起動要求の出力はbuild.log、更新プロセスの標準出力・標準エラーはjournaldへ記録する。確認は`journalctl --user -u whub-update-<id>.service`。SSH agent・Swiftに必要な環境変数だけを明示的に引き継ぐ。Git認証はsystemdからも使えるようにする。

起動要求が失敗しても、プロセスが始まっている可能性があるためロックは残す。履歴・サービス状態を確認し、後述の手順で手動復旧する。

## 成果物と環境の参照を分けて保存する

```text
<root>/
├── releases/<build-id>/
│   ├── whub-server
│   ├── build.json
│   └── … resources / bundle
├── environments/
│   ├── dev/
│   │   ├── current  → <root>/releases/<build-id>
│   │   └── previous → <root>/releases/<old-build-id>
│   └── prod/
│       ├── current  → <root>/releases/<build-id>
│       └── previous → <root>/releases/<old-build-id>
├── updates/<update-id>/
│   ├── state.json
│   ├── request.json             # Server設定・操作種別・ref・build ID
│   ├── commits.json             # Fetch成功時のコミット一覧
│   ├── runner                   # 更新中だけ保持する実行ファイルのコピー
│   └── build.log
└── update.lock/                 # 更新IDとworkerの実行予約。中断時は残る
```

Buildは`updates/<update-id>/artifact`へ出力し、成功時に`releases/<build-id>`へ移す。失敗時は現行Serverを維持する。配置済み成果物は上書き・自動削除しない。

Apply時、または一括更新のビルド成功後、旧`current`を`previous`に記録する。`current`のリンクをatomicに置換し、`systemctl --user restart`を実行する。MainPIDの`/proc/<pid>/exe`と対象実行ファイルを照合し、`/ping`のHTTP 200・`pong`を確認する。約1秒間隔で最大30回試行する。HTTP待機・systemd処理の時間は別途かかる。

同じ成果物へのApplyは再起動せず、previousも変更しない。Restartはcurrent・previousを変更せず再起動・起動確認を行う。

切り替え後の失敗時は旧`current`へ戻し、旧Serverを再起動・確認する。旧版がない初回導入では`current`を除き、サービスを停止する。新成果物は調査用に残す。

## 履歴を確認する

`try manager.history()`は保存済み履歴を開始日時順に返す。dev／prodは`environment`で区別する。`state.json`の項目は次のとおり。日時はUnix時刻のミリ秒。

| フィールド | 意味 |
| --- | --- |
| `previousBuild` | 更新前のcurrentが指していたbuild ID |
| `targetBuild` | 今回配置したbuild ID。ビルド失敗時はなし |
| `activeBuild` | 処理の結果、稼働を確認できたbuild ID。更新前の値は既存currentから引き継ぐ。切り替え中や復旧失敗時は不明 |
| `status` | 下表の処理状態 |
| `error`・`errorCode` | 失敗理由と識別用コード。復旧も失敗した場合は両方の理由を記録 |
| `operation` | `update`・`fetch`・`build`・`apply`・`restart`。旧記録で省略されている場合は`update`として扱う |
| `ref` | ビルドに指定したrefまたはcommit SHA。Fetch・Apply・Restartでは空文字列 |
| `commit` | Buildで確定した、またはApplyで選択した成果物のcommit SHA |

| status | 意味 |
| --- | --- |
| `queued` | 受付済み。更新プロセスの実行待ち |
| `launch_failed` | 更新プロセスの起動を確認できなかった。ロックは要確認 |
| `fetching` | Fetchによるリモート情報の取得中 |
| `building` | ビルド中。prodの取得も含む |
| `switching` | 成果物を保管済み。切り替え・起動確認中 |
| `restarting` | 現在のcurrentを再起動・起動確認中 |
| `rolling_back` | 旧版への復元処理中 |
| `succeeded` | 指定操作が成功。Build単独では成果物の保存までで、稼働版は変わらない |
| `failed` | 更新失敗。切り替え前なら現行維持、初回導入の切り替え後なら停止済み |
| `rolled_back` | 更新失敗後、旧版の起動確認が成功 |
| `recovery_failed` | 更新も復旧も失敗。実際の稼働状態は要確認 |

ビルド・切り替えの失敗は履歴に残る。HTTP 200は状態取得の成功。更新結果は本文の`status`・`errorCode`で判断する。

## 中断後は手動で復旧する

異常終了・OS再起動後は自動再開しない。`update.lock`が残り、次の更新を拒否する。更新プロセスの停止を確認するまでロックを削除しない。

1. `updates`の最新`state.json`と`build.log`、対象サービスの`systemctl --user status`・`journalctl --user -u <service>`を確認する。
2. `current`・`previous`のリンク先とMainPIDの実行ファイルを確認する。必要なら検証済みの旧成果物へ`current`を戻し、再起動後に`/ping`を確認する。初回導入で使える成果物がなければ停止する。
3. 復旧結果を別途記録する。保存済み履歴は自動修正されない。ビルド中断時は`updates/<id>`に作業中の成果物が残る場合がある。
4. プロセス停止と環境の状態を確認する。`<root>/update.lock/worker`があれば空を確認し、`rmdir`で削除する。次に`update.lock/id`だけを削除し、空の`update.lock`を`rmdir`で削除する。これで次の更新を実行できる。

MacではHTTPルート・受付・保存済み要求の別プロセス実行を検証する。systemd起動・実サービスの確認は差し替える。Linuxの実systemdによる切り替え・復旧、ログアウト・OS再起動後の常駐は未検証。不明点と常駐設定は[Issue #90](https://github.com/Applica-760/whub-mac/issues/90)で管理する。
