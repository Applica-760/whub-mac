# Linux の Git 変更監視

## GITWATCH-F-001：監視対象のファイル変更を通知する
- 前提：作業ツリーと Git 管理ディレクトリを監視している
- 操作：監視対象でファイルを作成・変更・削除する
- 期待結果：変更が通知される
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/LinuxFileWatcherTests.swift / LinuxFileWatcherTests.detectsFileChangesInAllRoots()（それぞれのディレクトリで検証）

## GITWATCH-F-002：追加されたディレクトリを監視する
- 前提：作業ツリーを監視している
- 操作：ディレクトリを追加し、その中にファイルを作成する
- 期待結果：追加されたディレクトリとファイルの変更が通知される
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/LinuxFileWatcherTests.swift / LinuxFileWatcherTests.detectsChangesInNewDirectories()

## GITWATCH-F-003：ファイルの読み取りでは通知しない
- 前提：ファイルのあるディレクトリを監視している
- 操作：ファイルを読み取る
- 期待結果：変更は通知されない
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/LinuxFileWatcherTests.swift / LinuxFileWatcherTests.doesNotReportFileReads()

## GITWATCH-F-004：HTTPで変更を待機し監視を解除する
- POST `/git/watches?root=<absolute path>` は監視IDと更新番号を返す。
- GET `/git/watches/<id>?after=<revision>` は更新番号が進むと番号を返し、5秒間変更がなければ204を返す。
- DELETE `/git/watches/<id>` は購読を解除する。存在しない監視IDは410を返す。
- 同じrootの購読は監視を共有する。60秒間利用されない購読は期限切れとなる。
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/GitAPITests.swift / GitAPITests.notifiesAndReleasesWatch()

## GITWATCH-F-005：Gitの無視対象を監視から除外する
- Gitのignore設定で無視され、追跡済みファイルを含まないディレクトリは監視しない。
- Gitの管理ディレクトリと、indexまたはHEADにあるファイルは監視を維持する。
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/GitAPITests.swift / GitAPITests.ignoresUntrackedDirectoriesButWatchesTrackedFiles()

## GITWATCH-F-006：ignore設定の変更を反映する
- `.gitignore`、Gitのindex、HEAD、設定、info/excludeの変更時に監視を再構築する。
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/GitAPITests.swift / GitAPITests.rechecksIgnoreRules()
