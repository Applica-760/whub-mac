# WhubPackage

GUIとCLIで使う保存モデル・共通処理、HTTPクライアント、リモートで動くHTTPサーバーをまとめたSwift Package。GUIの画面・タブ・編集状態は、このPackageの外にある `whub/Features/` が担当する。

## 構成と責務

主要な境界に関係するファイルを示す。`…` は省略部分。

```text
WhubPackage/
├── README.md
├── Package.swift                 // 4ターゲットの製品・依存関係とテストターゲットを定義
├── Sources/
│   ├── WhubCore/                 // GUI／CLIで使う保存モデル・Git・SSHの共通処理
│   │   ├── Container.swift       // SwiftDataの保存先と登録モデルを定義
│   │   ├── Host/                 // Hostモデルと、登録・変更・削除時の検証／保存
│   │   ├── Project/              // Projectモデルと、登録・実在確認・worktreeの解決
│   │   ├── Timer/                // 活動記録・分類・通知設定のモデルと検証／保存
│   │   ├── Git/                  // Git変更の取得・行／ファイル差分・ツリーへの集約
│   │   └── SSH/
│   │       ├── SSH.swift         // SSH設定・引数の検証とプロセス操作
│   │       ├── SSHConnectionService.swift
│   │       │                     // 1接続のControlMaster・コマンド実行・転送を管理
│   │       └── RemoteConnectionStore.swift
│   │                             // Host別のSSH接続・接続状態・接続処理を保持
│   ├── WhubClient/               // HTTP要求・応答の復号とAPIエラーを扱う
│   │   ├── WhubClient.swift      // 接続先URL・URLSessionを保持し、通信処理を共通化
│   │   └── API/Files/FilesAPI.swift
│   │                             // 一覧取得・本文取得・競合確認付き保存の要求を生成
│   ├── WhubCLI/                  // 製品名はwhub-mac。WhubCoreを使うCLI
│   │   ├── main.swift            // コマンド振り分けとProject名一覧のJSON出力
│   │   └── HostCommand.swift     // 登録済みRemoteHostへ対話用SSHで接続
│   └── WhubServer/               // 製品名はwhub-server。HTTPと更新用の実行ファイル
│       ├── WhubServer.swift      // 起動設定を検証し、HTTP起動／更新実行を選択
│       ├── API/
│       │   ├── Routes.swift      // URLとHTTPハンドラーを接続
│       │   ├── Files/            // HTTP入力・応答サイズを検証し、FilesServiceを呼ぶ
│       │   └── Manager/          // Bearer認証・更新要求の検証・状態／ログの応答
│       └── Services/
│           ├── Files/            // パス・ファイル種別・本文を検証し、実ファイルを読み書き
│           └── Manager/
│               ├── Build/        // 指定refから環境に依存しないServer成果物を生成
│               └── Releases/     // 更新予約・履歴・dev／prod切り替え・失敗時の復元
└── Tests/
    ├── WhubCoreTests/            // Git差分・SSH接続状態の検証
    └── WhubServerTests/          // Files／Manager API・ビルド・リリース処理の検証
```

## ターゲットの依存と通信を区別する

Package.swift上の依存関係は次のとおり。WhubClientとWhubServerは、どちらもWhubCoreへ依存していない。

```text
whub GUI［Packageの外］ → WhubCore・WhubClient
WhubCLI               → WhubCore
WhubServer            → Hummingbird

WhubClient ── HTTP ──→ WhubServer
```

Client側とServer側にはそれぞれ `FilesAPI` がある。前者は要求を作る窓口、後者はHTTP入力を検証してServiceを呼ぶハンドラー。同じ名前でも、共有された型や同じ責務ではない。APIのパス・JSON・エラー形式を変える場合は両側を確認する。

## GUI／CLIの保存モデルと、画面の状態を分ける

`Container.make()` は `~/Library/Application Support/whub/workspace.store` を開く。GUIとCLI、Debug版とRelease版は同じ保存先を使う。保存モデルを変更したらGUIとCLIを揃えて再ビルドする。

Host・Project・Timer配下のStoreは、渡された `ModelContext` で検証と保存を行う。画面の選択・タブ・未保存の編集内容はGUI側のStoreに置く。`RemoteConnectionStore` は永続化用Storeとは異なり、実行中の接続を保持する。

## SSH接続とHTTPクライアントの管理を分ける

Host別のSSH接続は `RemoteConnectionStore`、個別接続のコマンド実行・ポート転送は `SSHConnectionService` が担当する。GUI側の [RemoteServerStore](../../whub/Features/Host/RemoteServerStore.swift) が接続と環境別Server URLを使って転送を準備し、WhubClientを保持する。WhubClient自体はSSH接続やdev／prodの選択を行わない。

CLIの `host` コマンドは対話用の `/usr/bin/ssh` にプロセスを置き換える。GUIの接続Storeやポート転送を共有する処理ではない。

## Server変更時に守る境界

- HTTPの入力・応答・エラーへの変換は `API/`、ファイル操作と更新処理は `Services/` に置く。同期的なファイルI/Oやビルド処理をHTTPのイベントループで直接実行しない。
- Files APIは絶対パスの `root` と、その配下の相対 `path` を受け取る。`root` は要求側が指定する値で、サーバー固定の公開許可ルートではない。FilesServiceでの `..`・シンボリックリンク・ファイル種別の検証を、Client側の検証だけで代替しない。
- 本文保存はUTF-8の `expectedText` と保存先の現状をバイト単位で比較する。競合時は上書きせずエラーにする。通常の文字列比較への置き換えや、失敗後の無条件な再送は避ける。GUI側は通信断による保存結果不明も扱う。
- Manager APIはBearer認証を行うが、Files APIには同じ認証処理がない。Serverの既定待受は `127.0.0.1:8080`。公開範囲を変更する場合は、両APIの認証の違いを確認する。
- `ServerBuild` は成果物の生成まで、`ServerReleases` は更新の直列化・配置・切り替え・起動確認・復元を担当する。Buildは指定checkoutを変更するため、共有checkoutの並行ビルドを避ける。HTTPの202は更新受付であり、切り替え成功ではない。

## 運用の参照先

- [ビルド・起動・CLI再ビルド・Archive](../../docs/operations/build.md)
- [Serverの設定・更新・履歴確認・手動復旧](../../docs/operations/server-releases.md)

依存関係・保存先・通信や保存の契約を変えたら、このREADMEも更新する。
