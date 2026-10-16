# WhubServerのリリース

`WhubServer`内の`Services/Manager/Releases/ServerReleases`が、ビルドからdev／prodの切り替え、失敗時の旧版復元までを実行する。HTTPのManager APIが更新を受け付け、同じ実行ファイルを別プロセスで起動して更新を完遂する。常駐Serverのsystemd初回登録は別途必要。

初めて接続するときは「呼び出す前の準備」と「HTTPから更新する」を読む。中断や失敗が起きた場合は「履歴を確認する」「中断後は手動で復旧する」を参照する。

## 呼び出す前の準備

Linux上でSwift・Git・systemd userサービスを使えることが前提。リリース処理は対象Serverのプロセス外で実行する。同じサービス内から呼ぶと、再起動時に更新処理も停止する。

- ソースはcleanなGit checkoutとし、`origin`を設定する。Buildはdetached checkoutへ切り替え、元ブランチには戻さない。更新中はソースを編集しない。
- 保存先はソースcheckoutの外に置き、dev／prodの全更新で同じ絶対パスを使う。同じcheckoutを使う別のBuildも並行実行しない。
- dev／prodそれぞれのsystemd userサービスを事前に登録し、`ExecStart`に各環境の`current/whub-server`の絶対パスを指定する。シェルやラッパーを介さず、Server自身をMainPIDとして管理する。
- サービスごとに`WHUB_SERVER_HOST`・`WHUB_SERVER_PORT`を設定する。ポートは環境間で分ける。渡すhealth URLは、そのサービスの`/ping`を直接指す。
- systemdの起動・停止タイムアウトは有限値にする。更新プロセスは`systemd-run --user`で独立した一時サービスとして起動する。常駐Serverと同じサービスには属さない。ログアウト後・OS再起動後の常駐設定は後続作業。
- systemd 254以降を使う。起動引数の環境変数展開を無効にする`--expand-environment=no`を使用する（[systemdの公式文書](https://github.com/systemd/systemd/blob/v254/man/systemd-run.xml)）。

Files APIの閲覧ルートはMacが保持し、`/files/list`・`/files/read`の`root`クエリに絶対パスを渡す。`path`はその配下の相対パス（省略時は空）。`WHUB_SERVER_ROOT`は使用しない。

## Manager APIを有効にする

通常のHTTP起動は`whub-server`のまま。次の環境変数をServerのサービスへ設定する。Files APIとManager APIは両方とも必須。必要な設定が未指定・不完全な場合や短いトークンの場合は起動を拒否する。

| 環境変数 | 値 |
| --- | --- |
| `WHUB_SERVER_ENVIRONMENT` | `dev`または`prod`。更新先はこの環境に固定 |
| `WHUB_MANAGER_ROOT` | 共通の保存先の絶対パス。例：`/home/user/Developer/.whub/server` |
| `WHUB_MANAGER_SOURCE` | ビルド元Git checkoutの絶対パス |
| `WHUB_MANAGER_SWIFT` | Swift実行ファイルの絶対パス |
| `WHUB_MANAGER_SERVICE` | このServerを管理するsystemd userサービス名 |
| `WHUB_MANAGER_HEALTH_URL` | このServerの`/ping`へ直接接続するURL |
| `WHUB_MANAGER_TOKEN` | 空白を含まない32文字以上のASCIIトークン。環境ごとに別の値を使う |

トークンはManager APIの全操作で`Authorization: Bearer <token>`として送る。トークンをソースや更新要求ファイルへ保存しない。環境変数を設定したServerが現在の環境とサービス・ポートを正しく指していることを確認する。

## HTTPから更新する

| メソッド・パス | 結果 |
| --- | --- |
| `POST /manager/updates` | 更新を受け付け、202と更新ID・Locationを返す |
| `GET /manager/updates` | この環境の更新履歴を開始日時順に返す |
| `GET /manager/updates/<id>` | 更新1件の状態・結果・エラーを返す |
| `GET /manager/updates/<id>/log?offset=0` | 指定位置から最大1 MiBのログと`nextOffset`を返す |
| `GET /manager/status` | 稼働版、current・previous、同環境の更新情報と共通ロックの有無を返す |

POSTは`Content-Type: application/json`、本文は4 KiB以下とする。devでは`{"ref":"refs/remotes/origin/feature/example"}`のようにrefを指定する。prodでは`{}`を送り、必ずfetchした`refs/remotes/origin/main`のcommitをビルドする。ref以外のフィールド、任意の環境・パス・サービス名・コマンドは受け付けない。

更新はdev／prodを含めて一度に1件だけ実行する。受付時に共通ロックを確保し、要求と`queued`状態を保存する。更新中の追加要求は待たせず409で拒否する。認証失敗は401、不正入力は400、対象なし・別環境の更新IDは404、起動確認の失敗は503を返す。エラー本文は`{"error":{"code":"...","message":"..."}}`形式。履歴・結果・ログの応答は最大8 MiBで、超過時は413を返す。

受付後はLocationのURLを問い合わせる。Server切り替え時は短い接続断が発生するため、再接続後も同じ更新IDを使う。202は受付を意味し、更新完了を意味しない。応答を受信できなかった場合は、再要求する前に履歴を確認する。

ログは`text`と`nextOffset`を返す。次回は`offset=<nextOffset>`を指定する。offsetは元ログのバイト位置であり、末尾に達した場合は空のtextを返す。UTF-8の途中で分割された文字は置換文字になる場合がある。

`status.running`はプロセス起動時に実行ファイルの隣の`build.json`から読み取った版を返す。開発ビルドなどでメタデータがない場合は値を省略する。`current`は配置先の参照であり、更新途中は稼働版と異なる場合がある。`locked`はdev／prod共通の更新制限を示すが、履歴・ログ・個別の更新情報は接続先の環境だけを返す。

## 同じ実行ファイルから更新プロセスを起動する

受付処理は自身の実行ファイルを`updates/<id>/runner`へコピーしてから、`systemd-run --user --collect --service-type=exec`で次の処理を起動する。

```text
<root>/updates/<id>/runner update <root> <id>
```

`runner`は別の専用ツールではなく、`whub-server`と同じ実行ファイルのコピー。引数なしならHTTPを起動し、`update <root> <id>`なら保存された要求を読み、更新して終了する。コピーにより、ビルド元の実行ファイルが更新されても実行中の更新処理は影響を受けない。完了時にrunnerを削除する。処理失敗時は終了コードも非0になる。

更新用一時サービスの名前は`whub-update-<id>.service`。systemdへの起動要求の出力はbuild.logへ、更新プロセス自身の標準出力・標準エラーはjournaldへ出る。`journalctl --user -u whub-update-<id>.service`で確認する。SSH agentとSwift実行に必要な環境変数だけを起動元から明示的に引き継ぐ。Git認証はsystemd実行時にも利用できる形で用意する。

起動要求が失敗した場合、すでにプロセスが開始している可能性を除外できないためロックを保持する。履歴とサービスの状態を確認し、後述の手動復旧を行う。

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
│   ├── request.json             # Server設定とref。トークンは含めない
│   ├── runner                   # 更新中だけ保持する実行ファイルのコピー
│   └── build.log
└── update.lock/                 # 更新IDとworkerの実行予約。中断時は残る
```

Buildの出力先には`updates/<update-id>/artifact`を渡し、成功した成果物を`releases/<build-id>`へ移す。ビルド失敗時は現行Serverを維持する。配置済みの成果物は上書き・自動削除しない。

ビルド成功後、旧`current`を`previous`へ記録し、`current`のシンボリックリンクをatomicに置き換える。その後に`systemctl --user restart`を実行する。起動確認ではMainPIDの`/proc/<pid>/exe`と対象実行ファイルを照合し、`/ping`がHTTP 200と`pong`を返すことを確認する。約1秒間隔で最大30回試行する。HTTP待機時間とsystemdの処理時間は別にかかる。

切り替え後に失敗した場合は旧`current`へ戻し、旧Serverを再起動・確認する。初回導入では旧版がないため、`current`を取り除いて対象サービスを停止する。失敗した新成果物も調査用に残す。

## 履歴を確認する

`try releases.history()`で保存済みの更新履歴を開始日時順に取得する。dev／prodは各記録の`environment`で区別する。`state.json`には次の情報を保存する。日時はUnix時刻のミリ秒。

| フィールド | 意味 |
| --- | --- |
| `previousBuild` | 更新前のcurrentが指していたbuild ID |
| `targetBuild` | 今回配置したbuild ID。ビルド失敗時はなし |
| `activeBuild` | 処理の結果、稼働を確認できたbuild ID。更新前の値は既存currentから引き継ぐ。切り替え中や復旧失敗時は不明 |
| `status` | 下表の処理状態 |
| `error`・`errorCode` | 失敗理由と識別用コード。復旧も失敗した場合は両方の理由を記録 |
| `ref` | ビルドに指定したref。commitは各成果物の`build.json`で確認 |

| status | 意味 |
| --- | --- |
| `queued` | 受付済み。更新プロセスの実行待ち |
| `launch_failed` | 更新プロセスの起動を確認できなかった。ロックは要確認 |
| `building` | ビルド中 |
| `switching` | 成果物を保管済み。切り替え・起動確認中 |
| `rolling_back` | 旧版への復元処理中 |
| `succeeded` | 新版の起動確認が成功 |
| `failed` | 更新失敗。切り替え前なら現行維持、初回導入の切り替え後なら停止済み |
| `rolled_back` | 更新失敗後、旧版の起動確認が成功 |
| `recovery_failed` | 更新も復旧も失敗。実際の稼働状態は要確認 |

ビルド・切り替えの失敗は履歴へ保存する。APIのHTTP 200は状態取得の成功を表すので、本文の`status`と`errorCode`で更新結果を判定する。

## 中断後は手動で復旧する

異常終了やOS再起動の後は自動再開しない。`update.lock`が残り、次の更新を拒否する。稼働中の更新プロセスが存在しないことを確認するまでロックを取り除かない。

1. `updates`の最新`state.json`と`build.log`、対象サービスの`systemctl --user status`・`journalctl --user -u <service>`を確認する。
2. `current`と`previous`のリンク先、MainPIDの実行ファイルを確認する。必要なら検証済みの旧成果物へ`current`を戻し、対象サービスを再起動して`/ping`を確認する。初回導入で使える成果物がなければサービスを停止する。
3. 実際の復旧結果を別途記録する。保存済み履歴は自動で修正されない。ビルド中に中断した場合、`updates/<id>`内に作業中の成果物が残る場合もある。
4. 更新プロセスが停止し、環境の状態を確認できたら、`<root>/update.lock/worker`があれば空であることを確認して`rmdir`で取り除く。続けて`update.lock/id`だけを削除し、最後に空の`update.lock`を`rmdir`で取り除く。以降、新しい更新を実行できる。

MacではHTTPルート、更新受付、保存済み要求を別プロセスで実行する経路を検証する。systemd起動と実サービスの起動確認は差し替える。Linux上の実systemdによる切り替え・復旧、ログアウト・OS再起動後の常駐は未検証。不明点と後続の常駐設定は[Issue #90](https://github.com/Applica-760/whub-mac/issues/90)で管理する。
