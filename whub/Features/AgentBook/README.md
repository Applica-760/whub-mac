# AgentBook

[Agent](../Agent/README.md) の会話を、タブと中央ページ・前後のプレビューで表示する。タブの構成・通知・入力操作・読書位置を担当する。

## 構成と責務

主要な境界に関係するファイルを示す。`…` は省略部分。

```text
AgentBook/
├── README.md
├── Store/
│   ├── AgentBookStore.swift       // タブ一覧・選択・再開処理を保持し、タブの置換を調整
│   └── AgentBookTabStore.swift    // Agent側の3つのStoreと、用途・完了通知・通知日時を保持
└── View/
    ├── AgentBookView.swift        // タブごとのViewを保持し、切り替え・閉じる確認を担当
    ├── AgentBookTabView.swift     // 1タブの本文・入力・操作部を組み合わせ、接続を開始
    ├── Controls/
    │   ├── AgentBookInputView.swift
    │   │                          // 入力・候補選択・コマンド操作と、入力／読書フォーカスを担当
    │   ├── AgentBookNavigationView.swift
    │   │                          // ページの移動操作を担当
    │   └── …                     // タブ選択・モデル／エージェント選択のUI
    └── Exchange/
        ├── AgentBookExchangeView.swift
        │                          // 会話の変更をページ配置へ渡し、ヘッダー・承認UIを重ねる
        ├── AgentBookOutputView.swift
        │                          // 作業履歴の表示と、Agent出力の表示用変換を担当
        ├── AgentBookResponseView.swift
        │                          // 承認・質問の回答UIとショートカットを担当
        └── Page/
            ├── AgentBookPageLayout.swift
            │                      // 表示文書・ページ範囲・選択ページ・操作部品の座標を保持
            ├── AgentBookTextView.swift
            │                      // AppKitのページ・コード表示を配置し、選択・コピーを担当
            └── Markdown/
                ├── AgentBookMarkdownDocument.swift
                │                  // Markdownの段落・表・コードを表示用の属性付き文字列へ変換
                └── AgentBookMathRenderer.swift
                                   // 数式の元ソースを保持し、数式画像・本文装飾を生成
```

## タブの状態と会話の状態を分ける

`AgentBookTabStore` は `AgentStore`・`AgentHistoryStore`・`AgentSkillStore` を保持する。会話本文・下書き・接続／実行状態はAgent側、用途・完了通知・通知日時はタブ側に置く。履歴やスキルの一覧をView内に別途保持しない。

`AgentBookStore.resume` は再開先を別のタブとして準備し、成功後に元のタブを置き換える。同じエージェント種別・会話IDのタブが開いていれば再利用する。再開失敗時に元の会話を失わないため、Viewから先に元タブを消さない。

## ページ配置は会話データから作る表示状態

`AgentBookExchangeView` が `AgentBookPageLayout` を保持する。Markdownの見た目は `AgentBookMarkdownDocument`、ページへの配置は `AgentBookPageLayout`、実際のAppKit Viewの配置は `AgentBookTextSurface`（AgentBookTextView.swift内）が担当する。ページ内スクロールのために `AgentStore.exchanges` を加工しない。

1回のやり取りを1ページに表示し、次のやり取りは次のページから始める。各ページは独立して縦スクロールし、本文の長さでは改ページしない。最初の入力と追加入力はページ高の15％の固定領域にまとめ、その中で全文をスクロールできる。直下に作業履歴の操作部と区切り線、8ptの余白を置いて回答を表示する。

中央に選択ページを広く表示し、左右に前後のページを縮小して配置する。プレビューは中央ページと同じ論理サイズで描画してから縮小し、改行位置と表示範囲を揃える。左右対称の遠近変形と薄いグレーの重ね合わせで非選択状態を示し、ページ移動はアニメーションする。動きを減らす設定ではアニメーションしない。

読書フォーカスはBook全体に置き、選択ページを `AgentBookPageLayout` で管理する。H/Lは1ページ単位、J/Kは中央ページを縦スクロールする操作として扱う。ページごとのスクロール位置を保持する。新しいやり取りの追加時は最新ページを表示・操作対象にし、回答の通常更新では対象ページを維持する。

各ページは独立したTextKitの本文・レイアウトを持つ。入力・コードは本文中の添付部品で領域を確保し、別Viewで描画する。コードは横スクロールでき、縦のスクロール操作はページへ渡す。コードや数式のコピーには、保持した元ソースを使う。

## 変更時に守る境界

- タブの追加・削除・会話の新規作成・再開・エージェント種別の変更は `AgentBookStore` を通す。最後のタブを閉じても1つ残し、選択IDが実在する状態を保つ。
- タブ切り替えには共通の [RetainedPageContainer](../../Components/RetainedPageContainer.swift) を使う。非表示になっただけで会話を切断しない。非表示タブ・Featureの承認操作やキー入力は無効にする。
- 接続先の作業ディレクトリは `AgentBookStore.connect` で決める。履歴のディレクトリ、Local HostのBase Path、ホームの順に使う。Viewや入力欄で別の決定処理を作らない。
- 本文更新はExchangeViewで間引き、再表示時に最新の会話を渡す。ページ配置を変える際は、未変更ページの再利用と、リサイズ・更新時の読書位置／選択範囲の復元を維持する。
- タブ操作とページ内操作は別に扱う。ページ移動は読書フォーカス、送信は入力フォーカスとの関係を確認し、非表示の画面がショートカットを受け取らないようにする。境界を変えたら、このREADMEも更新する。
