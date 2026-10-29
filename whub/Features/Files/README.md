# Files

ローカル・リモートのファイル一覧、ファイル編集、Git差分表示を担当する。

## 構成と責務

```text
Files/
├── README.md
├── Model/
│   ├── EditorTab.swift            // ファイルタブ・差分タブを表す
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
│   │   ├── LocalDiffStore.swift   // ファイル単位の差分・取得状態を保持し、変更を監視
│   │   └── RemoteGitStore.swift   // Hostとリポジトリ単位の監視・差分取得を管理
│   └── FileWatcher.swift          // ファイルシステムの変更を通知
└── View/
    ├── Explorer/
    │   ├── ExplorerView.swift     // 選択UI・ツリー・変更一覧を組み合わせ、操作をStoreへ渡す
    │   ├── ExplorerTreeView.swift // ツリー表示とAppKitの選択・展開・名前入力を担当
    │   ├── ExplorerDiffView.swift // Git変更一覧を表示し、差分を開く操作を渡す
    │   └── …                     // 項目表示・選択メニュー・コンテキストメニュー
    └── Editor/
        ├── EditorView.swift       // ファイル・差分の表示を切り替え、フォーカスを復元
        ├── DiffContentView.swift  // ローカル・リモートの差分取得状態と比較結果を表示
        ├── EditorTabBarView.swift // 共通タブ部品に、ファイル名・変更状態・操作を接続
        ├── Text/
        │   ├── CodeEditorView.swift
        │   │                      // AppKitのテキスト編集UIを接続
        │   ├── LocalCodeEditorView.swift
        │   │                      // ローカル本文と行単位のGit差分を表示
        │   ├── RemoteViewerView.swift
        │   │                      // リモート本文・画像・通信状態・行単位のGit差分を表示
        │   ├── DiffView.swift     // ファイルの差分を表示
        │   └── …
        └── Binary/
            └── BinaryView.swift   // バイナリファイルを表示
```


`FilesStore.activeEditor` は、選択中のワークスペースに対応する `EditorStore` を指す。ワークスペースを切り替えても、各EditorStoreのタブ状態は保持する。

EditorはWorkspaceの左ペインに表示する。他のFeatureへ切り替えてもView・未保存内容・カーソル・スクロール位置を保持する。`ExplorerFocusNavigation` はExplorerとWorkspace間のフォーカス往復を管理する。

ローカルのUTF-8テキストは、開いているファイルの親ディレクトリを監視して外部変更を自動反映する。通知パスは標準化・シンボリックリンク解決後に対象を判定する。⌘⇧Rは監視の設定を再確認し、開いているローカル本文をディスクから再取得するため、通知を取り逃してもタブを閉じ直す必要はない。通常のリロードでは未保存編集を上書きせず、外部変更の警告を表示する。編集を破棄して最新内容へ切り替える場合は、本文へフォーカスを戻して⌘Sを押し、確認画面で「最新内容を採用」を選ぶ。IME変換中は採用を保留して入力確定後に再確認し、読込失敗時は直前の本文を保持する。リモート本文の自動監視とバイナリ表示の更新はこの仕組みの対象外。

リモート画像は拡張子から画像形式を判定し、Serverから最大8 MiBを取得して表示する。⌘⇧Rと再接続時に再取得し、取得失敗・切断時は前回の画像を保持する。画像は編集できない。

ローカル・リモートの `.md` は、エディタ右上の「Show Preview」またはExplorerの右クリックメニューから、左にソース・右に描画結果を表示できる。「Hide Preview」で閉じる。境界はドラッグで調整でき、未保存の編集内容も反映する。開閉状態は `EditorStore.markdownPreviews` がファイルごとに保持し、タブを閉じると破棄する。一時タブを表す既存の `previewTab` とは別の状態で、アプリ再起動後には復元しない。

プレビューは共通の [`MarkdownView`](../../Components/Markdown/MarkdownView.swift) を使う。表・コード・数式は既存の描画部品で表示し、コードは横スクロール・コピーできる。Mermaidはコードとして表示する。画像・相対リンクの解決は未対応。

⌘DはEditorの現在のファイルと差分を切り替える。

`ExplorerView.swift` の `ExplorerFocusNavigation` は、ウィンドウ内のExplorer一覧とFeature領域への参照を保持する。⌘⇧Eでフォーカスを往復し、FileEditorでは表示中の本文を優先する。⌘⇧Dは通常／Diff Explorerを切り替える。一覧のJ/Kは自動プレビューを伴う行移動、Enterはファイルの確定オープンまたはディレクトリの開閉で、一覧にフォーカスを残す。名前入力中はこれらの一覧操作を処理しない。

## 共通部品の参照先

- [TabBarContainer](../../Components/TabBarContainer.swift)：タブの選択・閉じる操作の受付、並べ替えなどの共通動作。
- [TabBar](../../Components/TabBar.swift)：タブの見た目。
- [WidgetFrame](../../Components/WidgetFrame.swift)：ヘッダーと本文を持つ領域の枠。

## 変更時に守る境界

- Store追加前に、管理する状態がワークスペース・タブ・ファイルのどれに属するかを確認し、既存Storeと同じ状態を別に持たせない。
- ファイルの新規作成・改名・ゴミ箱移動は `FilesStore` を通す。改名・ゴミ箱移動では、FilesStoreが全ワークスペースを確認し、`EditorStore` が影響するタブを抽出する。未保存・入力中・保存中の判定は `LocalFileStore`／`RemoteFileStore` が担当する。
- 読み書き・競合確認は `LocalFileStore`／`RemoteFileStore`、共通の編集状態は `FileStore` に置く。
- リモート接続・サーバー管理は、外部から渡される `RemoteConnectionStore`／`RemoteServerStore` を使う。
- 所有関係・操作の入口・共通部品の使い方を変更したら、このREADMEも更新する。
