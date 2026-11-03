# Markdown

| ファイル | 責務 |
| --- | --- |
| [MarkdownView.swift](MarkdownView.swift) | 表示更新と部品配置の統合、選択・スクロール位置の保持 |
| [MarkdownDocument.swift](MarkdownDocument.swift) | Markdownの解析、ブロック構造の生成、数式の保護・復元 |
| [MarkdownBlockRenderer.swift](MarkdownBlockRenderer.swift) | ブロックから属性付き文字列とコード配置情報を生成 |
| [MarkdownInlineRenderer.swift](MarkdownInlineRenderer.swift) | 文字装飾、数式画像の生成、LayoutManagerによるインラインコード背景の描画 |
| [MarkdownCodeBlock.swift](MarkdownCodeBlock.swift) | コード表示、横スクロール、コピー、空間確保用Cell |
| [MarkdownTextView.swift](MarkdownTextView.swift) | 本文の選択コピーとアクセシビリティ |
