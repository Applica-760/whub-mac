# whub-mac

ファイル編集、ターミナル、ブラウザ、Codexとの対話をまとめたmacOS用のワークスペースアプリです。SwiftUIとAppKitで実装し、キーボードでの操作を重視しています。

個人用に開発中です。保存モデルや操作方法は変更されることがあります。

## できること

- **File**：ローカルのファイル編集、Gitの変更一覧・差分表示、SSH接続先のファイル閲覧。
- **Terminal / Browser**：複数タブのターミナルとブラウザ、ブックマーク管理。
- **AgentBook**：Codexとの対話を本の見開きで表示。会話の再開、モデル選択、コマンドやファイル変更の承認。
- **Overview**：Todoと活動時間の記録・表示。
- **Motion**：カメラ映像から手指を認識する実験機能。

SSH接続先のファイルは閲覧のみです。AgentBookはローカルでCodex CLIを起動します。

## 必要な環境

| 用途 | 条件 |
| --- | --- |
| アプリの実行 | macOS 26.5以降（プロジェクト設定上の最低バージョン） |
| ビルド | Xcode。Xcode 27.0 / macOS 27.0.1でDebugビルドを確認済み |
| WhubCore / CLI | Swift tools 6.2以降、macOS 26以降 |
| アプリのテスト | テスト対象の最低OSはmacOS 27.0 |
| AgentBook | ローカルにインストール・認証済みのCodex CLI |
| リモートファイル閲覧 | SSH公開鍵認証、接続先で実行できるPython 3 |

最低OSでの実行と、クリーン環境でのビルドは未検証です。Codex CLIの対応バージョンはまだ固定していません。

## ソースからビルドする

リポジトリのルートで実行します。初回はSwift Packageの依存を取得するため、ネットワーク接続が必要です。

```sh
xcodebuild build \
  -project whub.xcodeproj \
  -scheme 'whub (whub project)' \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/DerivedData" \
  CODE_SIGNING_ALLOWED=NO
```

プロジェクトには開発者の署名設定が入っています。このコマンドは署名を無効にしてビルドします。ビルド成功後、次のコマンドで起動します。署名なしでの起動は未検証です。

```sh
open -n "$PWD/DerivedData/Build/Products/Debug/whub.app"
```

署名付きビルド、CLIのビルド、Archiveは[ビルド運用](docs/operations/build.md)を参照してください。

## 最初にHostとProjectを登録する

Hostは作業するMacやSSH接続先、ProjectはそのHost上のプロジェクトです。ファイル一覧には登録したProjectと、そのGit worktreeが表示されます。

1. Settingsの「Hosts」でLocalのHostを追加し、Base Pathを作業ディレクトリの絶対パスに設定します。
2. Base Pathの下にある `projects/<プロジェクト名>` に、対象のディレクトリを用意します。
3. Settingsの「Projects」で、そのディレクトリ名とHostを登録します。

worktree用のディレクトリは `worktrees/<プロジェクト名>-<Issue番号>` です。Project登録時にGit URLを指定しても、自動でcloneはしません。

RemoteのHostでは接続先、ユーザー名、ポート、必要に応じて秘密鍵ファイルのパスを設定します。ファイル閲覧は対話なしのSSH認証を使うため、事前に通常のSSH接続で認証とホスト鍵を確認してください。

AgentBookはLocal HostのBase Pathを作業ディレクトリに使います。未登録の場合はホームディレクトリを使い、会話の再開時はその会話の作業ディレクトリを使います。Codex CLIはログインシェルのPATHから探します。

## 保存データと権限

Host、Project、活動記録などは `~/Library/Application Support/whub/workspace.store` に保存します。GUIとCLI、Debug版とRelease版はこの保存先を共有します。保存モデルを変更した場合は、GUIとCLIを揃えて再ビルドしてください。

アプリのApp Sandboxは無効です。ファイル編集やターミナルは、起動したユーザーの権限で動作します。AgentBookの承認・実行制限はCodexの設定を使います。Motionを使う際はカメラへのアクセス許可が必要です。

## 操作・開発の参照先

- [キーボードショートカット](docs/reference/shortcuts.md)
- [ビルド・起動・Archive](docs/operations/build.md)
- [Swift / SwiftUIの実装メモ](docs/reference/swift-and-swiftui-concepts.md)
- [不具合報告・要望](https://github.com/Applica-760/whub-mac/issues)

## ライセンス

このリポジトリのライセンスは未設定です。依存ライブラリと同梱素材には、それぞれのライセンスが適用されます。
