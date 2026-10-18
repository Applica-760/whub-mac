# Files

ローカル・リモートのファイル一覧、ファイル編集、ローカルのGit差分表示を担当する。

## 構成と責務

```text
Files/
├── README.md
├── Model/
│   ├── FileLocation.swift         // ローカル・リモートのファイル位置を表す
│   └── ExplorerItem.swift         // ツリーに表示する項目を表す
├── Store/
│   ├── FilesStore.swift           // Explorer・Gitと、ワークスペース別のEditorを保持
│   │                              // ファイルを開く処理・作成・改名・ゴミ箱移動を調整
│   ├── Explorer/
│   │   ├── ExplorerStore.swift    // 選択場所・名前入力状態と、配下の4つのStoreを保持
│   │   ├── LocalWorkspaceStore.swift
│   │   │                          // ローカルのProject・worktree情報を保持
│   │   ├── RemoteWorkspaceStore.swift
│   │   │                          // リモートのワークスペース一覧・取得状態を保持
│   │   ├── LocalTreeStore.swift   // ローカルのツリー・取得結果を保持し、変更を監視
│   │   └── RemoteTreeStore.swift  // リモートのツリー・ディレクトリ別の取得状態を保持
│   ├── Editor/
│   │   ├── EditorStore.swift      // タブ・選択・プレビューと、Local／RemoteEditorを保持
│   │   ├── LocalEditorStore.swift // ファイル別のLocalFileStore・LocalDiffStoreを保持
│   │   ├── RemoteEditorStore.swift
│   │   │                          // ファイル別のRemoteFileStoreを保持
│   │   ├── LocalFileStore.swift   // FileStore・保存時のデータを保持し、読み書き・外部変更を管理
│   │   ├── RemoteFileStore.swift  // FileStore・通信状態を保持し、読み書き・競合・切断を管理
│   │   ├── FileStore.swift        // 本文・保存済み本文・Undo・エディタ位置を保持
│   │   └── FileEncoding.swift     // UTF-8の読み書きと、保存時の改行・BOMの保持を担当
│   ├── Git/
│   │   ├── GitStore.swift         // 選択ルートのGit変更一覧・取得状態を保持
│   │   └── LocalDiffStore.swift   // ファイル単位の差分・取得状態を保持し、変更を監視
│   └── FileWatcher.swift          // ファイルシステムの変更を通知
└── View/
    ├── Explorer/
    │   ├── ExplorerView.swift     // 選択UI・ツリー・変更一覧を組み合わせ、操作をStoreへ渡す
    │   ├── ExplorerTreeView.swift // ツリー表示とAppKitの選択・展開・名前入力を担当
    │   ├── ExplorerDiffView.swift // Git変更一覧を表示し、差分を開く操作を渡す
    │   └── …                     // 項目表示・選択メニュー・コンテキストメニュー
    └── Editor/
        ├── EditorView.swift       // ファイル・差分の表示を切り替え、フォーカスを復元
        ├── EditorTabBarView.swift // 共通タブ部品に、ファイル名・変更状態・操作を接続
        ├── Text/
        │   ├── CodeEditorView.swift
        │   │                      // AppKitのテキスト編集UIを接続
        │   ├── DiffView.swift     // ファイルの差分を表示
        │   └── …
        └── Binary/
            └── BinaryView.swift   // バイナリファイルを表示
```


`FilesStore.activeEditor` は、選択中のワークスペースに対応する `EditorStore` を指す。ワークスペースを切り替えても、各EditorStoreのタブ状態は保持する。

## 共通部品の参照先

- [TabBarContainer](../../Components/TabBarContainer.swift)：タブの選択・閉じる操作の受付、並べ替えなどの共通動作。
- [TabBar](../../Components/TabBar.swift)：タブの見た目。
- [WidgetFrame](../../Components/WidgetFrame.swift)：ヘッダーと本文を持つ領域の枠。

## 変更時に守る境界

- Store追加前に、管理する状態がワークスペース・タブ・ファイルのどれに属するかを確認し、既存Storeと同じ状態を別に持たせない。
- ファイルの新規作成・改名・ゴミ箱移動は `FilesStore` を通す。改名・ゴミ箱移動では、FilesStoreが全ワークスペースを確認し、`EditorStore` が影響するタブを抽出する。未保存・入力中・保存中の判定は `LocalFileStore` が担当する。
- 読み書き・競合確認は `LocalFileStore`／`RemoteFileStore`、共通の編集状態は `FileStore` に置く。
- リモート接続・サーバー管理は、外部から渡される `RemoteConnectionStore`／`RemoteServerStore` を使う。
- 所有関係・操作の入口・共通部品の使い方を変更したら、このREADMEも更新する。
