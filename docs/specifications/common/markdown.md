# Markdownの要求仕様

## 機能要件

### 描画

#### MD-F-001：テーブルを描画する
- 前提：テーブルを含むMarkdownがある
- 操作：Markdownを表示する
- 期待結果：行と列を持つ表として描画される
- 対応テスト：`whubTests/Components/Markdown/MarkdownDocumentTests.swift / MarkdownDocumentTests.markdownRendersTableAndCodeBlock()`（表の解析構造と、ライト／ダークの表示Viewにおける見出しを含む3行2列のセル文字列・描画領域・横並び・縦揃え・行間の非重複を検証。画面の目視確認は含まない）

#### MD-F-002：コードブロックを描画する
- 前提：コードブロックを含むMarkdownがある
- 操作：Markdownを表示する
- 期待結果：コードが独立したブロックとして描画される
- 対応テスト：`whubTests/Components/Markdown/MarkdownDocumentTests.swift / MarkdownDocumentTests.markdownRendersTableAndCodeBlock()`（コードブロックの種別・言語の解析と、ライト／ダークの表示Viewでコードの文字列が表とは別のテキストViewに表示され、表の下に独立した領域を持つことを検証。画面の目視確認は含まない）

#### MD-F-003：インラインコードを描画する
- 前提：文章中にインラインコードを含むMarkdownがある
- 操作：Markdownを表示する
- 期待結果：インラインコードが文章中で通常の本文と区別できる見た目で描画される
- 対応テスト：`whubTests/Components/Markdown/MarkdownDocumentTests.swift / MarkdownDocumentTests.inlineCodeAndFormulaRenderWithinParagraph()`（ライト／ダークの表示Viewで、前後の本文とコードの文字列、コード範囲のフォント・背景による区別、正の描画領域を検証。画面上の視認性の目視確認は含まない）

#### MD-F-004：インライン数式を描画する
- 前提：文章中にインライン数式を含むMarkdownがある
- 操作：Markdownを表示する
- 期待結果：文章中に数式として描画される
- 対応テスト：`whubTests/Components/Markdown/MarkdownDocumentTests.swift / MarkdownDocumentTests.inlineCodeAndFormulaRenderWithinParagraph()`（ライト／ダークの表示Viewで、本文中の数式が正のサイズを持つ画像として配置され、前後の本文と同じ行にあることを検証。数式全構文と目視の網羅は含まない）

### プレビュー

#### MD-F-005：FileEditorからプレビューを表示する
- 前提：FileEditorでMarkdownファイルを開いている
- 操作：プレビューを表示するオプションを選ぶ
- 期待結果：対象ファイルのMarkdownプレビューが表示される
- 対応テスト：`whubTests/Features/Files/Store/EditorStoreTests.swift / EditorStoreTests.markdownPreviewReusesDocumentsAndTracksEachOpenFile()`（Storeの文書再利用・未保存内容保持・ファイル別表示状態を検証。実アプリのボタン操作とライト／ダーク表示のUIテストは削除済み）

### コードブロックの操作

#### MD-F-006：コードブロックにコピーボタンを表示する
- 前提：コードブロックを含むMarkdownがある
- 操作：Markdownを表示する
- 期待結果：コードブロックに対応するコピーボタンが表示される
- 対応テスト：なし（実アプリのコピーボタン表示を検証するUIテストは削除済み）。

## 非機能要件

現時点で独立した要件は定義していない。

## 設計上の保証

現時点で独立した項目は定義していない。
