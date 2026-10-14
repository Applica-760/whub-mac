- whub-dev の後継として機能を拡張する。ただし、既存の設計や実装に囚われず、目的に合う方法を選ぶ。
- キーボードショートカットを重視し、キーボードから手を離さずに開発できる、whub-webapp にはないネイティブアプリならではの体験を目指す。
- `#Preview`は一切定義しない
- ビルド・起動・Archiveは [運用文書](docs/operations/build.md) に従う。
- 要件が固まり切らない段階で勝手にTestを作らない
- UIは基本LiquidGlassを利用する
- 配色は役割に応じたApple標準の動的な色・Material・Glassを優先し、文字と背景をライト／ダーク両方に対応させる。独自色や固定の白・黒、Glassのtintは明確な意図がある場合に限り、両モードと起動中の切り替えで視認性を確認する。

- worktreeの作成・push・PRとIssueの連携・merge・片付けは、[共通の開発運用](../../docs/operations/worktree.md)を正本とする。
