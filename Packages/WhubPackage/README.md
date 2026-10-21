# WhubPackage

保存モデル、Agent実行、HTTP通信、CLI／ServerをまとめたSwift Package。GUIの画面・タブ・編集状態はPackage外の `whub/Features/` が担当する。

## 構成と依存関係

| ターゲット | 責務 | 依存先 |
| --- | --- | --- |
| WhubCore | GUI／CLIの保存モデル、Git・SSHの共通処理 | なし |
| WhubAgent | Local／Remote共通のAgent実行・会話状態・モデル | なし |
| WhubClient | Files／Agent／ManagerのHTTP通信とRemote Agentの状態同期 | WhubAgent |
| WhubCLI | Project一覧の出力、登録HostへのSSH接続。実行ファイルは`whub-mac` | WhubCore |
| WhubServer | Files／Agent／Manager APIとServer更新。実行ファイルは`whub-server` | WhubAgent、Hummingbird |

GUIはWhubCore・WhubAgent・WhubClientを利用する。WhubClientからWhubServerへの接続はHTTP通信であり、ターゲット間の依存ではない。

## ディレクトリ

| 配置 | 内容 |
| --- | --- |
| `Package.swift` | 製品・ターゲット・依存関係の定義 |
| `Sources/<ターゲット名>/` | 各ターゲットの実装 |
| `Tests/WhubCoreTests/` | Git差分・SSH接続状態のテスト |
| `Tests/WhubServerTests/` | Files／Agent／Manager API、ビルド・リリース処理のテスト |

## 関連文書

- [MacとLinuxの責務](../../docs/architecture/remote-development.md)
- [HTTP API](../../docs/reference/api/README.md)
- [ビルド・起動・Archive](../../docs/operations/build.md)
- [Serverの設定・更新・復旧](../../docs/operations/server-releases.md)
