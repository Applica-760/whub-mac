# Linux の Git 変更監視

## GITWATCH-F-001：監視対象のファイル変更を通知する
- 前提：作業ツリーと Git 管理ディレクトリを監視している
- 操作：監視対象でファイルを作成・変更・削除する
- 期待結果：変更が通知される
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/LinuxFileWatcherTests.swift / LinuxFileWatcherTests.detectsFileChangesInAllRoots()（それぞれのディレクトリで検証）

## GITWATCH-F-002：追加されたディレクトリを監視する
- 前提：作業ツリーを監視している
- 操作：ディレクトリを追加し、その中にファイルを作成する
- 期待結果：ディレクトリ構成の再確認とファイルの変更が通知される
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/LinuxFileWatcherTests.swift / LinuxFileWatcherTests.detectsChangesInNewDirectories()

## GITWATCH-F-003：ファイルの読み取りでは通知しない
- 前提：ファイルのあるディレクトリを監視している
- 操作：ファイルを読み取る
- 期待結果：変更は通知されない
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/LinuxFileWatcherTests.swift / LinuxFileWatcherTests.doesNotReportFileReads()
