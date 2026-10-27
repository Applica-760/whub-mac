# リモート Git 差分取得

WhubServer は WhubGit を利用し、HEAD と保存済み作業ツリーを比較する。

## GITAPI-F-001：変更ファイル一覧を取得する
- 前提：Git リポジトリに保存済みの変更ファイルと未追跡ファイルがある
- 操作：変更ファイル一覧を要求する
- 期待結果：変更ファイルの相対パスと変更種別が返り、保存済みの内容が HEAD と同じファイルは含まれない
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/GitAPITests.swift / GitAPITests.listsSavedChangesAgainstHEAD()

## GITAPI-F-002：ファイルの変更前後を取得する
- 前提：HEAD から内容が変更または削除されたテキストファイルがある
- 操作：ファイルの差分を要求する
- 期待結果：変更種別と HEAD の内容、保存済みの内容が返る。削除後の内容は空文字になる
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/GitAPITests.swift / GitAPITests.returnsBeforeAndAfterForChangedAndDeletedFiles()

## GITAPI-F-003：非対応のファイル形式を通知する
- 前提：未追跡のバイナリファイルがある
- 操作：ファイルの差分を要求する
- 期待結果：変更種別とバイナリが非対応である理由が返る
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/GitAPITests.swift / GitAPITests.reportsUnsupportedBinaryContent()

## GITAPI-F-004：不正なパスを拒否する
- 前提：相対パスがルート外を指す、または要求のパスが不正である
- 操作：変更一覧またはファイル差分を要求する
- 期待結果：要求は不正なリクエストとして拒否される
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/GitAPITests.swift / GitAPITests.rejectsInvalidPaths()

## GITAPI-F-005：リポジトリ以外のルートを通知する
- 前提：指定したディレクトリが Git リポジトリ内にない
- 操作：変更ファイル一覧を要求する
- 期待結果：リポジトリでないことを示すエラーが返る
- 対応テスト：Packages/WhubPackage/Tests/WhubServerTests/GitAPITests.swift / GitAPITests.reportsNonRepository()
