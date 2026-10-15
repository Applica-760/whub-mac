# WhubServerのリリース

`WhubServerManager.ServerReleases`が、ビルドからdev／prodの切り替え、失敗時の旧版復元までを実行する。今回はSwiftから呼ぶ共通処理までを実装し、CLI・更新API・systemdの初回登録は後段で扱う。

初めて接続するときは「呼び出す前の準備」と「Swiftから更新する」を読む。中断や失敗が起きた場合は「履歴を確認する」「中断後は手動で復旧する」を参照する。

## 呼び出す前の準備

Linux上でSwift・Git・systemd userサービスを使えることが前提。リリース処理は対象Serverのプロセス外で実行する。同じサービス内から呼ぶと、再起動時に更新処理も停止する。

- ソースはcleanなGit checkoutとし、`origin`を設定する。Buildはdetached checkoutへ切り替え、元ブランチには戻さない。更新中はソースを編集しない。
- 保存先はソースcheckoutの外に置き、dev／prodの全更新で同じ絶対パスを使う。同じcheckoutを使う別のBuildも並行実行しない。
- dev／prodそれぞれのsystemd userサービスを事前に登録し、`ExecStart`に各環境の`current/whub-server`の絶対パスを指定する。シェルやラッパーを介さず、Server自身をMainPIDとして管理する。
- サービスごとに`WHUB_SERVER_HOST`・`WHUB_SERVER_PORT`・`WHUB_SERVER_ROOT`を設定する。ポートは環境間で分ける。渡すhealth URLは、そのサービスの`/ping`を直接指す。
- systemdの起動・停止タイムアウトは有限値にする。ログアウト後・OS再起動後の起動設定と、更新処理自身の独立実行の登録は後続作業。

## Swiftから更新する

次は`WhubServerManager`を依存に持つSwiftプログラム内での呼び出し例。単体で実行できるスクリプトではない。パスとサービス名は実環境に合わせて明示する。

```swift
import Foundation
import WhubServerManager

let releases = ServerReleases(
    root: URL(fileURLWithPath: "/home/user/Developer/.whub/server")
)
let build = ServerBuild(
    source: URL(fileURLWithPath: "/home/user/Developer/projects/whub-mac"),
    swift: "/home/user/.local/share/swiftly/bin/swift"
)
let update = try await releases.release(
    environment: .dev,
    ref: "refs/remotes/origin/feature/example",
    build: build,
    service: "whub-server-dev.service",
    healthURL: URL(string: "http://127.0.0.1:8081/ping")!
)
guard update.status == "succeeded" else {
    throw ReleaseError(update.status, update.error ?? "Release did not succeed.")
}
```

prodでは`environment: .prod`とし、`ref`を省略する。必ず`refs/remotes/origin/main`をfetchしてcommitを確定し、ビルドする。任意成果物のprodへの昇格機能は設けていない。

更新はdev／prodを含めて一度に1件だけ実行する。実行中の追加要求は待機させず、`update_locked`で拒否する。順番に更新する呼び出し側は、1件の完了を待ってから次を呼ぶ。

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
│   └── build.log
└── update.lock/                 # 更新中だけ存在。中断時は残る
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
| `error` | 失敗理由。復旧も失敗した場合は両方を記録 |
| `ref` | ビルドに指定したref。commitは各成果物の`build.json`で確認 |

| status | 意味 |
| --- | --- |
| `building` | ビルド中 |
| `switching` | 成果物を保管済み。切り替え・起動確認中 |
| `rolling_back` | 旧版への復元処理中 |
| `succeeded` | 新版の起動確認が成功 |
| `failed` | 更新失敗。切り替え前なら現行維持、初回導入の切り替え後なら停止済み |
| `rolled_back` | 更新失敗後、旧版の起動確認が成功 |
| `recovery_failed` | 更新も復旧も失敗。実際の稼働状態は要確認 |

ビルド・切り替えの失敗は履歴へ保存し、`ServerUpdate`として返す。戻り値の`status`を必ず確認する。入力不正、ロック取得失敗、履歴の保存失敗などはthrowする。

## 中断後は手動で復旧する

異常終了やOS再起動の後は自動再開しない。`update.lock`が残り、次の更新を拒否する。稼働中の更新プロセスが存在しないことを確認するまでロックを取り除かない。

1. `updates`の最新`state.json`と`build.log`、対象サービスの`systemctl --user status`・`journalctl --user -u <service>`を確認する。
2. `current`と`previous`のリンク先、MainPIDの実行ファイルを確認する。必要なら検証済みの旧成果物へ`current`を戻し、対象サービスを再起動して`/ping`を確認する。初回導入で使える成果物がなければサービスを停止する。
3. 実際の復旧結果を別途記録する。保存済み履歴は自動で修正されない。ビルド中に中断した場合、`updates/<id>`内に作業中の成果物が残る場合もある。
4. 更新プロセスが停止し、環境の状態を確認できたら、空の`<root>/update.lock`ディレクトリだけを`rmdir`で取り除く。以降、新しい更新を実行できる。

Macでのテストはsystemd操作とHTTP確認を差し替えている。Linux上の実サービスでの切り替え・復旧は未検証。不明点と後続のCLI・API・常駐設定は[Issue #90](https://github.com/Applica-760/whub-mac/issues/90)で管理する。
