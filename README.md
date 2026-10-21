# whub-mac

ファイル編集、ターミナル、ブラウザ、Codexとの対話をまとめたmacOS用のワークスペースアプリです。SwiftUIとAppKitで実装し、キーボードでの操作を重視しています。

個人用に開発中です。保存モデルや操作方法は変更されることがあります。

## できること

- **Workspace**：FileとAgentBookを左右に表示。
- **File**：ローカルのファイル編集・Git差分表示、リモートの既存ファイルの閲覧・編集・保存。
- **Terminal / Browser**：複数タブのターミナルとブラウザ、ブックマーク管理。
- **AgentBook**：Local／RemoteでCodexを実行。会話を中央ページと前後のプレビューで表示し、再開・モデル選択・実行承認に対応。
- **Overview**：Todo・活動時間の記録、リモートServerの管理。
- **Motion**：カメラ映像から手指を認識する実験機能。

## 必要な環境

| 用途 | 条件 |
| --- | --- |
| アプリの実行 | macOS 26.5以降（プロジェクト設定上の最低バージョン） |
| ビルド | Xcode、Swift tools 6.2以降 |
| AgentBook | 実行先のMacまたはLinuxにインストール・認証済みのCodex CLI |
| リモート利用 | SSH公開鍵認証、Linux上のWhubServer、HostのDev／Prod Server URL設定 |

最低OSでの実行と、クリーン環境でのビルドは未検証です。Codex CLIの対応バージョンはまだ固定していません。

ビルド・起動・Archiveは[ビルド手順](docs/operations/build.md)を参照してください。

## 最初にHostとProjectを登録する

Hostは作業するMacやSSH接続先、ProjectはそのHost上のプロジェクトです。

1. Settingsの「Hosts」でHostを追加し、Base PathをそのHost上の作業ディレクトリの絶対パスに設定します。
2. Base Pathの下にある `projects/<プロジェクト名>` に、対象のディレクトリを用意します。
3. Settingsの「Projects」で、そのディレクトリ名とHostを登録します。

Explorerは表示対象のProjectと、その `worktrees/<プロジェクト名>-<Issue番号>` を表示します。Project登録時に自動cloneはしません。

Remote HostはSSH接続情報とDev／Prod Server URLを設定します。事前に通常のSSH接続で認証とホスト鍵を確認してください。Serverの準備は[Server運用](docs/operations/server-releases.md)を参照してください。

AgentBookは選択HostのBase Pathで実行し、履歴再開時はその会話の作業ディレクトリを使います。Host未設定のLocal実行ではMacのホームディレクトリを使います。

## 保存データと権限

Host、Project、活動記録などは `~/Library/Application Support/whub/workspace.store` に保存します。GUIとCLI、Debug版とRelease版はこの保存先を共有します。保存モデルを変更した場合は、GUIとCLIを揃えて再ビルドしてください。

アプリのApp Sandboxは無効です。ファイル編集やターミナルは、起動したユーザーの権限で動作します。AgentBookの承認・実行制限はCodexの設定を使います。Motionを使う際はカメラへのアクセス許可が必要です。

## 操作・開発の参照先

- [ドキュメント一覧](docs/README.md)：設計・API・操作・運用と、各Package／FeatureのREADME。
- [不具合報告・要望](https://github.com/Applica-760/whub-mac/issues)

## ライセンス

このリポジトリのライセンスは未設定です。依存ライブラリと同梱素材には、それぞれのライセンスが適用されます。
